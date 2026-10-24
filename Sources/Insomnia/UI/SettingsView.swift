import AppKit
import SwiftUI

/// The settings window (redesign spec, section 2). The top level holds the
/// two app lists, the durations, the hotspot and Open at login; everything
/// else is under Advanced. Every change is written straight through
/// `manager.config` to config.json.
struct SettingsView: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    /// Launch at login as macOS reports it, not as config.json remembers it.
    let loginItem: LoginItem
    /// The "Check for updates" button's one request and its report.
    let releases: ReleaseChecker

    @State private var newTmuxTarget = ""
    /// The notice about the saved hotspot password (a keychain item this
    /// build can't read, for example).
    @State private var hotspot = HotspotPasswordField()
    /// A save or removal the keychain refused.
    @State private var saveNotice: String?
    /// Names of the apps "Pause every other app" would pause right now.
    @State private var wouldFreeze: [String] = []
    @State private var picker: Config.AppList?
    @State private var showingHotspotSheet = false
    @State private var showingAddDuration = false
    @State private var installed: [InstalledApp] = []
    /// macOS's "Ask to join hotspots", read on appear and whenever the app
    /// becomes active (the user may have just changed it).
    @State private var autoJoin = HotspotAutoJoin.read()

    var body: some View {
        Form {
            appsSection
            durationsSection
            hotspotSection
            loginSection
            Section {
                DisclosureGroup("Advanced", isExpanded: bind(\.advancedExpanded)) {
                    VStack(alignment: .leading, spacing: 18) {
                        lidSection
                        batterySection
                        agentSection
                        aboutSection
                    }
                    .padding(.top, 8)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 460, idealHeight: 640)
        .onAppear {
            installed = InstalledApps.scan()
            recheckPassword()
            refreshWouldFreeze()
            // The user may have approved or removed the item in System
            // Settings since the launch-time check.
            loginItem.refresh()
        }
        .onChange(of: manager.services?.status.hotspotPasswordReport) { recheckPassword() }
        .onChange(of: HotspotSSID.normalized(manager.config.hotspotSSID)) { recheckPassword() }
        .onChange(of: manager.config) { refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshWouldFreeze() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in autoJoin = HotspotAutoJoin.read() }
        .sheet(item: $picker) { list in
            AppPickerSheet(
                list: list,
                apps: installed,
                config: manager.config,
                toggle: { id in
                    update { c in c.contains(id, in: list) ? c.remove(id, from: list) : c.add(id, to: list) }
                }
            )
        }
        .sheet(isPresented: $showingHotspotSheet) {
            HotspotSetupSheet(
                locationPermission: locationPermission,
                onSave: saveHotspot
            )
        }
    }

    // MARK: Bindings

    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { manager.config[keyPath: keyPath] },
            set: { value in update { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ change: (inout Config) -> Void) {
        manager.updateConfig(change)
    }

    /// The floor steppers go through the Config setters, which move the
    /// other floor when the two would cross.
    private var lowPowerFloor: Binding<Int> {
        Binding(get: { manager.config.lowPowerFloor }, set: { v in update { $0.setLowPowerFloor(v) } })
    }

    private var endFloor: Binding<Int> {
        Binding(get: { manager.config.endFloor }, set: { v in update { $0.setEndFloor(v) } })
    }

    // MARK: Apps

    private var installedByID: [String: InstalledApp] {
        Dictionary(installed.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var appsSection: some View {
        Section {
            appList(.pause, title: "Pause when the lid closes", ids: manager.config.freezeList)
            appList(.fullSpeed, title: "Keep at full speed", ids: manager.config.agentList)
        } header: {
            Text("Apps")
        }
    }

    /// Only apps installed on this Mac are shown; a saved entry for one that
    /// isn't stays in config.json and comes back if the app does.
    private func appList(_ list: Config.AppList, title: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(ids.compactMap { installedByID[$0] }) { app in
                    AppChip(app: app) { update { $0.remove(app.bundleID, from: list) } }
                }
                AddChipButton(label: "Add an app to \(title)") { picker = list }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Durations

    private var durationsSection: some View {
        Section {
            FlowLayout(spacing: 6) {
                ForEach(manager.config.durations, id: \.self) { t in
                    TextChip(text: DurationLabel.short(t), removeLabel: "Remove \(DurationLabel.long(t))") {
                        update { $0.durations = TemplateList.removing(t, from: $0.durations) }
                    }
                }
                if manager.config.durations.count < TemplateList.capacity {
                    AddChipButton(label: "Add a duration") { showingAddDuration = true }
                        .popover(isPresented: $showingAddDuration, arrowEdge: .bottom) {
                            AddDurationPopover(templates: manager.config.durations) { d in
                                if case let .added(list) = TemplateList.adding(d, to: manager.config.durations) {
                                    update { $0.durations = list }
                                }
                                showingAddDuration = false
                            }
                        }
                }
            }
            Text("Up to 7, shown with \u{221E} in the menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Durations")
        }
    }

    // MARK: Hotspot

    private var hotspotSection: some View {
        Section {
            let ssid = HotspotSSID.normalized(manager.config.hotspotSSID)
            if ssid.isEmpty {
                HStack {
                    Text("Not set up").foregroundStyle(.secondary)
                    Spacer()
                    Button("Set up\u{2026}") { showingHotspotSheet = true }
                }
            } else {
                if manager.config.hotspotBSSIDs.isEmpty, manager.config.hotspotSecurity == nil {
                    Text("Choose it again to finish setup.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let notice = saveNotice ?? hotspot.notice {
                    Text(notice).font(.callout).foregroundStyle(.orange)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ssid)
                        Text(hotspotStatus).font(.caption).foregroundStyle(manager.config.hotspotLastJoin?.result == .rejected ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    Spacer()
                    Button("Change\u{2026}") { showingHotspotSheet = true }
                    Button("Remove", action: removeHotspot)
                }
            }
            if case let .off(mode) = autoJoin {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.autoJoinTip(mode))
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Wi-Fi Settings") { NSWorkspace.shared.open(HotspotAutoJoin.settingsURL) }
                }
            }
            if locationPermission.isDenied {
                HStack {
                    Text("Turn on Location Services to see Wi-Fi names.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Location Services") { locationPermission.openLocationServicesSettings() }
                }
            }
        } header: {
            Text("Hotspot backup")
        } footer: {
            Text("Joined when Wi-Fi drops during a session.")
        }
    }

    /// Why "Ask to join hotspots" should be Automatically, for the value it
    /// has now. Static so the copy can be tested.
    static func autoJoinTip(_ mode: String?) -> String {
        if mode == "Never" {
            return "Set Ask to join hotspots to Automatically. It\u{2019}s set to Never."
        }
        return "Set Ask to join hotspots to Automatically. Asking needs someone at the Mac."
    }

    private var hotspotStatus: String {
        guard let last = manager.config.hotspotLastJoin else { return "Not tried yet" }
        let day = last.at.formatted(.dateTime.month(.abbreviated).day())
        switch last.result {
        case .worked: return "Worked on \(day)"
        case .rejected: return "Password didn\u{2019}t work on \(day)"
        }
    }

    /// The sheet's choice: the network as scanned, and the password (empty
    /// for an open network). Config first, so the keychain item is saved
    /// under the new name; the failover forgets its last result.
    private func saveHotspot(_ row: HotspotMatcher.Row, password: String) {
        update { c in
            c.hotspotSSID = row.ssid
            c.hotspotBSSIDs = Array(row.bssids.prefix(HotspotMatcher.maxBSSIDs))
            c.hotspotSecurity = row.security
            c.hotspotLastJoin = nil
        }
        Task {
            let outcome = await Self.storePassword(password, in: secrets)
            Self.passwordStored(outcome, configuredSSID: manager.config.hotspotSSID, services: manager.services)
            if case let .failed(notice) = outcome { saveNotice = notice } else { saveNotice = nil }
            recheckPassword()
        }
    }

    private func removeHotspot() {
        Task {
            let outcome = await Self.storePassword("", in: secrets)
            Self.passwordStored(outcome, configuredSSID: manager.config.hotspotSSID, services: manager.services)
            update { c in
                c.hotspotSSID = ""
                c.hotspotBSSIDs = []
                c.hotspotSecurity = nil
                c.hotspotLastJoin = nil
            }
            saveNotice = nil
        }
    }

    /// Reads the notice again for the hotspot configured now, without a
    /// prompt.
    private func recheckPassword() {
        let request = hotspot.startRead(ssid: manager.config.hotspotSSID)
        Task {
            await Self.readForField(
                request,
                first: { await recheckedNotice() },
                again: { await recheckedNotice() },
                finish: { hotspot.finishRead($0, ssid: manager.config.hotspotSSID, password: $1.password, notice: $1.notice) }
            )
        }
    }

    private func recheckedNotice() async -> (password: String, notice: String?) {
        guard !HotspotSSID.normalized(manager.config.hotspotSSID).isEmpty else { return ("", nil) }
        let notice = await Self.hotspotNotice(
            reported: manager.services?.status.hotspotPasswordReport,
            ssid: manager.config.hotspotSSID,
            reread: secrets.peek
        )
        return ("", notice)
    }

    // MARK: Open at login

    private var loginSection: some View {
        Section {
            Toggle("Open at login", isOn: launchAtLogin)
            loginItemNote
        }
    }

    // MARK: Advanced

    /// Under the mute toggle and in the README. Apple Platform Security,
    /// "Hardware microphone disconnect".
    static let microphoneNote = "The built-in mic is off while the lid is closed."

    private var lidSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When the lid closes").font(.headline)
            // The one-time lid-close update, for a user who has
            // notifications turned off. Stays until dismissed.
            if let notice = manager.config.lidCloseDefaultsNotice {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.settingsLine)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { manager.dismissLidCloseNotice() }
                }
            }
            Toggle("Turn off display and keyboard light", isOn: bind(\.darkenDisplayOnLidClose))
            if !manager.darkenRefusals.isEmpty {
                Text("This Mac doesn\u{2019}t allow it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Mute sound", isOn: bind(\.muteOnLidClose))
            Text(Self.microphoneNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Low Power Mode", isOn: bind(\.lowPowerOnLidClose))
                // A floor input: apply it now if the lid is already closed.
                .onChange(of: manager.config.lowPowerOnLidClose) { manager.services?.reevaluateFloors() }
            Toggle("Pause Docker when idle", isOn: bind(\.dockerRule))
            Toggle("Pause every other app", isOn: bind(\.freezeAllApps))
            if manager.config.freezeAllApps {
                Text(wouldFreeze.isEmpty ? "Nothing else to pause now" : "Would pause \(wouldFreeze.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Same planner as the lid-close action, over the apps running now.
    private func refreshWouldFreeze() {
        let selfId = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
        wouldFreeze = FreezePlanner.automaticCandidates(config: manager.config, apps: Freezer.runningApps(), selfBundleId: selfId).map(\.name)
    }

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Battery and heat").font(.headline)
            Stepper(value: lowPowerFloor, in: 0...100, step: Config.floorStep) {
                LabeledContent("Low Power Mode below", value: "\(manager.config.lowPowerFloor)%")
            }
            Stepper(value: endFloor, in: 0...Config.maxEndFloor, step: Config.floorStep) {
                LabeledContent("End below", value: manager.config.endFloor == 0 ? "Off" : "\(manager.config.endFloor)%")
            }
            Toggle("Slow down or end when too hot", isOn: bind(\.thermalRules))
                .onChange(of: manager.config.thermalRules) { manager.services?.reevaluateFloors() }
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full-speed apps").font(.headline)
            Toggle("Turn off App Nap for these apps", isOn: bind(\.disableAppNapForAgents))
            Text("Coding agents").font(.headline).padding(.top, 6)
            Stepper(value: nudgeSeconds, in: 10...900, step: 10) {
                LabeledContent("Nudge tmux after", value: "\(Int(manager.config.nudgeThreshold)) s offline")
            }
            Toggle("Press Return after typing", isOn: bind(\.tmuxNudgePressesEnter))
            Text("Mark each pane with:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(TmuxNudge.markCommand())
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            ForEach(manager.config.tmuxTargets, id: \.self) { t in
                HStack {
                    Text(t).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        update { $0.tmuxTargets.removeAll { $0 == t } }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(t)")
                }
            }
            HStack {
                TextField("work:1.0", text: $newTmuxTarget)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTmuxTarget)
                Button("Add pane", action: addTmuxTarget)
            }
        }
    }

    private var nudgeSeconds: Binding<Int> {
        Binding(
            get: { Int(manager.config.nudgeThreshold) },
            set: { seconds in update { $0.nudgeThreshold = TimeInterval(seconds) } }
        )
    }

    private func addTmuxTarget() {
        let t = newTmuxTarget.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        update { if !$0.tmuxTargets.contains(t) { $0.tmuxTargets.append(t) } }
        newTmuxTarget = ""
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About").font(.headline)
            LabeledContent("Version") {
                Text(AppBuild.current.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            releaseCheck
            Button("Show settings file in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([manager.paths.configFile])
            }
            if LidSimulationBuild.isCompiledIn {
                Text(LidSimulationBuild.marker)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Password helpers

    /// Loads the saved password into the field, without a keychain prompt.
    /// An item this build may not read leaves the field empty and says
    /// why, so the user re-enters it; saving then replaces the item (see
    /// `KeychainStore`). The read can wait behind a save, so a field
    /// edited meanwhile is kept, even one typed in and emptied again, and
    /// a password read for an SSID edited away meanwhile is not shown: the
    /// SSID configured now is read instead. That read is a peek: the
    /// account a later save moves the password from stays the one the
    /// window loaded, as it does for any SSID edit, so the old SSID's item
    /// is still removed.
    static func loadForField(
        _ request: HotspotPasswordField.Read,
        secrets: any HotspotSecretStore,
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?)) -> HotspotPasswordField.ReadAnswer
    ) async {
        await readForField(
            request,
            first: { await loadedPassword(secrets.load) },
            again: { await loadedPassword(secrets.peek) },
            finish: finish
        )
    }

    /// Runs a load or recheck for the field: `first` reads, and `finish`
    /// takes the answer. While the SSID was edited during the read,
    /// `finish` drops the answer, and `again` reads the SSID configured
    /// now, until an answer is used or dropped.
    static func readForField(
        _ request: HotspotPasswordField.Read,
        first: @MainActor () async -> (password: String, notice: String?),
        again: @MainActor () async -> (password: String, notice: String?),
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?)) -> HotspotPasswordField.ReadAnswer
    ) async {
        var answer = await first()
        var request = request
        while case let .readAgain(next) = finish(request, answer) {
            request = next
            answer = await again()
        }
    }

    /// A prompt-free load: the password for the field, or an empty field
    /// and a notice saying why it cannot be shown.
    static func loadedPassword(_ load: () async throws -> String?) async -> (password: String, notice: String?) {
        do {
            return (try await load() ?? "", nil)
        } catch let error as KeychainError {
            return ("", error.problem.settingsNotice)
        } catch {
            return ("", HotspotPasswordProblem.error(error.localizedDescription).settingsNotice)
        }
    }

    /// The notice under the password field for the hotspot `ssid`
    /// configured now. A problem the failover reports about that hotspot
    /// shows as it is. A report about another SSID, one edited away since,
    /// does not apply, and a cleared report is not taken as "readable": it
    /// also clears when the session ends. Then the keychain is read again,
    /// without a prompt, and the notice says what that read finds. The
    /// field is left as the user has it, and the reread is a peek: a load
    /// would make an SSID typed since then the account a save moves the
    /// password from, and the old SSID's item would stay behind.
    static func hotspotNotice(reported: HotspotPasswordReport?, ssid: String, reread: () async throws -> String?) async -> String? {
        if let problem = reported?.problem(for: ssid) { return problem.settingsNotice }
        return await loadedPassword(reread).notice
    }

    /// A save or clear answered. The failover's report goes, and the next
    /// outage notifies afresh, unless the report is about the hotspot
    /// configured now and the save neither stored for it nor removed its
    /// item (`HotspotPasswordReport.stands`).
    static func passwordStored(_ outcome: HotspotStoreOutcome, configuredSSID: String, services: AppServices?) {
        guard case let .stored(stored) = outcome else { return }
        services?.hotspotPasswordChanged(stored.change, configuredSSID: configuredSSID)
    }

    /// Saves `password`, or clears the saved one when it is empty, and
    /// returns what was stored under which SSID and which loaded account
    /// it removed, or the notice for a failure. The store does the keychain work on `KeychainQueue`, so a
    /// save waiting on a keychain dialog waits there while the main actor
    /// (the battery floor, the deadline timer, End) carries on.
    static func storePassword(_ password: String, in secrets: any HotspotSecretStore) async -> HotspotStoreOutcome {
        do {
            let change = if password.isEmpty {
                try await secrets.delete()
            } else {
                try await secrets.save(password)
            }
            return .stored(.init(ssid: change.ssid, password: password, removed: change.removed))
        } catch {
            Log.error("could not save hotspot password: \(error.localizedDescription)")
            return .failed(notice: "Could not save the hotspot password: \(error.localizedDescription)")
        }
    }

    // MARK: Login item and updates

    /// The update check: one request to GitHub's releases list per click,
    /// and the report under the buttons. It opens the releases page and
    /// installs nothing; the installer run again is the upgrade.
    @ViewBuilder
    private var releaseCheck: some View {
        HStack {
            Button(releases.state == .checking ? "Checking" : "Check for updates") { releases.check() }
                .disabled(releases.state == .checking)
            Button("Open releases page") { NSWorkspace.shared.open(GitHubReleaseFetcher.releasesPage) }
        }
        switch releases.state {
        case .idle:
            EmptyView()
        case .checking:
            EmptyView()
        case let .checked(report):
            Text(report.summary)
                .font(.caption)
                .foregroundStyle(report.standing == .newerStableAvailable ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
        case .failed:
            Text("Couldn\u{2019}t check for updates")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// The switch shows what macOS has on file (`LoginItem.isRegistered`:
    /// enabled or waiting for approval), so a registration that an upgrade
    /// dropped reads as off even while config.json still says on, and a
    /// pending one can be withdrawn by turning the switch off; the note
    /// below explains the state.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem.isRegistered },
            set: { on in
                // Persist only what macOS accepted; a refused change leaves
                // the flag as it was and its error on screen.
                update { config in _ = loginItem.set(on, config: &config) }
            }
        )
    }

    /// One line under the switch: the last error, a pending approval with
    /// the button that opens Login Items, or a flag macOS no longer honours.
    @ViewBuilder
    private var loginItemNote: some View {
        if loginItem.error != nil {
            Text("Couldn\u{2019}t change Open at login").font(.caption).foregroundStyle(.red)
        } else if loginItem.needsApproval {
            HStack {
                Text("Waiting for approval in System Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { loginItem.openLoginItems() }
            }
        } else if manager.config.launchAtLogin, !loginItem.isRegistered {
            Text("Turned off in System Settings")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

/// Running apps offered by "Add running app…": everything with a bundle id
/// that is not Apple's own.
@MainActor
enum RunningApps {
    struct Entry: Hashable {
        let bundleID: String
        let name: String
    }

    static func candidates(excluding: [String]) -> [Entry] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple."), id != me,
                  app.activationPolicy != .prohibited,
                  !excluding.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(Entry(bundleID: id, name: app.localizedName ?? id))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Name of a running app for a bundle id, or the last path component.
    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
