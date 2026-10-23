import AppKit
import SwiftUI

/// Owns the NSStatusItem. The status bar button hosts a SwiftUI view (the
/// eye and the countdown); any click on it opens one native menu
/// (`SessionMenu` for starting, adding and ending, then `StatusMenu`'s status
/// lines, Settings and Quit). The item's length is written once per width
/// change (`StatusWidthWriter`).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// Builds the width writer over `apply` (which sets the item's length);
    /// tests inject one that records every write.
    typealias WidthWriterFactory = @MainActor (_ apply: @escaping (CGFloat) -> Void) -> StatusWidthWriter

    let manager: SessionManager
    let status: any StatusSource
    let model = MenuBarModel()
    let reminder = ReminderScheduler()
    /// Opens the settings window. Injected because the window is owned by the
    /// app delegate, which outlives any one status item.
    private let showSettings: () -> Void
    private let makeWidthWriter: WidthWriterFactory?
    /// Asks before a browser is quit for a relaunch; true means go ahead.
    /// Injected so tests never see the NSAlert.
    private let confirmRelaunch: @MainActor (String) -> Bool
    private let clock: @Sendable () -> Date

    private let statusItem: NSStatusItem
    private var hostingView: StatusHostingView?
    private var widthWriter: StatusWidthWriter?
    /// The custom field in the open menu, focused once the menu is up.
    private var openField: CustomTimeField?
    private var openMenu: NSMenu?
    /// The width the status item is heading for.
    private(set) var widthTarget: CGFloat = 0
    private var addHourObserver: NSObjectProtocol?

    /// Autosave name so macOS remembers where the user drags the item.
    static let autosaveName = "insomnia.status"

    init(
        manager: SessionManager,
        status: any StatusSource,
        showSettings: @escaping () -> Void,
        makeWidthWriter: WidthWriterFactory? = nil,
        confirmRelaunch: (@MainActor (String) -> Bool)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.manager = manager
        self.status = status
        self.showSettings = showSettings
        self.makeWidthWriter = makeWidthWriter
        self.confirmRelaunch = confirmRelaunch ?? Self.askBeforeRelaunch
        self.clock = clock
        Self.seedPreferredPositionIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = [.terminationOnRemoval]
        super.init()
        installHostingView()
        observeManager()
        managerChanged()
        addHourObserver = NotificationCenter.default.addObserver(
            forName: ForegroundNotifications.addHourPressed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.addTime(3600) }
        }
    }

    // MARK: Status item

    /// New status items are appended at the left of the existing group. On a
    /// crowded menu bar (notch Macs) that lands in the hidden overflow, so the
    /// item exists but is never seen. Seed a position near the right end the
    /// first time only; after that macOS keeps whatever the user drags to.
    static func seedPreferredPositionIfNeeded(defaults: UserDefaults = .standard) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(40, forKey: key)
    }

    private func installHostingView() {
        guard let button = statusItem.button else { return }
        let apply: (CGFloat) -> Void = { [statusItem] width in statusItem.length = width }
        widthWriter = makeWidthWriter?(apply) ?? StatusWidthWriter(apply: apply)
        let root = StatusRootView(
            model: model,
            manager: manager,
            onWidthChange: { [weak self] w in self?.retargetWidth(w) },
            onCountdownWidth: { [weak self] w in self?.countdownWidthChanged(w) }
        )
        let host = Self.makeHostingView(root)
        host.onClick = { [weak self] in self?.showMenu() }
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.height]
        host.frame = NSRect(x: 0, y: 0, width: 0, height: button.bounds.height)
        button.addSubview(host)
        button.title = ""
        button.image = nil
        (button.cell as? NSButtonCell)?.highlightsBy = []
        hostingView = host
        host.frame.size.width = max(widthTarget, host.fittingSize.width.rounded(.up), 24)
        retargetWidth(host.fittingSize.width)
    }

    /// Centralizes the AppKit/SwiftUI boundary so its sizing contract can be
    /// regression-tested without a live menu bar.
    static func makeHostingView(_ root: StatusRootView) -> StatusHostingView {
        let host = StatusHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }

    /// Set the item's length to `width`, once per change.
    private func retargetWidth(_ width: CGFloat) {
        let w = max(width.rounded(.up), 24)
        guard w != widthTarget else { return }
        widthTarget = w
        if let host = hostingView { host.frame.size.width = w }
        widthWriter?.write(w)
    }

    /// Keep the countdown's width from shrinking within a level; reset it
    /// when the level drops or the session ends.
    private func countdownWidthChanged(_ width: CGFloat) {
        let level = manager.session.map { s -> CountdownFormat.Level? in
            s.openEnded ? nil : CountdownFormat.level(remaining: s.remaining(at: clock()))
        } ?? nil
        if let reserved = Self.reservedCountdownWidth(current: model.countdownMinWidth, currentLevel: model.countdownLevel, measured: width, level: level) {
            model.countdownMinWidth = reserved.width
            model.countdownLevel = reserved.level
        }
    }

    /// The countdown's reserved width: grows with the text, never shrinks
    /// within a level, and starts over at a new (lower) level. nil when
    /// nothing changes. Pure.
    static func reservedCountdownWidth(
        current: CGFloat,
        currentLevel: CountdownFormat.Level?,
        measured: CGFloat,
        level: CountdownFormat.Level?
    ) -> (width: CGFloat, level: CountdownFormat.Level?)? {
        let w = measured.rounded(.up)
        if level != currentLevel { return (w, level) }
        return w > current ? (w, level) : nil
    }

    // MARK: Manager observation

    private func observeManager() {
        withObservationTracking {
            _ = manager.session
            _ = manager.lastError
            _ = manager.commandWarning
            _ = manager.foreignSleepWarning
            _ = manager.outputsWaitingForRestore
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.managerChanged()
                self.observeManager()
            }
        }
    }

    private func managerChanged() {
        let s = manager.session
        reminder.sync(endsAt: s?.openEnded == false ? s?.endsAt : nil)
        model.needsAttention = manager.commandWarning != nil
            || manager.foreignSleepWarning != nil
            || !manager.outputsWaitingForRestore.isEmpty
            || (manager.isActive && manager.lastError != nil)
        if manager.isActive {
            if model.phase != .running {
                model.phase = .running
                model.pendingCountdown = nil
                model.startFailure = nil
            }
        } else if model.phase == .running {
            model.phase = .idle
            model.countdownMinWidth = 0
            model.countdownLevel = nil
        }
    }

    // MARK: Menu

    /// What the session part of the menu shows right now.
    var menuState: SessionMenu.State {
        if model.phase == .starting { return .starting }
        if let s = manager.session { return s.openEnded ? .openEnded : .running(endsAt: s.endsAt) }
        if let failure = model.startFailure { return .failed(reason: failure) }
        return .idle
    }

    func showMenu() {
        guard let button = statusItem.button else { return }
        status.refreshInstant()
        status.refreshOnDemand()
        Task { await manager.recheckForeignSleep() }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        openField = nil
        for item in SessionMenu.items(state: menuState, templates: manager.config.templates, now: clock(), maxDuration: manager.config.maxDuration) {
            menu.addItem(menuItem(item))
        }
        menu.addItem(.separator())
        let tail = StatusMenu.menu(
            Self.menuItems(manager: manager, status: status),
            target: self,
            settings: #selector(menuOpenSettings),
            quit: #selector(menuQuit),
            relaunchBrowser: #selector(menuRelaunchBrowser(_:)),
            stopWaitingForOutput: #selector(menuStopWaitingForOutput(_:))
        )
        for item in tail.items {
            tail.removeItem(item)
            menu.addItem(item)
        }
        openMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func menuItem(_ item: SessionMenu.Item) -> NSMenuItem {
        switch item {
        case let .header(text):
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            entry.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0).bold, .foregroundColor: NSColor.labelColor])
            return entry
        case let .failure(text):
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            entry.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.systemOrange])
            return entry
        case let .label(text):
            return NSMenuItem.sectionHeader(title: text)
        case let .template(duration, title, mode):
            let entry = NSMenuItem(title: title, action: #selector(menuTemplate(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = TemplateChoice(duration: duration, mode: mode)
            entry.indentationLevel = 1
            return entry
        case .noTimeLimit:
            let entry = NSMenuItem(title: SessionMenu.noTimeLimitTitle, action: #selector(menuNoTimeLimit), keyEquivalent: "")
            entry.target = self
            entry.indentationLevel = 1
            return entry
        case let .customField(mode):
            let view = CustomTimeField(
                mode: mode,
                templates: { [manager] in manager.config.templates },
                onCommit: { [weak self] d in self?.customCommitted(d, mode: mode) },
                onSave: { [weak self] d in self?.saveTemplate(d) },
                onCancel: { [weak self] in self?.openMenu?.cancelTracking() }
            )
            openField = view
            let entry = NSMenuItem()
            entry.view = view
            return entry
        case .removeTimeLimit:
            let entry = NSMenuItem(title: SessionMenu.removeTimeLimitTitle, action: #selector(menuRemoveTimeLimit), keyEquivalent: "")
            entry.target = self
            return entry
        case .endSession:
            let entry = NSMenuItem(title: SessionMenu.endSessionTitle, action: #selector(menuEndSession), keyEquivalent: "")
            entry.target = self
            return entry
        case .separator:
            return .separator()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let field = openField else { return }
        // The menu's window exists only once it is on screen; focus on the
        // next turn of the tracking run loop.
        RunLoop.main.perform(inModes: [.eventTracking, .default]) {
            MainActor.assumeIsolated { field.focus() }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        openField = nil
        openMenu = nil
        // A start failure is shown until the menu has been seen once.
        if model.startFailure != nil, !manager.isActive, model.phase == .idle {
            model.startFailure = nil
        }
    }

    // MARK: Session actions

    private final class TemplateChoice: NSObject {
        let duration: TimeInterval
        let mode: SessionMenu.Mode
        init(duration: TimeInterval, mode: SessionMenu.Mode) {
            self.duration = duration
            self.mode = mode
        }
    }

    @objc private func menuTemplate(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TemplateChoice else { return }
        act(choice.duration, mode: choice.mode)
    }

    private func customCommitted(_ duration: TimeInterval, mode: SessionMenu.Mode) {
        openMenu?.cancelTracking()
        act(duration, mode: mode)
    }

    private func act(_ duration: TimeInterval, mode: SessionMenu.Mode) {
        switch mode {
        case .start: start(.timed(duration))
        case .add: addTime(duration)
        case .setLimit: Task { await manager.setTimeLimit(duration) }
        }
    }

    @objc private func menuNoTimeLimit() { start(.openEnded) }

    @objc private func menuRemoveTimeLimit() { Task { await manager.removeTimeLimit() } }

    @objc private func menuEndSession() {
        Task { await manager.end(reason: .user) }
    }

    enum StartChoice: Equatable {
        case timed(TimeInterval)
        case openEnded
    }

    func start(_ choice: StartChoice) {
        guard !manager.isActive, model.phase != .starting else { return }
        model.startFailure = nil
        model.phase = .starting
        switch choice {
        case let .timed(d):
            model.pendingCountdown = CountdownFormat.text(remaining: SessionMath.clamp(d, maxDuration: manager.config.maxDuration))
        case .openEnded:
            model.pendingCountdown = CountdownFormat.openEnded
        }
        Task { @MainActor in
            switch choice {
            case let .timed(d): await manager.start(duration: d)
            case .openEnded: await manager.startOpenEnded()
            }
            model.pendingCountdown = nil
            if manager.isActive {
                model.phase = .running
            } else {
                model.phase = .idle
                model.startFailure = manager.lastError ?? "the session could not be started"
            }
        }
    }

    /// Add 1 hour from the reminder, or a template while running.
    func addTime(_ duration: TimeInterval) {
        guard let s = manager.session, !s.openEnded else { return }
        Task { await manager.extend(by: duration) }
    }

    private func saveTemplate(_ duration: TimeInterval) {
        if case let .added(list) = TemplateList.adding(duration, to: manager.config.templates) {
            manager.updateConfig { $0.templates = list }
        }
    }

    // MARK: Status lines

    /// The menu's status lines from what the session and the status source
    /// report now. Static, so a test can check them without a status item.
    static func menuItems(manager: SessionManager, status: any StatusSource) -> [StatusMenu.Item] {
        StatusMenu.items(
            sessionActive: manager.isActive,
            sleepHeld: manager.state.sleepDisabledByUs,
            machine: StatusLines.machine(
                lidClosed: status.lidClosed,
                watts: status.instantWatts(),
                wifiSSID: WiFiStatusName.display(
                    ssid: status.wifiSSID,
                    locationAuthorized: (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
                ),
                batteryPercent: status.batteryPercent,
                isCharging: status.isCharging
            ),
            actions: StatusLines.actions(
                frozenCount: status.frozenCount,
                dockerPaused: status.dockerPaused,
                lastGap: status.lastGap
            ),
            throttledBrowsers: status.throttledBrowsers,
            relaunchProblems: status.relaunchProblems,
            // A report about an SSID edited away since is not shown.
            hotspotWarning: status.hotspotPasswordReport?.problem(for: manager.config.hotspotSSID)?.menuLine,
            // A refused start has its own line at the top of the menu.
            error: manager.isActive ? manager.lastError : nil,
            commandRunning: manager.commandWarning,
            foreignSleep: manager.foreignSleepWarning,
            outputsWaiting: manager.outputsWaitingForRestore,
            lidSimulationBuild: LidSimulationBuild.isCompiledIn
        )
    }

    @objc private func menuStopWaitingForOutput(_ sender: NSMenuItem) {
        guard let waiting = sender.representedObject as? SavedAudioOutput else { return }
        Task { await manager.stopWaitingForOutput(waiting) }
    }

    @objc private func menuRelaunchBrowser(_ sender: NSMenuItem) {
        guard let browser = sender.representedObject as? ThrottledBrowser else { return }
        relaunchBrowser(browser)
    }

    /// The relaunch item: ask first, since the browser is quit and its
    /// windows come back only through its own session restore.
    func relaunchBrowser(_ browser: ThrottledBrowser) {
        guard confirmRelaunch(browser.name) else { return }
        status.relaunchUnthrottled(browser)
    }

    private static func askBeforeRelaunch(_ name: String) -> Bool {
        let prompt = RelaunchPrompt(browser: name)
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: RelaunchPrompt.confirmTitle)
        alert.addButton(withTitle: RelaunchPrompt.cancelTitle)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func menuQuit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func menuOpenSettings() {
        showSettings()
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

/// The SwiftUI host covers the status bar button, so clicks are caught here:
/// left, right and ctrl-click all open the menu.
final class StatusHostingView: NSHostingView<StatusRootView> {
    var onClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
