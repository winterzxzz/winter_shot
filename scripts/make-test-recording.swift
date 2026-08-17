// Generates a synthetic WinterShot recording for exercising the export
// pipeline without Screen Recording permission: a variable-frame-rate H.264
// "desktop" (frames only when something changes, exactly like a
// ScreenCaptureKit capture — 53 frames over 14 s) plus a .wsrec.json sidecar
// with a smooth cursor path and clicks near edges and in clusters.
//
//   swift scripts/make-test-recording.swift /tmp/testrec
//   WinterShot.app/Contents/MacOS/WinterShot --export-recording /tmp/testrec/test.mp4 /tmp/testrec/out.mp4 \
//       [--export-options options.json]      # RecordingExportOptions as JSON
//   WinterShot.app/Contents/MacOS/WinterShot --open-recording /tmp/testrec/test.mp4
//   (WS_EDITOR_PANEL=cursor|animations|background and WS_EDITOR_OPTIONS=options.json
//    open the editor on a panel / with given options — handy for screenshots)
//
// Then e.g. `ffmpeg -ss 1.2 -i out.mp4 -frames:v 12 f_%02d.png` to eyeball the
// zoom-in frame by frame.
import AVFoundation
import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let videoURL = outDir.appendingPathComponent("test.mp4")
let sidecarURL = outDir.appendingPathComponent("test.wsrec.json")
try? FileManager.default.removeItem(at: videoURL)

let W = 2880, H = 1800          // 1440×900 @2x
let scale = 2.0
let duration = 14.0

// --- Cursor script (points, top-left origin like the screen) ---------------
// (time, x, y) waypoints; the cursor eases between them, pauses at each.
struct Way { let t: Double; let x: Double; let y: Double; let click: Bool }
let ways: [Way] = [
    Way(t: 0.0, x: 720, y: 450, click: false),
    Way(t: 1.5, x: 300, y: 260, click: true),    // click near left, cluster A
    Way(t: 2.2, x: 340, y: 300, click: true),    // second click same area
    Way(t: 3.0, x: 420, y: 330, click: false),
    Way(t: 4.6, x: 1380, y: 120, click: true),   // click near top-right corner (edge snap)
    Way(t: 5.5, x: 1400, y: 160, click: false),
    Way(t: 8.6, x: 700, y: 620, click: true),    // new range after >2.5s gap
    Way(t: 9.4, x: 900, y: 660, click: false),   // typing... moving inside cluster
    Way(t: 10.4, x: 1000, y: 700, click: false),
    Way(t: 12.5, x: 720, y: 450, click: false),
]

