# Development

Everything you need to build WinterShot from source, plus the shape of the codebase.

## Requirements

- macOS 14.0+
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

The project has **zero third-party runtime dependencies**; the Xcode project itself is generated from [`project.yml`](../project.yml), so it is not checked in as the source of truth.

## Building

```sh
xcodegen generate
open WinterShot.xcodeproj
```

Or straight from the command line:

```sh
xcodebuild -project WinterShot.xcodeproj -scheme WinterShot -configuration Release build
```

The built app lands in `~/Library/Developer/Xcode/DerivedData/WinterShot-*/Build/Products/Release/WinterShot.app`.

### Signing

`project.yml` pins `CODE_SIGN_IDENTITY: "Apple Development"` and a `DEVELOPMENT_TEAM`, deliberately: macOS keys the Screen Recording (TCC) grant to the app's designated requirement, which for an Apple Development certificate is its identifier plus the certificate's common name — no cdhash. Signing every build with the *same* identity means the permission survives rebuilds and reinstalls, while ad-hoc (`-`) signing re-prompts every time.

If the pinned team isn't in your keychain, override it on the command line rather than editing the file:

```sh
xcodebuild -project WinterShot.xcodeproj -scheme WinterShot -configuration Release \
  DEVELOPMENT_TEAM=YOURTEAMID CODE_SIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)" build
```

Check what a build will ask TCC for with `codesign -d -r- /Applications/WinterShot.app`.

Install it where the permission grants live:

```sh
ditto ~/Library/Developer/Xcode/DerivedData/WinterShot-*/Build/Products/Release/WinterShot.app /Applications/WinterShot.app
```

### Releasing

```sh
scripts/release.sh 0.3.0
```

Bump `CFBundleShortVersionString` in `project.yml` first — the script refuses to run if the two disagree. It builds Release, packages a styled `.dmg` (rendered background, volume icon, Finder layout) plus a `.zip`, and publishes both to GitHub with `gh`.

## Launch arguments

The app is scriptable for testing and for capturing documentation — every flag is handled at launch:

| Flag | What it does |
|---|---|
| `--open-main` | Opens the main window (library + editor) |
| `--edit <name>.png\|.mp4` | Opens the editor on a capture in the library — the studio editor for a recording |
| `--show <name>` | Opens the main window with that capture selected (a recording shows its detail pane, not the studio editor) |
| `--capture <area\|window\|fullscreen>` | Runs a capture immediately |
| `--history` | Drops the notch history panel |
| `--open-recording <path.mp4>` | Opens the studio editor for a recording |
| `--preview-image <path>` | Shows the post-capture thumbnail card (repeatable — stacks) |
| `--show-recording-hud` | Shows the recording timer pill without recording |
| `--snapshot-windows <dir>` | Writes a PNG of every open window 5 s after launch, then quits |
| `--login-item <on\|off\|status>` | Flips or reads "Open at login", prints the resulting state, exits |
| `--ocr <name>.png` | Runs OCR through the app's pipeline, prints the text, exits |
| `--export-recording <in> <out>` | Headless export with the recording's saved edit (or the defaults); `--export-options <json>` supplies `RecordingExportOptions` instead |

```sh
open -a WinterShot --args --edit WinterShot-20260818-101204.png
```

A few environment variables complete the picture for scripted runs and documentation shoots:

| Variable | What it does |
|---|---|
| `WS_CAPTURES_DIR=<dir>` | Uses that folder as the library instead of `~/Library/Application Support/WinterShot/Captures` — stage a demo library without touching your own |
| `WS_EDITOR_PANEL=background\|cursor\|animations` | Opens the studio editor on that panel |
| `WS_EDITOR_OPTIONS=<json>` | Opens the studio editor with those `RecordingExportOptions` (they are saved as the recording's edit, like any change) |
| `WS_EDITOR_MODE=crop\|mask` | Opens the studio editor straight into crop or mask mode |
| `WS_EDITOR_OCR=1` | Runs OCR as soon as the screenshot editor opens |

## Architecture

Clean Architecture with MVVM in the presentation layer. Dependencies point inward — the Domain layer imports nothing but Foundation/CoreGraphics.

```
WinterShot/
├── App/                     Composition root
│   ├── WinterShotApp.swift    SwiftUI scenes (MenuBarExtra, main Window, Settings)
│   ├── AppDelegate.swift      Status item, hotkeys, launch arguments, window opening
│   └── DIContainer.swift      Wires Data impls to Domain protocols
├── Domain/                  Pure business logic — no SwiftUI, no AppKit
│   ├── Entities/              Screenshot, Recording, CaptureItem, Annotation, BackdropStyle, CaptureMode
│   ├── Repositories/          Protocols (ScreenshotRepository, RecordingRepository, AnnotationRepository, OCRService)
│   └── UseCases/              One intent per type (CaptureScreenshot, SaveAnnotations, RecognizeText, …)
├── Data/                    Implementations of Domain protocols
│   ├── Services/              ScreenCaptureKit capture, screen recording, compositor/exporter, Vision OCR
│   ├── Storage/               FileScreenshotStore (library layout + sidecars)
│   └── Repositories/          ScreenshotRepositoryImpl, RecordingRepositoryImpl, AnnotationRepositoryImpl
└── Presentation/            MVVM — each screen is View + ViewModel
    ├── Main/                  Main window: captures sidebar + detail
    ├── Editor/                Canvas, toolbar, inspector
    ├── AreaPicker/            Frozen-screen selector with loupe and window lifting
    ├── WindowPicker/          Window capture picker
    ├── Recorder/              Recording controller, HUD, studio editor, export
    ├── Notch/                 Notch history panel
    ├── Preview/               Post-capture thumbnail cards
    ├── Pin/                   Floating pinned-shot panels
    ├── Onboarding/            First-run permission + hotkey steps
    ├── Settings/              Appearance, preview, storage, hotkey, about
    └── Common/                AnnotationRenderer (shared by editor + export)
```

**Data flow:** View → ViewModel → UseCase → Repository protocol → Data implementation. ViewModels never touch the file system or Vision directly; Domain types never import SwiftUI.

**Rendering:** `AnnotationRenderer` draws into a SwiftUI `GraphicsContext` and is shared by the live canvas and the flattened export, so what you see is exactly what ships. The recording compositor runs on the GPU for the same reason — the studio preview and the exported MP4 come out of the same pipeline.

## Storage layout

```
~/Library/Application Support/WinterShot/Captures/
  WinterShot-20260818-101204.png         immutable capture
  WinterShot-20260818-101204.wshot.json  sidecar: metadata, annotations, crop, backdrop
  WinterShot-20260818-100815.mp4         immutable recording
  WinterShot-20260818-100815.wsrec.json  sidecar: cursor samples, clicks, frame timing, duration
  WinterShot-20260818-100815.wsedit.json sidecar: the studio editor's options, written once the take is edited
```

Sidecars sit next to their file so the set can't drift apart, and are flagged hidden so Finder shows only pictures and movies — press ⌘⇧. in Finder to reveal them. The library lists both kinds of file; a PNG or MP4 dropped into the folder by hand shows up too, without a sidecar.

All sidecars are plain `Codable` JSON (`ScreenshotSidecar`, `RecordingEventLog`, `RecordingEditSidecar`), which makes them easy to author or inspect by hand when you are testing the editors. The studio editor autosaves its options into the `.wsedit.json` half a second after each change and when its window closes; `--export-recording` without `--export-options` renders exactly that edit.
