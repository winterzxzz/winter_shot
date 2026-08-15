// Renders the styled installer background for the release dmg.
// Usage: swift scripts/render-dmg-background.swift <output.png>
// The PNG is written at 2x pixels with a 660x400pt logical size so Finder
// draws it retina-sharp at the window size set by scripts/release.sh.
//
// Layout (matches winter_voice's installer): brand header with tagline,
// numbered dashed rings around the two drop targets, a gradient drag arrow
// between them, nameplate capsules under the icons, and a brand strip along
// the bottom.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-dmg-background.swift <output.png>\n".utf8))
    exit(1)
}
let outputURL = URL(fileURLWithPath: arguments[1])

let pointSize = NSSize(width: 660, height: 400)
let scale: CGFloat = 2

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(pointSize.width * scale),
    pixelsHigh: Int(pointSize.height * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: scale, y: scale)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func blend(_ from: UInt32, _ to: UInt32, _ t: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: lerp(CGFloat((from >> 16) & 0xFF), CGFloat((to >> 16) & 0xFF), t) / 255,
        green: lerp(CGFloat((from >> 8) & 0xFF), CGFloat((to >> 8) & 0xFF), t) / 255,
        blue: lerp(CGFloat(from & 0xFF), CGFloat(to & 0xFF), t) / 255,
        alpha: alpha
    )
}

// AppKit coordinates: origin bottom-left. Design positions are given from
// the window top, so convert through `fromTop`.
func fromTop(_ y: CGFloat) -> CGFloat { pointSize.height - y }

let accentBlue: UInt32 = 0x3B82F6
let accentSky: UInt32 = 0x60A5FA

// Deep navy canvas with glows seated behind each drop target.
let bounds = NSRect(origin: .zero, size: pointSize)
NSGradient(colors: [color(0x151824), color(0x0A0B10)])!.draw(in: bounds, angle: -90)

func glow(_ hex: UInt32, alpha: CGFloat, centerTopY: NSPoint, radius: CGFloat) {
    let center = NSPoint(x: centerTopY.x, y: fromTop(centerTopY.y))
    NSGradient(starting: color(hex, alpha), ending: color(hex, 0))!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

glow(accentBlue, alpha: 0.10, centerTopY: NSPoint(x: 330, y: 40), radius: 240)
glow(accentSky, alpha: 0.08, centerTopY: NSPoint(x: 165, y: 200), radius: 170)
glow(accentBlue, alpha: 0.10, centerTopY: NSPoint(x: 495, y: 200), radius: 170)

// Faint blueprint grid.
color(0xFFFFFF, 0.022).setStroke()
var gridX: CGFloat = 30
while gridX < pointSize.width {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: gridX, y: 0))
    line.line(to: NSPoint(x: gridX, y: pointSize.height))
    line.lineWidth = 0.5
    line.stroke()
    gridX += 60
}
var gridY: CGFloat = 20
while gridY < pointSize.height {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 0, y: gridY))
    line.line(to: NSPoint(x: pointSize.width, y: gridY))
    line.lineWidth = 0.5
    line.stroke()
    gridY += 60
}

// Corner brackets framing the canvas.
let bracketInset: CGFloat = 22
let bracketArm: CGFloat = 16
color(0xFFFFFF, 0.22).setStroke()
for (cornerX, cornerY, dirX, dirY) in [
    (bracketInset, bracketInset, 1.0, 1.0),
    (pointSize.width - bracketInset, bracketInset, -1.0, 1.0),
    (bracketInset, pointSize.height - bracketInset, 1.0, -1.0),
    (pointSize.width - bracketInset, pointSize.height - bracketInset, -1.0, -1.0),
] {
    let bracket = NSBezierPath()
    bracket.move(to: NSPoint(x: cornerX + CGFloat(dirX) * bracketArm, y: cornerY))
    bracket.line(to: NSPoint(x: cornerX, y: cornerY))
    bracket.line(to: NSPoint(x: cornerX, y: cornerY + CGFloat(dirY) * bracketArm))
    bracket.lineWidth = 1.5
    bracket.stroke()
}

func attributedText(
    _ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, kern: CGFloat = 0
) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(0xFFFFFF, alpha),
        .kern: kern,
    ])
}

func drawCentered(_ text: NSAttributedString, centerX: CGFloat, topY: CGFloat) {
    let textSize = text.size()
    text.draw(at: NSPoint(x: centerX - textSize.width / 2, y: fromTop(topY) - textSize.height / 2))
}

