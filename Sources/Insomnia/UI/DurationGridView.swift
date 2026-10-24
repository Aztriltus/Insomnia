import AppKit

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
    private var buttons: [(NSButton, SessionMenu.Cell)] = []

    init(cells: [SessionMenu.Cell], selected: SessionMenu.Cell?, selectedTitle: String? = nil, enabled: Bool, onTap: @escaping (SessionMenu.Cell) -> Void) {
        self.onTap = onTap
        let rows = max(1, (cells.count + Self.columns - 1) / Self.columns)
        let width = Self.inset * 2 + CGFloat(Self.columns) * Self.cellSize.width + CGFloat(Self.columns - 1) * Self.gap
        let height = 8 + CGFloat(rows) * Self.cellSize.height + CGFloat(rows - 1) * Self.gap + 8
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        for (i, cell) in cells.enumerated() {
            let row = i / Self.columns
            let column = i % Self.columns
            let button = NSButton(title: cell.title, target: self, action: #selector(tapped(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .flexiblePush
            button.font = .systemFont(ofSize: cell == .openEnded ? 15 : 12, weight: .medium)
            button.state = cell == selected ? .on : .off
            button.isEnabled = enabled
            button.tag = i
            button.setAccessibilityLabel(cell.accessibilityTitle)
            button.toolTip = cell.accessibilityTitle
            button.frame = NSRect(
                x: Self.inset + CGFloat(column) * (Self.cellSize.width + Self.gap),
                y: height - 8 - CGFloat(row + 1) * Self.cellSize.height - CGFloat(row) * Self.gap,
                width: Self.cellSize.width,
                height: Self.cellSize.height
            )
            if cell == selected {
                // The running session's cell: the accent colour, counting down.
                button.bezelColor = .controlAccentColor
                let centered = NSMutableParagraphStyle()
                centered.alignment = .center
                let title = selectedTitle ?? cell.title
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: cell == .openEnded ? 15 : 12, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: centered,
                ])
                button.setAccessibilityLabel("\(cell.accessibilityTitle), running, \(title == CountdownFormat.openEnded ? "no time limit" : "\(title) left"). Click to end")
            }
            addSubview(button)
            buttons.append((button, cell))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The menu stays open: the controller rebuilds the grid with the new
    /// highlight once the session has changed.
    @objc private func tapped(_ sender: NSButton) {
        guard let entry = buttons.first(where: { $0.0 === sender }) else { return }
        onTap(entry.1)
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
/// grey value on the right ("until 6:40 PM").
@MainActor
final class MenuHeaderView: NSView {
    static let inset: CGFloat = 14
    static let height: CGFloat = 24

    init(title: String, value: String?, eyeOpen: Bool, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        autoresizingMask = [.width]
        let eye = NSImageView(image: StatusIcon.image(open: eyeOpen, attention: false))
        eye.frame = NSRect(x: Self.inset, y: (Self.height - 16) / 2, width: 16, height: 16)
        eye.contentTintColor = .labelColor
        eye.setAccessibilityElement(false)
        addSubview(eye)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.menuFont(ofSize: 0).withBold
        label.textColor = .labelColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: Self.inset + 16 + 7, y: (Self.height - label.frame.height) / 2)
        addSubview(label)

        if let value {
            let right = NSTextField(labelWithString: value)
            right.font = NSFont.menuFont(ofSize: 0)
            right.textColor = .secondaryLabelColor
            right.alignment = .right
            right.sizeToFit()
            right.frame.origin = NSPoint(x: width - Self.inset - right.frame.width, y: (Self.height - right.frame.height) / 2)
            right.autoresizingMask = [.minXMargin]
            addSubview(right)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([title, value].compactMap { $0 }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

extension NSFont {
    var withBold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
