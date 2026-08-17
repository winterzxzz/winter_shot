# WinterShot

A native macOS menu-bar screenshot tool inspired by [BridgeShot](https://www.bridgemind.ai/products/bridgeshot) — capture, annotate with a real editor, and ship share-ready shots. Pure SwiftUI, 100% on-device, and non-destructive by design.

## Features

- **Capture** — area and window with a frozen-screen selector (ScreenCaptureKit): the screen freezes, a pixel loupe with live coordinates follows the cursor, and windows lift out of a dimmed backdrop as you hover — a click captures the window clean even when partially covered. Fullscreen uses the system capture tool. After every capture a thumbnail slides in at the screen edge; click it to open the editor.
- **Screen recording (beta)** — Screen Studio-style recordings, fully on-device. "Record Screen" in the menu bar records the display under your cursor with ScreenCaptureKit; the real cursor is kept out of the pixels while its motion and clicks are logged to a `.wsrec.json` sidecar. On stop, a Screen Studio-style editor opens: a wallpaper / gradient / color / image backdrop with blur, padding, corners and shadow; output aspect ratios for YouTube, Reels or feeds; a non-destructive crop (with aspect lock); masks that blur sensitive data or spotlight a region for a stretch of the timeline; an auto-zoom camera that glides to wherever you're clicking (and holds still while you work there); a smoothed synthetic cursor with click circles and tilt that mirrors the pointer the app was showing (text cursor, hand, resize arrows…) or a pointer you pick, in macOS, light or dark coloring; cinematic motion blur; presets, undo/redo, and a timeline of the clip and zoom ranges. Everything is composited on the GPU, so the live preview is exactly the 60 fps MP4 you export. The raw recording stays untouched — re-export with different looks anytime.
- **Nine annotation tools** — arrow, rectangle, ellipse, line, freehand, text, numbered counters, highlighter, and redact.
- **Non-destructive by design** — annotations and the crop live in a `.wshot.json` sidecar next to the image. Reopen any screenshot later and every arrow is still editable and the crop reversible; pixels are flattened only on export.
- **Crop** — drag a rect with rule-of-thirds guides and a live size readout; the crop applies to the canvas, exports, copies, and pins, and can be reset at any time.
- **Background beautify** — pad the shot on a gradient backdrop with rounded corners and a soft shadow, ready for posts and docs. Seven presets plus padding, corner, and shadow controls; non-destructive and live in the editor.
- **On-device OCR** — recognize and copy text from any screenshot via Apple Vision. Nothing leaves your Mac.
- **Pin to screen** — float a shot above every window; drag to move, double-click to dismiss.
- **History** — a searchable library of every capture, reopenable in the editor with annotations intact.
- **One global hotkey** — ⌘⇧4 opens the area selector system-wide. Hover a window and it highlights — a single click captures the whole window; drag to capture an area instead. Every other feature lives in the menu bar icon. (If macOS's own ⌘⇧4 is still enabled both will fire — turn the system one off in System Settings → Keyboard → Keyboard Shortcuts → Screenshots.)
- **Menu-bar native** — no Dock icon, no Electron, zero third-party dependencies.

## Requirements

- macOS 14.0+
- Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

```sh
xcodegen generate
open WinterShot.xcodeproj
```

Or from the command line:

```sh
xcodebuild -project WinterShot.xcodeproj -scheme WinterShot -configuration Release build
```

On first capture, macOS will ask for Screen Recording permission (System Settings → Privacy & Security → Screen Recording).

## Architecture

Clean Architecture with MVVM in the presentation layer. Dependencies point inward — the Domain layer imports nothing but Foundation/CoreGraphics.

```
WinterShot/
├── App/                     Composition root
│   ├── WinterShotApp.swift    SwiftUI scenes (MenuBarExtra, Editor, History)
│   └── DIContainer.swift      Wires Data impls to Domain protocols
├── Domain/                  Pure business logic — no SwiftUI, no AppKit
│   ├── Entities/              Screenshot, Annotation, CaptureMode
│   ├── Repositories/          Protocols (ScreenshotRepository, AnnotationRepository, OCRService)
│   └── UseCases/              One intent per type (CaptureScreenshot, SaveAnnotations, RecognizeText, …)
├── Data/                    Implementations of Domain protocols
│   ├── Services/              SystemScreenCaptureService, VisionOCRService
│   ├── Storage/               FileScreenshotStore (library layout + sidecars)
│   └── Repositories/          ScreenshotRepositoryImpl, AnnotationRepositoryImpl
└── Presentation/            MVVM — each screen is View + ViewModel
    ├── MenuBar/               Capture entry points
    ├── Editor/                Canvas, toolbar, inspector
    ├── History/               Capture library grid
    ├── Pin/                   Floating pinned-shot panels
    └── Common/                AnnotationRenderer (shared by editor + export)
```

**Data flow:** View → ViewModel → UseCase → Repository protocol → Data implementation. ViewModels never touch the file system or Vision directly; Domain types never import SwiftUI.

**Storage:** captures live in `~/Library/Application Support/WinterShot/Captures/` as an immutable PNG plus a JSON sidecar holding metadata and editable annotations (recordings: an MP4 plus a `.wsrec.json` event log). Sidecars sit next to their file so the pair can't drift apart, but are flagged hidden so Finder shows only pictures and movies — press ⌘⇧. in Finder to reveal them.

## Roadmap

- Configurable hotkeys
- Space to toggle window/area mode mid-selection
- Multi-display fullscreen capture

## License

MIT