// Brand header: viewfinder-snowflake mark beside the wordmark, tagline
// underneath. The mark echoes the app icon — capture brackets around a
// six-spoke snowflake.
let wordmark = attributedText("WinterShot", size: 24, weight: .bold, alpha: 0.95, kern: 0.3)
let markSize: CGFloat = 28
let headerGap: CGFloat = 12
let headerWidth = markSize + headerGap + wordmark.size().width
let headerCenterTopY: CGFloat = 58
let markCenter = NSPoint(
    x: (pointSize.width - headerWidth) / 2 + markSize / 2,
    y: fromTop(headerCenterTopY)
)

// Capture brackets on the mark's four corners.
let markHalf = markSize / 2
let markArm: CGFloat = 7
color(accentSky, 0.9).setStroke()
for (dirX, dirY) in [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] {
    let cornerX = markCenter.x - CGFloat(dirX) * markHalf
    let cornerY = markCenter.y - CGFloat(dirY) * markHalf
    let bracket = NSBezierPath()
    bracket.move(to: NSPoint(x: cornerX + CGFloat(dirX) * markArm, y: cornerY))
    bracket.line(to: NSPoint(x: cornerX, y: cornerY))
    bracket.line(to: NSPoint(x: cornerX, y: cornerY + CGFloat(dirY) * markArm))
    bracket.lineWidth = 2.5
    bracket.lineCapStyle = .round
    bracket.lineJoinStyle = .round
    bracket.stroke()
}

// Six-spoke snowflake with side ticks on each spoke.
let spokeLength: CGFloat = 9
let tickLength: CGFloat = 3
for spoke in 0..<6 {
    let angle = CGFloat(spoke) * .pi / 3 + .pi / 6
    let direction = NSPoint(x: cos(angle), y: sin(angle))
    let tip = NSPoint(
        x: markCenter.x + direction.x * spokeLength,
        y: markCenter.y + direction.y * spokeLength
    )
    let line = NSBezierPath()
    line.move(to: markCenter)
    line.line(to: tip)
    line.lineWidth = 2
    line.lineCapStyle = .round
    color(0xDBEAFE, 0.95).setStroke()
    line.stroke()
    // Ticks branching off at 60° near the tip.
    let branchBase = NSPoint(
        x: markCenter.x + direction.x * spokeLength * 0.62,
        y: markCenter.y + direction.y * spokeLength * 0.62
    )
    for side in [-1.0, 1.0] {
        let branchAngle = angle + CGFloat(side) * .pi / 3
        let tick = NSBezierPath()
        tick.move(to: branchBase)
        tick.line(to: NSPoint(
            x: branchBase.x + cos(branchAngle) * tickLength,
            y: branchBase.y + sin(branchAngle) * tickLength
        ))
        tick.lineWidth = 1.5
        tick.lineCapStyle = .round
        tick.stroke()
    }
}

wordmark.draw(at: NSPoint(
    x: (pointSize.width - headerWidth) / 2 + markSize + headerGap,
    y: fromTop(headerCenterTopY) - wordmark.size().height / 2
))
drawCentered(
    attributedText("CAPTURE. ANNOTATE. RECORD.", size: 10, weight: .semibold, alpha: 0.42, kern: 3.2),
    centerX: 330, topY: 92
)

// Numbered dashed rings around the two drop targets. Finder seats the app
// icon and the Applications folder (100pt icons) at these centers.
let targetCenters: [(x: CGFloat, hex: UInt32)] = [(165, accentSky), (495, accentBlue)]
let targetCenterTopY: CGFloat = 192
let ringRadius: CGFloat = 78
for (index, target) in targetCenters.enumerated() {
    let center = NSPoint(x: target.x, y: fromTop(targetCenterTopY))
    let ring = NSBezierPath(ovalIn: NSRect(
        x: center.x - ringRadius, y: center.y - ringRadius,
        width: ringRadius * 2, height: ringRadius * 2
    ))
    ring.lineWidth = 1.5
    ring.setLineDash([4, 6], count: 2, phase: 0)
    color(target.hex, 0.45).setStroke()
    ring.stroke()

    // Step badge riding the top of the ring.
    let badgeCenter = NSPoint(x: center.x, y: center.y + ringRadius)
    let badgeRadius: CGFloat = 13
    let badge = NSBezierPath(ovalIn: NSRect(
        x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
        width: badgeRadius * 2, height: badgeRadius * 2
    ))
    color(0x0A0B10, 0.9).setFill()
    badge.fill()
    badge.lineWidth = 1.5
    color(target.hex, 0.9).setStroke()
    badge.stroke()
    let number = NSAttributedString(string: "\(index + 1)", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: color(target.hex, 0.95),
    ])
    let numberSize = number.size()
    number.draw(at: NSPoint(
        x: badgeCenter.x - numberSize.width / 2,
        y: badgeCenter.y - numberSize.height / 2
    ))
}

