#!/usr/bin/env swift
//
// clipboard-unwrap.swift
// Monitors the clipboard and fixes soft-wrapped text when copying from Warp.
//
// Warp pads every line with trailing whitespace to fill the pane width. When
// you select and copy text from a narrow pane, each soft-wrapped line becomes
// a real newline padded with spaces. This tool detects that padding and rejoins
// the lines, preserving blank lines as paragraph/command breaks.
//
// Usage: Run as a background process (LaunchAgent recommended).
//   swift clipboard-unwrap.swift [--dry-run] [--verbose]
//
// Install: compile with `swiftc -O -o clipboard-unwrap clipboard-unwrap.swift`
//
// Known limitation: if you copy indented code from a narrow Warp pane, the
// indentation will be stripped. The trailing-whitespace signal can't distinguish
// soft-wrapped prose from intentionally indented code.

import Cocoa
import Foundation

// MARK: - Configuration

let terminalBundleIDs: Set<String> = [
    "dev.warp.Warp-Stable",
    "com.apple.Terminal",
    "com.googlecode.iterm2",
]
let trailingWsThreshold = 3    // min trailing spaces to count as "padded"
let paddedLineRatio = 0.5      // fraction of non-blank lines that must be padded

let dryRun = CommandLine.arguments.contains("--dry-run")
let verbose = CommandLine.arguments.contains("--verbose")

// MARK: - String helpers

extension String {
    func trimmingLeadingWhitespace() -> String {
        var idx = startIndex
        while idx < endIndex && (self[idx] == " " || self[idx] == "\t") {
            idx = index(after: idx)
        }
        return String(self[idx...])
    }

    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            if self[prev] == " " || self[prev] == "\t" {
                end = prev
            } else {
                break
            }
        }
        return String(self[..<end])
    }

    var trailingWhitespaceCount: Int {
        var count = 0
        var idx = endIndex
        while idx > startIndex {
            let prev = index(before: idx)
            if self[prev] == " " || self[prev] == "\t" {
                count += 1
                idx = prev
            } else {
                break
            }
        }
        return count
    }
}

// MARK: - Soft-wrap detection and rejoining

/// Detects whether the text was copied from a narrow terminal pane.
///
/// Primary signal: most non-blank lines have the same total character count
/// (content + trailing spaces), indicating a fixed pane width. This is stronger
/// than just checking for trailing whitespace, which could match tabular output.
///
/// Fallback signal: if lines don't share a uniform width but most have
/// significant trailing whitespace padding, still treat as soft-wrapped.
///
/// Blank lines are preserved as paragraph/command breaks (collapsed to single breaks).
func fixSoftWrap(_ text: String) -> String? {
    let lines = text.components(separatedBy: "\n")

    let nonBlankLines = lines.filter { !$0.trimmingTrailingWhitespace().isEmpty }
    guard nonBlankLines.count >= 2 else { return nil }

    // Primary check: do most lines share the same total length (= pane width)?
    // This is the strongest signal for terminal soft-wrap.
    let lengths = nonBlankLines.map { $0.count }
    let lengthCounts = Dictionary(lengths.map { ($0, 1) }, uniquingKeysWith: +)
    let (mostCommonLength, mostCommonCount) = lengthCounts.max(by: { $0.value < $1.value })!
    let uniformRatio = Double(mostCommonCount) / Double(nonBlankLines.count)

    // Lines at the uniform width must also have trailing whitespace (not just
    // coincidentally the same content length)
    let uniformAndPadded = uniformRatio >= paddedLineRatio
        && nonBlankLines.filter({ $0.count == mostCommonLength }).allSatisfy({ $0.trailingWhitespaceCount >= trailingWsThreshold })

    guard uniformAndPadded else { return nil }

    let stripped = lines.map { $0.trimmingTrailingWhitespace() }

    // Rejoin consecutive non-blank lines into paragraphs.
    // Consecutive blank lines collapse into a single paragraph break.
    var paragraphs: [[String]] = [[]]
    var lastWasBlank = false

    for line in stripped {
        if line.trimmingLeadingWhitespace().isEmpty {
            if !lastWasBlank && !paragraphs[paragraphs.count - 1].isEmpty {
                paragraphs.append([])
            }
            lastWasBlank = true
        } else {
            let content = line.trimmingLeadingWhitespace()
            paragraphs[paragraphs.count - 1].append(content)
            lastWasBlank = false
        }
    }

    return paragraphs
        .filter { !$0.isEmpty }
        .map { $0.joined(separator: " ") }
        .joined(separator: "\n\n")
}

// MARK: - Clipboard processing

func processClipboard(_ text: String) -> String {
    return fixSoftWrap(text) ?? text
}

// MARK: - Main loop

func log(_ msg: String) {
    if verbose {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
    }
}

let pasteboard = NSPasteboard.general
var lastChangeCount = pasteboard.changeCount

log("clipboard-unwrap started (dry-run: \(dryRun))")
log("Watching for clipboard changes when a terminal app is frontmost...")

let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    let currentCount = pasteboard.changeCount
    guard currentCount != lastChangeCount else { return }
    lastChangeCount = currentCount

    guard let frontApp = NSWorkspace.shared.frontmostApplication,
          let bundleID = frontApp.bundleIdentifier,
          terminalBundleIDs.contains(bundleID) else {
        return
    }

    guard let text = pasteboard.string(forType: .string) else { return }

    let fixed = processClipboard(text)

    if fixed != text {
        log("Fixed clipboard content (\(text.count) → \(fixed.count) chars)")
        if dryRun {
            FileHandle.standardError.write(Data("--- ORIGINAL ---\n\(text)\n--- FIXED ---\n\(fixed)\n---\n".utf8))
        } else {
            pasteboard.clearContents()
            pasteboard.setString(fixed, forType: .string)
            lastChangeCount = pasteboard.changeCount
        }
    }
}

RunLoop.current.add(timer, forMode: .default)
RunLoop.current.run()
