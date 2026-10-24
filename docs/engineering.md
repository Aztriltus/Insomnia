# Engineering

How the current build does what [spec.md](spec.md) describes. When the two disagree, the spec wins and this file is out of date. Upstream's full design notes, which this fork inherited, are in [design-notes.md](design-notes.md) (formerly `docs/spec.md`); they go deeper but are partly stale (see "Doc drift" below). The redesign's build brief is [redesign-spec.md](redesign-spec.md) until it ships.

## Targets and identifiers

| What | Value |
| --- | --- |
| Toolchain | Swift tools 6.2, Swift 6 language mode, Swift Package (no Xcode project) |
| Platform | macOS 26+ (`LSMinimumSystemVersion` 26.0), arm64 release bundles |
| Bundle id | `com.zacheryng.insomnia` (`Resources/Info.plist`; renamed from upstream's `com.kgarg.insomnia` on 2026-10-24, and the scripts still quit an app with the old ID) |
| App type | `LSUIElement` true, `.accessory` activation policy; status item only |
| Signing | Ad-hoc (`codesign --force --sign -`) in `scripts/build-app.sh` |
| sudoers | `/etc/sudoers.d/insomnia`, 0440, four `pmset` commands, validated with `visudo -cf` |
| Recovery agent | `~/Library/LaunchAgents/com.insomnia.backstop.plist`, `RunAtLoad`, `StartInterval` 60; verifies the bundle's pinned code requirement, then runs the sealed `Contents/Resources/backstop.sh` |
| Hotspot password | Login Keychain generic password, service `insomnia-hotspot`, account = SSID (`insomnia-hotspot.replacing` during a replace) |

## Key files

**Core** (`Sources/Insomnia/Core/`)

- `SessionManager.swift`: session lifecycle, journal, restore, launch reconcile, most notifications.
- `AppServices.swift`: wires lid, power, network, browser and brightness sampler during a session.
- `LidActions.swift`: the close and open action list.
- `FloorRules.swift`: battery and heat decision table.
- `SleepGuard.swift`: `sudo -n pmset` wrapper with the 5 s read-back.
- `LaunchdBackstop.swift`: arms the agent and pins the code requirement.
- `RecoveryLock.swift`: flock shared with `backstop.sh`.
- `ResumeFrozenCommand.swift`: `--resume-frozen` mode used by `backstop.sh`.
- `SessionMath.swift`: duration clamping, extension, countdown format.

**Model and store**

- `Model/Config.swift`: settings and defaults; tolerant decoding.
- `Model/RuntimeState.swift`: the journal schema.
- `Store/`: paths and atomic owner-only IO.

**System**

- `Freezer.swift` and `ProcessControl.swift`: pause planning, SIGSTOP/SIGCONT, identity checks; `FreezePlanner.builtInProtected` holds the protected set.
- `NetworkFailover.swift`, `HotspotJoiner.swift`, `TmuxNudge.swift`, `LocationPermission.swift`: failover.
- `DisplayPower.swift` and `BrightnessSampler.swift`: private brightness calls, guarded to macOS 26 and 27.
- `AudioControl.swift`, `BrowserThrottle.swift`, `DockerRule.swift`, `PowerMonitor.swift`, `LidObserver.swift`.

**UI**

- `StatusItemController.swift`: status item, key handling, menu.
- `StatusRootView.swift`, `StatusMenu.swift`, `SettingsView.swift`, `ReminderScheduler.swift`, `ReleaseCheck.swift`, `LoginItem.swift`.

**Scripts:** `install.sh`, `uninstall.sh`, `backstop.sh`, `build-app.sh`, `simulate-lid.sh`.

## Session pipeline

1. **Start:**
   - Clamp the duration to 60 s through 30 days.
   - Write `session.json` and journal `sleepDisabledByUs`.
   - Arm the launchd agent.
   - Run `sudo -n pmset -a disablesleep 1`, then read it back after 5 s. A read-back of 0 fails the start.
   - Arm the deadline timer, apply App Nap (opt-in), and start `AppServices`.
   - A failure before `pmset` rolls back; a failed `pmset` ends the session as `startFailed`.
2. **Extend:** re-arm the agent, then rewrite `session.json`. The new end is capped at now + 30 days, and an expired session restarts from now.
3. **End:**
   - Delete `session.json`.
   - Undo, in this order: sleep, Low Power Mode (if Insomnia set it), lid actions, App Nap.
   - Each journal flag is cleared only after its undo succeeds. A busy lock or a dirty journal retries every 30 s.
4. **Recovery agent:**
   - Idle fast path: with no session and a clean journal, it exits before taking the lock.
   - Otherwise it takes the lock (10 s timeout). For an expired session, or with `--force`, it undoes sleep, Low Power Mode, paused processes and App Nap.
   - Audio and brightness are left to the app.

Timing: lock timeout 10 s, retry 30 s, `pmset` timeout 20 s, SIGTERM grace 3 s, lid debounce 2 s, brightness re-assert 2 s after wake.

## Data files

All files are 0600 in 0700 folders and written atomically.

- **`~/Library/Application Support/Insomnia/`:** `config.json`, `session.json`, `state.json`, `unfinished-command.json`, `.recovery.lock` (never unlinked), and `session.json.unreadable-<stamp>`.
- **`~/Library/Logs/Insomnia/`:** `insomnia.log` and `handoffs.log`, each rotated to `.1` past 1 MiB.
- **UserDefaults:** `NSStatusItem Preferred Position insomnia.status`.

## Constraints the redesign must respect

Measured upstream, before the fork. These are engineering facts, not owner decisions.

- **Status item width:** each `NSStatusItem.length` write makes Control Center re-lay out the menu bar and stalls the app 8–130 ms. Write it only on a layout change, never per frame.
- **Countdown digits:** animating them with `.contentTransition(.numericText())` cost about 46% of a core, against about 2% without. They change in one step (`StatusRootView.swift`).
- **Recovery agent idle exit:** this cut the per-minute cost from about 106 ms of CPU to about 2 ms. Don't add work before it.
- **Sleep read-back:** something else on the Mac (another keep-awake daemon) can revert `disablesleep`. Keep the read-back.

## Redesign implementation

Built on 2026-10-24 (branch `feat/redesign`). [redesign-spec.md](redesign-spec.md) §7 lists what went, what's new and what changed; its "Build notes" list where the build differs.

- **Pure types:** `CountdownFormat`, `DurationParser`, `DurationLabel`, `TemplateList`, `InstalledApps` (filtering), `HotspotMatcher`, and the v1 → v2 config migration. Each is unit tested and mutation-checked.
- **UI:**
  - `StatusMenu` is rebuilt around the idle, starting, failed and running menus.
  - `StatusItemController` loses its key monitors and the pill staging.
  - `SettingsView` becomes one `Form` with a collapsed `DisclosureGroup`.
  - New sheets: `AppPickerSheet` and `HotspotSetupSheet`.
- **No time limit:** a rolling deadline. The session's end time is kept 60 minutes ahead and renewed every 15 minutes through the normal extend path, with `openEnded: true` in `session.json`. The recovery agent and `backstop.sh` don't change: if the app dies, the deadline lapses and sleep comes back within an hour. `OpenEndedLease` holds the logic as a pure type. Details are in redesign-spec.md §1, "Sessions with no time limit".
- **Network:** `NetworkFailover` gains the internet-check trigger and an unfiltered scan; `HotspotJoiner` joins a given `CWNetwork`.
- **Removed:** `DurationInput`, `PillView`, `KeyCatcherPanel`, `HoldToEndButton` and `CountdownShape`.
- **Files:** `Core/DurationText.swift` (countdown, labels, parser), `Core/OpenEndedLease.swift`, `Model/TemplateList.swift`, `System/InstalledApps.swift`, `System/HotspotMatcher.swift` (matcher, security names, internet-check counter), `System/HotspotJoiner.swift` (join and `WiFiScanner`), `UI/SessionMenu.swift`, `UI/DurationGridView.swift` (the grid and the throttled icons), `UI/SettingsChips.swift` (chips, flow layout, app picker), `UI/HotspotSetupSheet.swift`.
- **Tests:** `RedesignLogicTests.swift` and `MenuBarFlowTests.swift`.

## Build, test and release

Debug build:

```bash
swift build
```

Release build, as CI runs it:

```bash
swift build -c release -Xswiftc -warnings-as-errors
```

Tests:

```bash
swift test
```

App bundle:

```bash
./scripts/build-app.sh --output build
```

Disk image to hand to other people (`dist/Insomnia-<version>.dmg` and its `.sha256`): the app, `install.sh`, `uninstall.sh`, "Install Insomnia.command", "Uninstall Insomnia.command" and a Read Me. With a Developer ID Application identity in the keychain it signs with the hardened runtime and notarizes and staples both the app and the DMG; without one it falls back to ad-hoc:

```bash
./scripts/build-dmg.sh
```

## Runbook: releasing an update

Installed copies check `https://github.com/Aztriltus/Insomnia/releases/latest/download/appcast.xml` once a day with Sparkle (`UI/AppUpdater.swift`, `SUFeedURL` and `SUPublicEDKey` in Info.plist), and Settings > Advanced > About > Check for updates checks now.

One-time setup on the release Mac:

1. A **Developer ID Application** certificate in the login keychain (developer.apple.com > Certificates; the account holder creates it).
2. Notary credentials stored as a keychain profile, with an app-specific password from appleid.apple.com:

   ```bash
   xcrun notarytool store-credentials insomnia-notary --apple-id <apple id> --team-id <team id>
   ```

3. The Sparkle EdDSA private key in the login keychain. It was made on 2026-10-24 with `.build/artifacts/sparkle/Sparkle/bin/generate_keys`; its public half is `SUPublicEDKey`. Losing the private key means installed copies can't verify updates any more: back it up with `generate_keys -x <file>`.

Each release, from a clean tree on the branch to ship:

```bash
./scripts/release.sh 0.2.0 "What changed, in a sentence or two."
```

It sets the version and build number in Info.plist and commits that, builds the notarized DMG, writes and signs `appcast.xml`, pushes the branch, and creates GitHub release `v0.2.0` with both files, marked Latest. It refuses to run without a Developer ID identity: Sparkle replaces the app in place, and the recovery agent keeps trusting it only when its pinned requirement names the team rather than an ad-hoc cdhash.

- The first Developer ID build has to be installed with its installer, once, so the agent pins the team requirement. Updates after that need no reinstall.
- `install.sh --app` installs a bundle signed by team `H37KGF95Y9` that Gatekeeper accepts as notarized without `--allow-unverified-origin` or its warning; anything else still needs the flag.
- First signed, notarized build: 0.1.0, installed from the DMG on 2026-10-24. Apple took about 30 minutes for the team’s first submission.
- First release: [v0.2.0](https://github.com/Aztriltus/Insomnia/releases/tag/v0.2.0), published with `release.sh` on 2026-10-24 (build 549).
- An update ends a running session, like any quit.
- Upstream's `release.yml` is manual-only in this fork, so a `v*` tag can't publish an unsigned zip over a release.

Testing:

- `InsomniaTests` has 22 test files, about 515 tests, and runs in under a minute. On 2026-10-24 it was cut from about 1,250 tests and 20 minutes down to the essentials: the session engine, recovery and reconcile, sleep guard, lid actions and freezing, floors, failover, config, the menu and the redesign's pure logic, plus 15 core recovery-script cases and the 2 recovery-agent signature checks. The removed tests are in git history before that date.
- To see the menu without a mouse, run a debug build with `INSOMNIA_DEBUG_MENU=open` (opens the menu 2 seconds after launch) or `=throttled` (also clicks the first throttled browser's icon), with `INSOMNIA_HOME` set to a scratch folder, and capture it with `screencapture`. Don't click grid cells in such a build: a session would load the real recovery agent's launchd label.
- The C target `InsomniaTestHome` points `INSOMNIA_HOME` at a temporary folder when the bundle loads, and aborts if it can't.
- Fakes live in `TestSupport.swift`: `FakeSleepGuard`, `FakeBackstop`, `FakeProcessControl`, `FakeAudioControl`, `FakeDisplayDimmer` and `FakeClock`.
- Keychain tests use a throwaway keychain file.

CI (`.github/workflows/`):

- **`ci.yml`:**
  - On macOS 26 and 27: a bash 3.2 syntax check, the merge-gate test, a release build with warnings as errors, the lid-simulation gate check, and `swift test` with a 50-minute watchdog.
  - On Ubuntu: ShellCheck, actionlint and zizmor.
- **`mac-mini.yml`:** a self-hosted macOS 27 VM; not required.
- **`merge-gate.yml`:** upstream's PR gate, with Greptile, the `accepted` label, real-Mac evidence, config review and Codex review. It is written for krishhgg/Insomnia; decide whether the fork keeps it.
- **`release.yml`:**
  - Stable: a `v*` tag matching `CFBundleShortVersionString`, marked Latest.
  - Nightly: daily at 07:17 UTC, tagged `nightly-<YYYYMMDD>-<sha12>`.
  - Each release is a zip with the app, `install.sh`, `uninstall.sh` and `SHA256SUMS`.
- **The update check and release URLs** point at `krishhgg/Insomnia` (`UI/ReleaseCheck.swift`).

## Code issues

All confirmed in code unless marked otherwise.

- `SessionManager.swift:1268` has a stale comment ("PR3: schedule '5 minutes left' notification"). The reminder is scheduled from `StatusItemController.swift`.
- `ReminderScheduler` has its own notification and authorization path, bypassing `Notifier`.
- The launchd agent runs `codesign --verify` every 60 s even when idle, before `backstop.sh` can take its idle exit (`install.sh`, `AGENT_PROGRAM`).
- `AppServices.syncState` counts paused processes, not apps, for the menu's "N apps frozen".
- `BrowserThrottle` only matches ids containing "chrome" or "chromium", plus Arc and Comet.
- Hypothesis: the agent's candidate plist is written with `Data.write`, which uses default permissions rather than 0600 (`LaunchdBackstop.swift:171-177`).

## Doc drift

Places where `design-notes.md` (upstream's spec) disagrees with the code:

- It describes a coffee-cup icon drawn with SF Symbols; the code draws a custom eye (`EyeMark*`).
- It says the countdown uses `.numericText()`; the code deliberately doesn't. Only the pills use it.
- It names the session field `extendedBy`; the code uses `extensions`.
- Its notification list leaves out eight that the code posts.
- Its event-source table leaves out the 30 s brightness sampler.
- Its repository layout misses about 20 source files and 36 test files.
- The README's "Some things need you" leaves out brightness, which the recovery agent can't restore either.
