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

    private static func render(open: Bool) -> NSImage {
        let renderer = ImageRenderer(content: EyeMarkView(progress: open ? 1 : 0, reduceMotion: true, size: size.width)
            .frame(width: size.width, height: size.height))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: size)
        image.size = size
        return image
    }
}
