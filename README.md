# clipboard-unwrap-from-terminal

Fixes soft-wrapped text when copying from narrow terminal panes.

When you copy text from a narrow pane in Warp, Terminal, or iTerm2, soft-wrapped lines become real newlines—breaking URLs, commands, and file paths. This tool monitors the clipboard and silently rejoins them.

## How it works

Terminals pad every line with trailing spaces to fill the pane width. The tool detects this by checking if most lines share the same total character count (content + padding). If they do, it strips the padding and rejoins consecutive non-blank lines. Blank lines are preserved as paragraph breaks.

Runs as a macOS LaunchAgent, polling `NSPasteboard.changeCount` every 200ms (essentially zero CPU). Only processes text when a terminal app is frontmost.

## Install

Compile:

```bash
swiftc -O -o clipboard-unwrap-from-terminal clipboard-unwrap-from-terminal.swift
```

Create `~/Library/LaunchAgents/com.pjh.clipboard-unwrap-from-terminal.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pjh.clipboard-unwrap-from-terminal</string>
    <key>ProgramArguments</key>
    <array>
        <string>/full/path/to/clipboard-unwrap-from-terminal</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
```

Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.pjh.clipboard-unwrap-from-terminal.plist
```

## Debugging

Run directly with flags:

```bash
./clipboard-unwrap-from-terminal --verbose    # logs all fixes to stderr
./clipboard-unwrap-from-terminal --dry-run    # logs fixes without modifying clipboard
```

## Known limitation

If you copy indented code from a narrow terminal pane, the indentation will be stripped. The uniform-width signal can't distinguish soft-wrapped prose from intentionally indented code that the terminal padded.
