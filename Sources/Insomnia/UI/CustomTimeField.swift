import AppKit

/// The custom-time row inside the status item's menu: a text field, and
/// under it either the action Return takes ("Start for 45 minutes ↵") with
/// a Save button, or the hint for text that can't be read. A fixed height,
/// so the open menu never has to lay out again while typing.
@MainActor
final class CustomTimeField: NSView, NSTextFieldDelegate {
    let mode: SessionMenu.Mode
    private let templates: () -> [TimeInterval]
    private let onCommit: (TimeInterval) -> Void
    private let onSave: (TimeInterval) -> Void
    private let onCancel: () -> Void

    let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let save = NSButton(title: "", target: nil, action: nil)
    private var current: TimeInterval?

    static let width: CGFloat = 260
    static let height: CGFloat = 58

    init(
        mode: SessionMenu.Mode,
        templates: @escaping () -> [TimeInterval],
        onCommit: @escaping (TimeInterval) -> Void,
        onSave: @escaping (TimeInterval) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.templates = templates
        self.onCommit = onCommit
        self.onSave = onSave
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))

        field.placeholderString = SessionMenu.customPlaceholder
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.font = .menuFont(ofSize: 0)
        field.setAccessibilityLabel("Custom time")
        field.frame = NSRect(x: 14, y: Self.height - 28, width: Self.width - 28, height: 22)
        addSubview(field)

        status.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 16, y: 8, width: Self.width - 32, height: 16)
        addSubview(status)

        save.bezelStyle = .inline
        save.controlSize = .small
        save.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        save.target = self
        save.action = #selector(saveTapped)
        save.isHidden = true
        addSubview(save)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let current { onCommit(current) } else { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty {
                onCancel()
            } else {
                field.stringValue = ""
                refresh()
            }
            return true
        default:
            return false
        }
    }

    @objc private func saveTapped() {
        guard let current else { return }
        onSave(current)
        refresh()
    }

    private func refresh() {
        switch SessionMenu.fieldStatus(field.stringValue, mode: mode) {
        case .empty:
            current = nil
            status.stringValue = ""
            save.isHidden = true
        case .invalid:
            current = nil
            status.stringValue = SessionMenu.customHint
            status.textColor = .secondaryLabelColor
            save.isHidden = true
        case let .valid(duration, action):
            current = duration
            status.stringValue = "\(action) \u{21A9}\u{FE0E}"
            status.textColor = .labelColor
            if mode == .start, let title = SessionMenu.saveTitle(duration, templates: templates()) {
                save.title = title.hasPrefix("Templates full") ? title : "Save as template"
                save.isEnabled = !title.hasPrefix("Templates full")
                save.sizeToFit()
                save.isHidden = false
                save.frame.origin = NSPoint(x: Self.width - 16 - save.frame.width, y: 6)
                status.frame.size.width = Self.width - 40 - save.frame.width
            } else {
                save.isHidden = true
                status.frame.size.width = Self.width - 32
            }
        }
    }

    /// Puts the cursor in the field as the menu opens, so typing goes
    /// straight in.
    func focus() {
        window?.makeFirstResponder(field)
    }
}
