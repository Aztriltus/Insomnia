import AppKit
import SwiftUI

/// The menu's grid of durations: three cells to a row, the highlighted one
/// being the running session's. A custom view inside one NSMenuItem.
@MainActor
final class DurationGridView: NSView {
    static let columns = 3
    static let cellSize = NSSize(width: 76, height: 28)
    static let gap: CGFloat = 6
    static let inset: CGFloat = 14
    /// The menu's width, set by the grid, which is its widest row.
    static var width: CGFloat {
        inset * 2 + CGFloat(columns) * cellSize.width + CGFloat(columns - 1) * gap
    }

    private let onTap: (SessionMenu.Cell) -> Void

    init(cells: [SessionMenu.Cell], selected: SessionMenu.Cell?, selectedTitle: String? = nil, enabled: Bool, onTap: @escaping (SessionMenu.Cell) -> Void) {
        self.onTap = onTap
        let rows = max(1, (cells.count + Self.columns - 1) / Self.columns)
        let height = 8 + CGFloat(rows) * Self.cellSize.height + CGFloat(rows - 1) * Self.gap + 8
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        for (i, cell) in cells.enumerated() {
            let row = i / Self.columns
            let column = i % Self.columns
            let running = cell == selected
            let title = running ? (selectedTitle ?? cell.title) : cell.title
            let button = GridCellButton(title: title, large: cell == .openEnded, running: running, enabled: enabled) { [weak self] in
                self?.onTap(cell)
            }
            button.frame = NSRect(
                x: Self.inset + CGFloat(column) * (Self.cellSize.width + Self.gap),
                y: height - 8 - CGFloat(row + 1) * Self.cellSize.height - CGFloat(row) * Self.gap,
                width: Self.cellSize.width,
                height: Self.cellSize.height
            )
            button.setAccessibilityLabel(running
                ? "\(cell.accessibilityTitle), running, \(title == CountdownFormat.openEnded ? "no time limit" : "\(title) left"). Click to end"
                : cell.accessibilityTitle)
            button.toolTip = cell.accessibilityTitle
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// One grid cell, drawn by hand like the Battery menu's Energy Mode
/// buttons: a quiet grey fill, or the accent colour with white text for the
/// running one. NSButton's own bezel colour turns grey in a menu, whose
/// window is never the active one. Brightens under the pointer. The menu
/// stays open when it's clicked.
@MainActor
final class GridCellButton: NSView {
    private let title: String
    private let large: Bool
    private let running: Bool
    private let enabled: Bool
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(title: String, large: Bool, running: Bool, enabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.large = large
        self.running = running
        self.enabled = enabled
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(enabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = enabled }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled, pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        action()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        let text: NSColor
        if running {
            fill = pressed ? NSColor.controlAccentColor.blended(withFraction: 0.2, of: .black) ?? .controlAccentColor : .controlAccentColor
            text = .white
        } else {
            let base = NSColor.labelColor.withAlphaComponent(hovering ? (pressed ? 0.24 : 0.17) : 0.1)
            fill = base
            text = enabled ? .labelColor : .tertiaryLabelColor
        }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()

        let font = large
            ? NSFont.systemFont(ofSize: 15, weight: .semibold)
            : NSFont.monospacedDigitSystemFont(ofSize: 12, weight: running ? .bold : .semibold)
        let string = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: text])
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// The throttled browsers, as a row of their icons with no labels. Clicking
/// one asks what to do with it (`onTap`).
@MainActor
final class ThrottledAppsView: NSView {
    static let iconSize: CGFloat = 22
    static let gap: CGFloat = 8
    static let inset: CGFloat = 14

    private let onTap: (ThrottledBrowser) -> Void
    private var buttons: [(NSButton, ThrottledBrowser)] = []

    init(browsers: [ThrottledBrowser], width: CGFloat, onTap: @escaping (ThrottledBrowser) -> Void) {
        self.onTap = onTap
        let perRow = max(1, Int((width - Self.inset * 2 + Self.gap) / (Self.iconSize + Self.gap)))
        let rows = max(1, (browsers.count + perRow - 1) / perRow)
        let height = 4 + CGFloat(rows) * Self.iconSize + CGFloat(rows - 1) * Self.gap + 6
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        for (i, browser) in browsers.enumerated() {
            let row = i / perRow
            let column = i % perRow
            let button = NSButton(image: Self.icon(for: browser), target: self, action: #selector(tapped(_:)))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.setAccessibilityLabel("\(browser.name) is throttled")
            button.toolTip = "\(browser.name) is throttled"
            button.frame = NSRect(
                x: Self.inset + CGFloat(column) * (Self.iconSize + Self.gap),
                y: height - 4 - CGFloat(row + 1) * Self.iconSize - CGFloat(row) * Self.gap,
                width: Self.iconSize,
                height: Self.iconSize
            )
            addSubview(button)
            buttons.append((button, browser))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func icon(for browser: ThrottledBrowser) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: browser.name) ?? NSImage()
    }

    @objc private func tapped(_ sender: NSButton) {
        guard let entry = buttons.first(where: { $0.0 === sender }) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onTap(entry.1)
    }
}

/// The menu's first row, laid out like the Battery menu's: the eye (open
/// while active, closed while not) and the state in bold on the left, a
/// grey value on the right ("until 6:40 PM"). The controller keeps one
/// across updates while the menu is open, so the eye blinks open or shut in
/// place when the state changes.
@MainActor
final class MenuHeaderView: NSView {
    static let inset: CGFloat = 14
    static let height: CGFloat = 24
    static let eyeSize: CGFloat = 16

    private let eye = HeaderEye()
    private let label = NSTextField(labelWithString: "")
    private let right = NSTextField(labelWithString: "")

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        autoresizingMask = [.width]
        let host = NSHostingView(rootView: HeaderEyeView(eye: eye))
        host.frame = NSRect(x: Self.inset, y: (Self.height - Self.eyeSize) / 2, width: Self.eyeSize, height: Self.eyeSize)
        host.setAccessibilityElement(false)
        addSubview(host)

        label.font = NSFont.menuFont(ofSize: 0).withBold
        label.textColor = .labelColor
        addSubview(label)
        right.font = NSFont.menuFont(ofSize: 0)
        right.textColor = .secondaryLabelColor
        right.alignment = .right
        right.autoresizingMask = [.minXMargin]
        addSubview(right)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Sets the row's content; the eye animates when `eyeOpen` changes.
    func update(title: String, value: String?, eyeOpen: Bool) {
        eye.open = eyeOpen
        label.stringValue = title
        label.sizeToFit()
        label.frame.origin = NSPoint(x: Self.inset + Self.eyeSize + 7, y: (Self.height - label.frame.height) / 2)
        right.stringValue = value ?? ""
        right.isHidden = value == nil
        right.sizeToFit()
        right.frame.origin = NSPoint(x: bounds.width - Self.inset - right.frame.width, y: (Self.height - right.frame.height) / 2)
        setAccessibilityLabel([title, value].compactMap { $0 }.joined(separator: ", "))
    }
}

@MainActor
@Observable
final class HeaderEye {
    var open = false
}

/// The menu bar's eye, with its blink, centred by its visible shape.
private struct HeaderEyeView: View {
    let eye: HeaderEye
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let closedOffset = StatusIcon.opticalOffset(open: false, canvas: MenuHeaderView.eyeSize)
    private static let openOffset = StatusIcon.opticalOffset(open: true, canvas: MenuHeaderView.eyeSize)

    var body: some View {
        EyeMarkView(isRunning: eye.open, reduceMotion: reduceMotion, size: MenuHeaderView.eyeSize)
            .frame(width: MenuHeaderView.eyeSize, height: MenuHeaderView.eyeSize)
            // Positive offsets move down; the shape sat that far above centre.
            .offset(y: eye.open ? Self.openOffset : Self.closedOffset)
            .animation(Motion.blink(opening: eye.open, reduceMotion: reduceMotion), value: eye.open)
            .foregroundStyle(Color(nsColor: .labelColor))
    }
}

extension NSFont {
    var withBold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
