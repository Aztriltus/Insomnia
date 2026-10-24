import AppKit
import SwiftUI

/// Owns the NSStatusItem: the eye as the button's image, in the standard
/// square slot, so macOS sizes and centres it like any other status icon. Any click on it opens
/// one native menu (`SessionMenu`'s first line and grid, then `StatusMenu`'s
/// lines, Settings and Quit). The menu stays open while a grid cell is used,
/// and its first line and highlight update in place.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let manager: SessionManager
    let status: any StatusSource
    let model = MenuBarModel()
    let reminder = ReminderScheduler()
    /// Opens the settings window. Injected because the window is owned by the
    /// app delegate, which outlives any one status item.
    private let showSettings: () -> Void
    /// Asks before a browser is quit for a relaunch; true means go ahead.
    /// Injected so tests never see the NSAlert.
    private let confirmRelaunch: @MainActor (String) -> Bool
    private let clock: @Sendable () -> Date

    private let statusItem: NSStatusItem
    /// The menu while it is open; rebuilt in place when the state changes.
    private var openMenu: NSMenu?
    /// The open menu's first row, kept across rebuilds so its eye animates.
    private var headerItem: NSMenuItem?
    /// A throttled browser's icon was clicked in the open menu; its own
    /// menu opens once that one has closed.
    private var pendingThrottled: ThrottledBrowser?
    private var addHourObserver: NSObjectProtocol?

    /// Autosave name so macOS remembers where the user drags the item.
    static let autosaveName = "insomnia.status"

    init(
        manager: SessionManager,
        status: any StatusSource,
        showSettings: @escaping () -> Void,
        confirmRelaunch: (@MainActor (String) -> Bool)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.manager = manager
        self.status = status
        self.showSettings = showSettings
        self.confirmRelaunch = confirmRelaunch ?? Self.askBeforeRelaunch
        self.clock = clock
        Self.seedPreferredPositionIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = [.terminationOnRemoval]
        super.init()
        installButton()
        observeManager()
        managerChanged()
        // The throttled-browser scan otherwise first runs when the menu
        // opens, too late for that opening to show its result.
        status.refreshOnDemand()
        #if DEBUG
        debugAtLaunch()
        #endif
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

    private func installButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(buttonPressed)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        updateIcon()
    }

    @objc private func buttonPressed() {
        showMenu()
    }

    /// The width macOS gives the item: the standard square slot, whatever
    /// the state.
    var statusItemLength: CGFloat { statusItem.length }

    /// Open while a session runs or starts, closed otherwise; with an orange
    /// dot when something in the menu needs attention.
    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let open = manager.isActive || model.phase == .starting
        let attention = model.needsAttention || model.startFailure
        button.image = StatusIcon.image(open: open, attention: attention)
        var label = "Insomnia"
        if model.phase == .starting {
            label += ", starting"
        } else if let s = manager.session {
            label += s.openEnded ? ", awake with no time limit" : ", \(CountdownFormat.spoken(remaining: s.remaining(at: clock()))) left"
        }
        if attention { label += ", needs attention" }
        button.setAccessibilityLabel(label)
    }

    // MARK: Manager observation

    private func observeManager() {
        withObservationTracking {
            _ = manager.session
            // The running cell counts down in the open menu.
            _ = manager.countdownText
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
                model.startFailure = false
            }
        } else if model.phase == .running {
            model.phase = .idle
        }
        updateIcon()
        refreshOpenMenu()
    }

    // MARK: Menu

    /// What the session part of the menu shows right now.
    var menuState: SessionMenu.State {
        #if DEBUG
        // `INSOMNIA_DEBUG_MENU=active`: draw the menu as if a session with no
        // time limit were running, without starting one.
        if ProcessInfo.processInfo.environment["INSOMNIA_DEBUG_MENU"] == "active" { return .openEnded }
        #endif
        if model.phase == .starting { return .starting }
        if let s = manager.session { return s.openEnded ? .openEnded : .running(endsAt: s.endsAt, choice: s.choice) }
        if model.startFailure { return .failed }
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
        headerItem = nil
        populate(menu)
        openMenu = menu
        present(menu, from: button)
        openMenu = nil
        headerItem = nil
        if let browser = pendingThrottled {
            pendingThrottled = nil
            showThrottledMenu(browser)
        }
    }

    /// Fills the menu in the Battery menu's order: the eye and the state,
    /// anything that needs attention under it, then a section for the grid,
    /// a section for throttled browsers, and Settings and Quit, with a
    /// separator between each.
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let session = SessionMenu.items(state: menuState, durations: manager.config.durations, now: clock())
        let lines = Self.menuItems(manager: manager, status: status)
        var throttled: [ThrottledBrowser] = []
        // The header block: the first row, a refused start, then warnings.
        for item in session.prefix(while: { if case .section = $0 { return false } else { return true } }) {
            menu.addItem(menuItem(item))
        }
        for line in lines {
            switch line.kind {
            case .info, .warning:
                let entry = NSMenuItem(title: line.title, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                entry.attributedTitle = NSAttributedString(string: line.title, attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: line.kind == .warning ? NSColor.systemOrange : NSColor.secondaryLabelColor,
                ])
                menu.addItem(entry)
            case let .stopWaitingForOutput(waiting):
                let entry = NSMenuItem(title: line.title, action: #selector(menuStopWaitingForOutput(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = waiting
                menu.addItem(entry)
            case let .throttled(browsers):
                throttled = browsers
            case .separator, .settings, .quit, .relaunchBrowser:
                break
            }
        }
        // The grid section.
        menu.addItem(.separator())
        for item in session.drop(while: { if case .section = $0 { return false } else { return true } }) {
            menu.addItem(menuItem(item))
        }
        // Throttled browsers.
        if !throttled.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: StatusMenu.throttledTitle))
            let row = NSMenuItem()
            row.view = ThrottledAppsView(browsers: throttled, width: DurationGridView.width) { [weak self] browser in
                // Shown once this menu has closed: one menu at a time.
                self?.pendingThrottled = browser
            }
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: StatusMenu.settingsTitle, action: #selector(menuOpenSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: StatusMenu.quitTitle, action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Rebuilds the open menu for the state now. It stays open.
    private func refreshOpenMenu() {
        guard let menu = openMenu else { return }
        populate(menu)
    }

    /// Opens `menu` where macOS puts a status item's menu, under the item
    /// and highlighting it. Returns once the menu has closed.
    private func present(_ menu: NSMenu, from button: NSStatusBarButton) {
        statusItem.menu = menu
        #if DEBUG
        debugWhileOpen(menu)
        #endif
        button.performClick(nil)
        statusItem.menu = nil
    }

    #if DEBUG
    /// Debug builds only: `INSOMNIA_DEBUG_MENU=open` opens the menu six
    /// seconds after launch, so its rendering can be captured without a
    /// mouse; `=throttled` also clicks the first throttled browser's icon.
    private func debugAtLaunch() {
        guard ProcessInfo.processInfo.environment["INSOMNIA_DEBUG_MENU"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.showMenu() }
    }

    private func debugWhileOpen(_ menu: NSMenu) {
        if ProcessInfo.processInfo.environment["INSOMNIA_DEBUG_MENU"] == "refresh" {
            // Walks the open menu through starting and a refused start, with
            // no session, to show it updates in place.
            let starting = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.phase = .starting
                    self?.refreshOpenMenu()
                }
            }
            let failed = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.phase = .idle
                    self?.model.startFailure = true
                    self?.refreshOpenMenu()
                }
            }
            RunLoop.main.add(starting, forMode: .eventTracking)
            RunLoop.main.add(failed, forMode: .eventTracking)
            return
        }
        guard ProcessInfo.processInfo.environment["INSOMNIA_DEBUG_MENU"] == "throttled",
              let row = menu.items.compactMap({ $0.view as? ThrottledAppsView }).first,
              let icon = row.subviews.compactMap({ $0 as? NSButton }).first
        else { return }
        let timer = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated { icon.performClick(nil) }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    #endif

    private func menuItem(_ item: SessionMenu.Item) -> NSMenuItem {
        switch item {
        case let .header(title, value, eyeOpen):
            // One header per open menu: refreshing updates it, so its eye
            // blinks in place instead of being replaced.
            let entry = headerItem ?? NSMenuItem()
            let view = (entry.view as? MenuHeaderView) ?? MenuHeaderView(width: DurationGridView.width)
            view.update(title: title, value: value, eyeOpen: eyeOpen)
            entry.view = view
            headerItem = entry
            return entry
        case let .section(title):
            return .sectionHeader(title: title)
        case let .failure(text):
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            entry.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.systemOrange])
            return entry
        case let .grid(cells, selected, selectedTitle, enabled):
            let entry = NSMenuItem()
            entry.view = DurationGridView(cells: cells, selected: selected, selectedTitle: selectedTitle, enabled: enabled) { [weak self] cell in
                self?.gridTapped(cell)
            }
            return entry
        case .endSession:
            let entry = NSMenuItem(title: SessionMenu.endSessionTitle, action: #selector(menuEndSession), keyEquivalent: "")
            entry.target = self
            return entry
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        // A start failure is shown until the menu has been seen once.
        if model.startFailure, !manager.isActive, model.phase == .idle {
            model.startFailure = false
            updateIcon()
        }
    }

    /// A browser's icon in the Throttled row: what to do about it.
    private func showThrottledMenu(_ browser: ThrottledBrowser) {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "\(browser.name) is throttled", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let relaunch = NSMenuItem(title: "Relaunch unthrottled", action: #selector(menuRelaunchBrowser(_:)), keyEquivalent: "")
        relaunch.target = self
        relaunch.representedObject = browser
        menu.addItem(relaunch)
        let advanced = NSMenuItem(title: "Advanced settings\u{2026}", action: #selector(menuOpenAdvanced), keyEquivalent: "")
        advanced.target = self
        menu.addItem(advanced)
        present(menu, from: button)
    }

    @objc private func menuOpenAdvanced() {
        manager.updateConfig { $0.advancedExpanded = true }
        showSettings()
    }

    // MARK: Session actions

    /// A grid cell was clicked (`SessionMenu.action`). The menu stays open.
    func gridTapped(_ cell: SessionMenu.Cell) {
        switch SessionMenu.action(for: cell, in: menuState) {
        case let .start(.duration(d)): start(.timed(d))
        case .start(.openEnded): start(.openEnded)
        case let .switchTo(.duration(d)): Task { await manager.setTimeLimit(d) }
        case .switchTo(.openEnded): Task { await manager.removeTimeLimit() }
        case .end: Task { await manager.end(reason: .user) }
        case .none: break
        }
    }

    @objc private func menuEndSession() {
        Task { await manager.end(reason: .user) }
    }

    enum StartChoice: Equatable {
        case timed(TimeInterval)
        case openEnded
    }

    func start(_ choice: StartChoice) {
        guard !manager.isActive, model.phase != .starting else { return }
        model.startFailure = false
        model.phase = .starting
        updateIcon()
        refreshOpenMenu()
        Task { @MainActor in
            switch choice {
            case let .timed(d): await manager.start(duration: d)
            case .openEnded: await manager.startOpenEnded()
            }
            if manager.isActive {
                model.phase = .running
            } else {
                model.phase = .idle
                model.startFailure = true
            }
            updateIcon()
            refreshOpenMenu()
        }
    }

    /// Add 1 hour from the reminder.
    func addTime(_ duration: TimeInterval) {
        guard let s = manager.session, !s.openEnded else { return }
        Task { await manager.extend(by: duration) }
    }

    // MARK: Status lines

    /// The menu's lines below the grid, in plain words. Only what needs
    /// attention is shown; detail is in the log. Static, so a test can check
    /// them without a status item.
    static func menuItems(manager: SessionManager, status: any StatusSource) -> [StatusMenu.Item] {
        StatusMenu.items(
            sessionActive: manager.isActive,
            sleepHeld: manager.state.sleepDisabledByUs,
            machine: nil,
            actions: nil,
            throttledBrowsers: status.throttledBrowsers,
            relaunchProblems: status.relaunchProblems.isEmpty ? [] : ["Couldn\u{2019}t relaunch the browser"],
            // A report about an SSID edited away since is not shown.
            hotspotWarning: status.hotspotPasswordReport?.problem(for: manager.config.hotspotSSID)?.menuLine,
            // A refused start has its own line at the top of the menu.
            error: manager.isActive && manager.lastError != nil ? "Something went wrong" : nil,
            commandRunning: manager.commandWarning == nil ? nil : "A power command is stuck",
            foreignSleep: manager.foreignSleepWarning == nil ? nil : "Another app has turned sleep off",
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
