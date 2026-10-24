import AppKit
import SwiftUI

/// The status item's image: the eye, open or closed, drawn at the size of
/// macOS's own status icons and centred by the status bar button.
@MainActor
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)

    /// A template image (it follows the menu bar's light or dark look), or,
    /// with `attention`, one drawn in the menu bar's text colour with an
    /// orange dot at the top right.
    static func image(open: Bool, attention: Bool) -> NSImage {
        let eye = render(open: open)
        guard attention else {
            eye.isTemplate = true
            return eye
        }
        return NSImage(size: size, flipped: false) { rect in
            let tinted = NSImage(size: size, flipped: false) { r in
                eye.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
    }

    /// The eye drawn in its own canvas sits off centre: open, the lashes are
    /// on top; closed, they hang below. Render it large, find the box its
    /// pixels cover, and draw that box centred in `size`, so open and closed
    /// both sit on the menu bar's centre line like the system icons.
    private static func render(open: Bool) -> NSImage {
        let canvas: CGFloat = 18
        let renderer = ImageRenderer(content: EyeMarkView(progress: open ? 1 : 0, reduceMotion: true, size: canvas)
            .frame(width: canvas, height: canvas))
        renderer.scale = 4
        guard let cg = renderer.cgImage, let ink = inkBounds(cg) else { return NSImage(size: size) }
        let scale = renderer.scale
        // The shape in points, inside the 18 pt canvas.
        let shape = NSRect(x: ink.minX / scale, y: ink.minY / scale, width: ink.width / scale, height: ink.height / scale)
        let cropped = cg.cropping(to: ink) ?? cg
        return NSImage(size: size, flipped: false) { rect in
            let origin = NSPoint(x: (rect.width - shape.width) / 2, y: (rect.height - shape.height) / 2)
            NSGraphicsContext.current?.cgContext.draw(cropped, in: NSRect(origin: origin, size: shape.size))
            return true
        }
    }

    /// How far the drawn eye's centre sits above its canvas's centre, in
    /// points (positive is up), for a canvas of `canvas` points: what the
    /// menu's animated eye shifts by to sit centred.
    static func opticalOffset(open: Bool, canvas: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: EyeMarkView(progress: open ? 1 : 0, reduceMotion: true, size: canvas)
            .frame(width: canvas, height: canvas))
        renderer.scale = 4
        guard let cg = renderer.cgImage, let ink = inkBounds(cg) else { return 0 }
        let shapeCentreFromTop = (ink.midY) / renderer.scale
        return canvas / 2 - shapeCentreFromTop
    }

    /// The smallest box (in pixels, top-left origin) holding every pixel
    /// that isn't fully transparent. Pure over the bitmap.
    static func inkBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Row 0 of the bitmap's memory is the image's top row, as cropping
        // counts.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
