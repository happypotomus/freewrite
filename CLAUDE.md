# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **IMPORTANT**: `CLAUDE.md` and `AGENTS.md` are clones and must be kept in sync. Mirror any substantial changes (architecture, data flow, storage, threading, permissions, major bug fixes) to both files immediately. Skip syncing for minor UI tweaks or copy edits.

## Build Commands

```bash
# Build
xcodebuild -project freewrite.xcodeproj -scheme freewrite -configuration Debug build

# Clean build
xcodebuild -project freewrite.xcodeproj -scheme freewrite -configuration Debug clean build
```

Open `freewrite.xcodeproj` in Xcode and click Run to develop interactively.

## Architecture

Native macOS SwiftUI app (macOS 14+, Swift 5). No backend — all data is local in `~/Documents/Freewrite/`.

**Source files** (all in `freewrite/`):
- `ContentView.swift` — entire UI and business logic (~2250 lines)
- `VideoRecordingView.swift` — camera capture via AVFoundation + speech transcription via Speech framework (~850 lines)
- `VideoPlayerView.swift` — simple AVKit-based playback wrapper (~260 lines)
- `freewriteApp.swift` — app entry point (~50 lines)

**ContentView.swift layout by line range:**
- 1–230: Imports, data models (`HumanEntry`, `EntryType`), `@State` variables, constants, AI prompt strings
- 230–500: Private helper functions (file paths, video asset management, thumbnails, transcripts, filename parsing)
- 500–865: Video recording preflight, permission checks, permission popover logic
- 865–1745: Main `var body` and UI
- 1745–2060: Entry CRUD (save/load/delete), chat/export actions
- 2060–2220: PDF export (title extraction, `createPDFFromText`)
- 2220–2256: Helper extension (`getLineHeight`, `NSView` extension)

## Data Model

```swift
enum EntryType { case text, video }

struct HumanEntry: Identifiable {
    let id: UUID
    let date: String        // Display: "MMM d" (e.g. "Feb 20"), no year
    let filename: String    // "[UUID]-[YYYY-MM-DD-HH-mm-ss].md"
    var previewText: String // First 30 chars or "Video Entry"
    var entryType: EntryType
    var videoFilename: String?
}
```

## File Storage Layout

**Text entries** — `~/Documents/Freewrite/[UUID]-[YYYY-MM-DD-HH-mm-ss].md`

**Video entries:**
- Metadata: `~/Documents/Freewrite/[UUID]-[YYYY-MM-DD-HH-mm-ss].md` (contains "Video Entry")
- Video directory: `~/Documents/Freewrite/Videos/[UUID]-[YYYY-MM-DD-HH-mm-ss]/`
  - `[UUID]-[YYYY-MM-DD-HH-mm-ss].mov`
  - `thumbnail.jpg`
  - `transcript.md` (optional, from speech recognition)

The UUID ensures uniqueness across devices; brackets make regex extraction reliable: `\[(.*?)\]` and `\[(\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2})\]`.

Legacy video layouts (checked as fallbacks on load):
- `~/Documents/Freewrite/Videos/[entry].mov` (flat)
- `~/Documents/Freewrite/[entry].mov` (oldest)

## Threading Rules

**Critical**: SwiftUI's `ForEach` enumerates the `entries` array. Mutating it from an async context (AVFoundation callbacks, `DispatchQueue` callbacks) causes `NSGenericException: Collection was mutated while being enumerated`.

Always wrap `entries` mutations from async contexts in `DispatchQueue.main.async { }`. In `loadExistingEntries()`, build a local array and assign once to `entries`.

Threading breakdown:
- Main thread: all UI updates and `@State` mutations
- Global queue: file I/O
- AVFoundation queue: camera setup and capture

## AVCaptureSession Rules

Always bracket input/output changes with `beginConfiguration()` / `commitConfiguration()`. Without this, concurrent enumeration of internal session arrays causes crashes.

Additional safety rules:
- Guard `setupCamera()` with a `isSettingUpSession` in-flight flag — permission callbacks and `onAppear` can fire multiple times
- Call `startRunning()` exactly once per setup cycle
- Attach `AVCaptureVideoPreviewLayer` only after `startRunning()` completes
- Teardown: call `stopRunning()` and release references; avoid removing inputs/outputs during active session transitions

## Key Non-Obvious Behaviors

**Video overlay**: `VideoRecordingView` is rendered via `.overlay` on `ContentView` with **no transitions** (plain swap). Do not add animations to open/close.

**Entry text prefix**: Every text entry content starts with `\n\n`. The `TextEditor` binding enforces this. This is intentional for visual breathing room — preserve it.

**Date comparison gotcha**: Display dates store "MMM d" without a year (defaults to year 1 in `DateFormatter`). To check "is this today?", extract month/day, inject the current year, then compare. See existing `isFromTodayAndEmpty` logic.

**Backspace disable** uses `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` and swallows key codes 51 (backspace) and 117 (forward delete).

**Timer scroll**: Scroll wheel adjusts timer in 5-minute increments via `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)`.

**Thumbnail orientation**: Always set `imageGenerator.appliesPreferredTrackTransform = true` when generating thumbnails — front camera video contains a rotation transform that must be applied or the thumbnail will be sideways.

**Chat URL limit**: URLs >6000 chars fail in some browsers. The chat button falls back to "Copy Prompt" when the encoded text exceeds this.

**Only `colorScheme` is persisted** in `UserDefaults` ("light"/"dark"). Font size, font family, timer duration, and backspace state are session-only.

## Permissions

Entitlements in `freewrite.entitlements`: app-sandbox, user-selected file read-write, camera, audio-input, speech-recognition.

Privacy keys in Xcode build settings: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.

All three permissions (camera + microphone + speech) must be granted before `VideoRecordingView` is presented. If any is missing, a popover above the camera icon explains what's missing and links to System Settings.

## Adding Navigation Bar Items

Bottom nav is built around line 500–950 in `ContentView.swift`. Pattern: `Text("•")` separator, then a `Button` with `.buttonStyle(.plain)`, `.onHover` that pushes/pops `NSCursor.pointingHand`, and sets `isHoveringBottomNav = true/false`.
