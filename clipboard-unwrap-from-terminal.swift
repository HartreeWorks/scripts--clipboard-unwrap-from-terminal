#!/usr/bin/env swift
//
// clipboard-unwrap-from-terminal.swift
// Monitors the clipboard and fixes soft-wrapped text when copying from terminal apps.
//
// Terminals pad every line with trailing whitespace to fill the pane width. When
// you select and copy text from a narrow pane, each soft-wrapped line becomes
// a real newline padded with spaces. This tool detects that padding and rejoins
// the lines, preserving blank lines as paragraph/command breaks.
//
// Usage: Run as a background process (LaunchAgent recommended).
//   swift clipboard-unwrap-from-terminal.swift [--dry-run] [--verbose]
//
// Install: compile with `swiftc -O -o clipboard-unwrap-from-terminal clipboard-unwrap-from-terminal.swift`
//
// Known limitation: if you copy indented code from a narrow terminal pane, the
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

/// Detects whether the text was copied from a narrow terminal pane and unwraps it.
///
/// Primary signal: most non-blank lines share the same total character count
/// (= pane width). At least one must have trailing whitespace padding.
///
/// Two rejoining strategies depending on the trailing-whitespace distribution:
///
/// **Gap-based mode** — the trailing-whitespace values cluster into two groups
/// (small gaps = continuations, large gaps = logical line endings). Typical for
/// wrapped URLs or long tokens. Continuations are concatenated without spaces.
///
/// **Paragraph mode** — all lines have similar trailing padding (no clear gap
/// between continuation and end-of-line). Classic prose / command wrapping.
/// Lines are joined with spaces; blank lines become paragraph breaks.
func fixSoftWrap(_ text: String) -> String? {
    let lines = text.components(separatedBy: "\n")

    let nonBlankLines = lines.filter { !$0.trimmingTrailingWhitespace().isEmpty }
    guard nonBlankLines.count >= 2 else { return nil }

    // Detect pane width: most common line length among non-blank lines.
    let lengths = nonBlankLines.map { $0.count }
    let lengthCounts = Dictionary(lengths.map { ($0, 1) }, uniquingKeysWith: +)
    let (paneWidth, modeCount) = lengthCounts.max(by: { $0.value < $1.value })!
    let uniformRatio = Double(modeCount) / Double(nonBlankLines.count)

    guard uniformRatio >= paddedLineRatio else { return nil }

    let linesAtPaneWidth = nonBlankLines.filter { $0.count == paneWidth }

    // At least one line must show trailing-whitespace padding to confirm
    // this really is terminal-padded text.
    let hasPaddedLine = linesAtPaneWidth.contains {
        $0.trailingWhitespaceCount >= trailingWsThreshold
    }
    guard hasPaddedLine else { return nil }

    let stripped = lines.map { $0.trimmingTrailingWhitespace() }
    let nonBlankStripped = stripped.filter { !$0.trimmingLeadingWhitespace().isEmpty }

    // Compute the trailing-whitespace gap (paneWidth - strippedLength) for each
    // non-blank line.  Small gaps mean near-full content (continuation); large
    // gaps mean short content (end of a logical line).
    let gaps = nonBlankStripped.map { paneWidth - $0.count }
    let sortedGaps = gaps.sorted()

    // Find the first significant jump in sorted gaps to separate the two
    // clusters.  "Significant" = jump >= minGapJump characters.
    let minGapJump = 5
    var gapThreshold: Int? = nil
    for i in 0..<(sortedGaps.count - 1) {
        let jump = sortedGaps[i + 1] - sortedGaps[i]
        if jump >= minGapJump {
            gapThreshold = (sortedGaps[i] + sortedGaps[i + 1]) / 2
            break
        }
    }

    if let threshold = gapThreshold {
        // Clear gap between continuation lines and logical-line endings.
        // Concatenate continuations without spaces (the wrap broke at an
        // exact character boundary).
        return rejoinByGapThreshold(stripped, paneWidth: paneWidth,
                                    gapThreshold: threshold, originalText: text)
    }

    // No clear gap — all lines are similarly padded (classic prose wrapping).
    // Fall back to paragraph-based rejoining with spaces.
    guard linesAtPaneWidth.allSatisfy({ $0.trailingWhitespaceCount >= trailingWsThreshold }) else {
        return nil
    }
    return rejoinAsParagraphs(stripped, originalText: text)
}

/// Rejoin lines using an adaptive gap threshold (for wrapped URLs / tokens).
/// Lines with trailing-whitespace gap > threshold mark the end of a logical line.
func rejoinByGapThreshold(_ stripped: [String], paneWidth: Int,
                          gapThreshold: Int, originalText: String) -> String? {
    var result: [String] = []
    var current = ""
    var lastBlank = false

    for line in stripped {
        let content = line.trimmingLeadingWhitespace()

        if content.isEmpty {
            if !current.isEmpty { result.append(current); current = "" }
            if !lastBlank && !result.isEmpty { result.append("") }
            lastBlank = true
            continue
        }
        lastBlank = false

        current = current.isEmpty ? content : current + content

        // Gap larger than the threshold = end of a logical line.
        let gap = paneWidth - line.count
        if gap > gapThreshold {
            result.append(current)
            current = ""
        }
    }
    if !current.isEmpty { result.append(current) }
    while result.last?.isEmpty == true { result.removeLast() }

    let output = result.joined(separator: "\n")
    return output == originalText ? nil : output
}

/// Rejoin lines using blank-line paragraph detection (for padded prose).
func rejoinAsParagraphs(_ stripped: [String], originalText: String) -> String? {
    var paragraphs: [[String]] = [[]]
    var lastWasBlank = false

    for line in stripped {
        if line.trimmingLeadingWhitespace().isEmpty {
            if !lastWasBlank && !paragraphs[paragraphs.count - 1].isEmpty {
                paragraphs.append([])
            }
            lastWasBlank = true
        } else {
            paragraphs[paragraphs.count - 1].append(line.trimmingLeadingWhitespace())
            lastWasBlank = false
        }
    }

    let output = paragraphs
        .filter { !$0.isEmpty }
        .map { $0.joined(separator: " ") }
        .joined(separator: "\n\n")
    return output == originalText ? nil : output
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
