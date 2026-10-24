// Draws the disk image's window background: a line asking the user to drag
// Insomnia onto Applications, and an arrow between the two icons, in the
// app's palette (Sources/Insomnia/UI/BrandPalette.swift). build-dmg.sh puts
// the icons at the centres used below.
//
//   swift scripts/generate-dmg-background.swift OUT_DIR
//
// Writes OUT_DIR/background.png (1x) and OUT_DIR/background@2x.png; the
// shell wrapper combines them into Resources/dmg-background.tiff.
import AppKit

let size = NSSize(width: 640, height: 400)
/// Icon centres in the window, top-left origin (as dmgbuild takes them).
let appCenter = NSPoint(x: 180, y: 210)
let applicationsCenter = NSPoint(x: 460, y: 210)

let paper = NSColor(srgbRed: 0xF4 / 255, green: 0xF2 / 255, blue: 0xEE / 255, alpha: 1)
let paperLow = NSColor(srgbRed: 0xEA / 255, green: 0xE7 / 255, blue: 0xE1 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x30 / 255, green: 0x33 / 255, blue: 0x36 / 255, alpha: 1)
let inkSoft = NSColor(srgbRed: 0x30 / 255, green: 0x33 / 255, blue: 0x36 / 255, alpha: 0.6)
let arrowGrey = NSColor(srgbRed: 0x9A / 255, green: 0x9B / 255, blue: 0x9C / 255, alpha: 1)

func render(scale: CGFloat) -> Data {
    let pixels = NSSize(width: size.width * scale, height: size.height * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Flip to the top-left origin Finder and dmgbuild use.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: size.height)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    NSGradient(starting: paper, ending: paperLow)!.draw(in: NSRect(origin: .zero, size: size), angle: 90)

    // Title, centred above the icons.
    let title = NSAttributedString(string: "Drag Insomnia to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: ink,
    ])
    drawCentered(title, x: size.width / 2, top: 58)

    // A soft arc from the app to Applications, ending in an open arrowhead
    // that follows the curve's last direction. One path, so nothing overlaps.
    let start = NSPoint(x: appCenter.x + 84, y: appCenter.y - 4)
    let end = NSPoint(x: applicationsCenter.x - 86, y: applicationsCenter.y - 4)
    let control2 = NSPoint(x: end.x - 40, y: end.y - 34)
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.curve(to: end, controlPoint1: NSPoint(x: start.x + 40, y: start.y - 34), controlPoint2: control2)
    let dx = end.x - control2.x, dy = end.y - control2.y
    let length = (dx * dx + dy * dy).squareRoot()
    let back = (x: -dx / length, y: -dy / length)
    for angle in [CGFloat.pi / 6, -CGFloat.pi / 6] {
        let arm = NSPoint(
            x: end.x + 15 * (back.x * cos(angle) - back.y * sin(angle)),
            y: end.y + 15 * (back.x * sin(angle) + back.y * cos(angle))
        )
        arrow.move(to: end)
        arrow.line(to: arm)
    }
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrowGrey.setStroke()
    arrow.stroke()

    let hint = NSAttributedString(string: "Then open it from Applications.", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: inkSoft,
    ])
    drawCentered(hint, x: size.width / 2, top: 340)

    return rep.representation(using: .png, properties: [:])!
}

/// Text in the flipped context: drawn upright, centred on `x`, with its top at `top`.
func drawCentered(_ text: NSAttributedString, x: CGFloat, top: CGFloat) {
    let bounds = text.size()
    NSGraphicsContext.saveGraphicsState()
    let upright = NSAffineTransform()
    upright.translateX(by: x - bounds.width / 2, yBy: top + bounds.height)
    upright.scaleX(by: 1, yBy: -1)
    upright.concat()
    text.draw(at: .zero)
    NSGraphicsContext.restoreGraphicsState()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