func easeInOut(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
func cursorAt(_ t: Double) -> (Double, Double) {
    if t <= ways[0].t { return (ways[0].x, ways[0].y) }
    for i in 1..<ways.count {
        let a = ways[i - 1], b = ways[i]
        if t <= b.t {
            // pause for the first 30% of the segment, then move
            let seg = (t - a.t) / (b.t - a.t)
            let f = seg < 0.3 ? 0 : easeInOut((seg - 0.3) / 0.7)
            return (a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
        }
    }
    return (ways.last!.x, ways.last!.y)
}

// --- Video ------------------------------------------------------------------
let writer = try! AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000,
                                      AVVideoExpectedSourceFrameRateKey: 60],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func drawDesktop(_ ctx: CGContext, t: Double) {
    // wallpaper gradient
    let g = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.35, green: 0.45, blue: 0.75, alpha: 1),
                                                CGColor(srgbRed: 0.75, green: 0.35, blue: 0.55, alpha: 1)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: W, y: H), options: [])
    // menu bar
    ctx.setFillColor(CGColor(gray: 0.95, alpha: 0.9)); ctx.fill(CGRect(x: 0, y: H - 48, width: W, height: 48))
    // a "window" with title bar and text lines
    let win = CGRect(x: 240, y: 240, width: 2200, height: 1300)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(win)
    ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(CGRect(x: win.minX, y: win.maxY - 60, width: win.width, height: 60))
    // sidebar
    ctx.setFillColor(CGColor(gray: 0.94, alpha: 1)); ctx.fill(CGRect(x: win.minX, y: win.minY, width: 380, height: win.height - 60))
    // text lines (thin dark bars) — fine detail to judge sharpness
    ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
    var y = win.maxY - 130.0
    var row = 0
    while y > win.minY + 40 {
        let w = [900.0, 1400, 1100, 600, 1300, 800][row % 6]
        ctx.fill(CGRect(x: win.minX + 440, y: y, width: w, height: 8))
        // small "words" gaps
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        var gx = win.minX + 440 + 120
        while gx < win.minX + 440 + w { ctx.fill(CGRect(x: gx, y: y, width: 12, height: 8)); gx += 140 }
        ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
        y -= 44; row += 1
    }
    // buttons near the click targets (points→px, top-left → bottom-left)
    func btn(_ px: Double, _ py: Double, _ label: String, on: Bool) {
        let r = CGRect(x: px * scale - 120, y: Double(H) - py * scale - 40, width: 240, height: 80)
        ctx.setFillColor(on ? CGColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 1) : CGColor(gray: 0.85, alpha: 1))
        ctx.fill(r)
        ctx.setFillColor(CGColor(gray: on ? 1 : 0.2, alpha: 1))
        ctx.fill(CGRect(x: r.minX + 40, y: r.midY - 6, width: r.width - 80, height: 12))
    }
    btn(300, 260, "A", on: t >= 1.5 && t < 2.2)
    btn(340, 300, "B", on: t >= 2.2)
    btn(1380, 120, "C", on: t >= 4.6)
    btn(700, 620, "D", on: t >= 8.6)
    // a caret blinking every 0.5 s in the "editor" after the last click
    if t >= 8.6, Int(t * 2) % 2 == 0 {
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 1800 + (t - 8.6) * 60, y: 1300 - 40, width: 4, height: 40))
    }
    // a progress bar animating between 5.0 and 5.6 s (activity burst)
    if t >= 5.0 {
        let p = min(1, (t - 5.0) / 0.6)
        ctx.setFillColor(CGColor(gray: 0.8, alpha: 1)); ctx.fill(CGRect(x: 1200, y: 400, width: 800, height: 20))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 1)); ctx.fill(CGRect(x: 1200, y: 400, width: 800 * p, height: 20))
    }
}

// Frame times: only when the desktop actually changes (VFR with big gaps).
var frameTimes: [Double] = [0]
for t in [1.5, 2.2, 4.6, 8.6] { frameTimes.append(t) }         // button state changes
var t = 5.0; while t <= 5.6 { frameTimes.append(t); t += 1.0 / 60 } // progress burst @60fps
t = 8.6; while t < duration { frameTimes.append(t); t += 0.5 }      // caret blink
frameTimes.append(duration - 0.02)
frameTimes = Array(Set(frameTimes.map { ($0 * 1000).rounded() / 1000 })).sorted()

let pool = adaptor.pixelBufferPool!
for ft in frameTimes {
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    drawDesktop(ctx, t: ft)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    while !input.isReadyForMoreMediaData { usleep(2000) }
    adaptor.append(pb!, withPresentationTime: CMTime(seconds: ft, preferredTimescale: 600))
}
input.markAsFinished()
let sema = DispatchSemaphore(value: 0)
writer.finishWriting { sema.signal() }
sema.wait()
print("video: \(frameTimes.count) frames, \(duration)s → \(videoURL.path)")

// --- Sidecar ------------------------------------------------------------------
// Times are host-clock seconds; use an arbitrary base so relative math is real.
let base = 1000.0
var samples: [[String: Double]] = []
var st = 0.0
while st <= duration {
    let (x, y) = cursorAt(st)
    // video px, bottom-left origin
    samples.append(["t": base + st, "x": x * scale, "y": Double(H) - y * scale])
    st += 1.0 / 120
}
let clicks: [[String: Double]] = ways.filter { $0.click }.map { w in
    ["t": base + w.t, "x": w.x * scale, "y": Double(H) - w.y * scale]
}
let iso = ISO8601DateFormatter()
let log: [String: Any] = [
    "recordingID": UUID().uuidString,
    "createdAt": Date().timeIntervalSinceReferenceDate,
    "firstFrameTime": base,
    "frameWidth": Double(W), "frameHeight": Double(H),
    "pixelScale": scale,
    "cursorSamples": samples,
    "clicks": clicks,
]
let data = try! JSONSerialization.data(withJSONObject: log, options: [.sortedKeys])
try! data.write(to: sidecarURL)
print("sidecar: \(samples.count) samples, \(clicks.count) clicks → \(sidecarURL.path)")