// Finder draws icon labels in BLACK whenever the view has a background
// picture (regardless of system appearance), and exposes no way to recolor
// them. To keep the titles readable on the dark canvas without a visible
// nameplate, bake a white glow shaped exactly like each label string at the
// label position — Finder's black text lands on the glow's core and reads
// as outlined text.
for (target, title) in [(targetCenters[0], "WinterShot"), (targetCenters[1], "Applications")] {
    let labelFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    let glow = NSShadow()
    glow.shadowColor = color(0xFFFFFF, 0.9)
    glow.shadowBlurRadius = 5
    glow.shadowOffset = .zero
    // Soft core: a crisp white core would show as doubled glyphs wherever
    // Finder's black text lands a pixel off; a diffuse halo hides that.
    let text = NSAttributedString(string: title, attributes: [
        .font: labelFont,
        .foregroundColor: color(0xFFFFFF, 0.25),
        .shadow: glow,
    ])
    let textSize = text.size()
    let origin = NSPoint(x: target.x - textSize.width / 2, y: fromTop(255.5) - textSize.height / 2)
    // Stack the shadowed draw a few times so the halo builds up solid.
    for _ in 0..<6 { text.draw(at: origin) }
}

// "DRAG TO INSTALL" with a gradient arc sweeping toward Applications.
drawCentered(
    attributedText("DRAG TO INSTALL", size: 11, weight: .bold, alpha: 0.75, kern: 3),
    centerX: 330, topY: 172
)
let arcStart = NSPoint(x: 252, y: fromTop(206))
let arcControl = NSPoint(x: 330, y: fromTop(222))
let arcEnd = NSPoint(x: 402, y: fromTop(196))
let arcSegments = 48
var previousPoint = arcStart
for segment in 1...arcSegments {
    let t = CGFloat(segment) / CGFloat(arcSegments)
    let mt = 1 - t
    let point = NSPoint(
        x: mt * mt * arcStart.x + 2 * mt * t * arcControl.x + t * t * arcEnd.x,
        y: mt * mt * arcStart.y + 2 * mt * t * arcControl.y + t * t * arcEnd.y
    )
    let stroke = NSBezierPath()
    stroke.move(to: previousPoint)
    stroke.line(to: point)
    stroke.lineWidth = 3
    stroke.lineCapStyle = .round
    blend(accentSky, accentBlue, t, 0.35 + 0.6 * t).setStroke()
    stroke.stroke()
    previousPoint = point
}
let head = NSBezierPath()
head.move(to: NSPoint(x: arcEnd.x - 9, y: arcEnd.y + 12))
head.line(to: NSPoint(x: arcEnd.x + 4, y: arcEnd.y + 1))
head.line(to: NSPoint(x: arcEnd.x - 12, y: arcEnd.y - 6))
head.lineWidth = 3
head.lineCapStyle = .round
head.lineJoinStyle = .round
color(accentBlue, 0.95).setStroke()
head.stroke()

// Bottom brand strip: letterspaced name over a gradient hairline.
drawCentered(
    attributedText("WINTERSHOT", size: 9, weight: .semibold, alpha: 0.35, kern: 4),
    centerX: 330, topY: 348
)
let hairline = NSBezierPath(
    roundedRect: NSRect(x: 150, y: fromTop(364) - 1.25, width: 360, height: 2.5),
    xRadius: 1.25, yRadius: 1.25
)
NSGradient(colors: [
    color(accentSky, 0), color(accentSky, 0.8), color(accentBlue, 0.8), color(accentBlue, 0),
])!.draw(in: hairline, angle: 0)

NSGraphicsContext.restoreGraphicsState()

// The logical (point) size must be stamped so Finder renders the 2x
// pixels at 660x400 instead of doubling the window.
rep.size = pointSize
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: outputURL)
print("wrote \(outputURL.path)")
