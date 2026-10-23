# Insomnia redesign: a simpler menu bar app

Status: draft, 2026-10-23. This spec covers what changes. Everything it
doesn't mention keeps working as [spec.md](spec.md) describes: the sleep
guard, lid-close actions, battery and heat rules, the recovery journal, the
launchd backstop, install and uninstall.

## Goal

Make Insomnia something you can use without reading the README. Five things
change:

1. **Starting a session** moves from three typed fields in the menu bar to a
   menu of saved durations, with a field for a custom time.
2. **The countdown** in the menu bar shows two units and no seconds.
3. **Settings** shrink to the few things most people change: which apps are
   paused, which are kept at full speed, the durations, and the hotspot.
   Everything else is folded under Advanced.
4. **Hotspot backup** is set up by picking a network from a list, not by
   typing its name. Insomnia saves the network's name, its hardware address
   (BSSID) and its password.
5. **Sessions can have no time limit.** Today every session is timed, up to
   30 days.

## Decisions

| Topic | Chosen | Turned down, and why |
| --- | --- | --- |
| Scope | Keep the engine, rebuild the UI, settings, hotspot setup and saved settings | Full rewrite: the recovery and lid-close engine is the hard, well-tested part (about 30k lines of tests) and none of the requests need it changed |
| Click target | One native menu (`NSMenu`) for both left and right click | The "dropdown" is a **Menu**: each item does something (start, add time, end). It's not a Select, because nothing is stored as a form value. Inline pills: hard to discover, need a custom key panel, and slow to animate. Two menus for left and right click: users can't find the second one |
| Countdown | Unit suffixes, two units at most: `2d 5h`, `5h 12m`, `42m` | Colons (`02:05`): unclear whether that's days and hours or hours and minutes |
| Countdown seconds | None. Redraw once a minute | 1 Hz redraws cost battery and make the bar flicker for no gain |
| App lists | Two equal lists at the top: "Pause when the lid closes" and "Keep at full speed" | One list with the other under Advanced: hides a choice that matters for agent users. A three-state grid: every app gets a control and the screen gets busy |
| Apps shown | Only apps the user installed, as a small icon and name | Typed bundle IDs: nobody knows them. Showing default entries for apps that aren't installed: noise |
| Session length | Timed (up to 30 days), or no time limit | Timed only: the owner wants an open-ended option. A literal "never ends" session: if the app crashed, nothing would ever put sleep back |
| Hotspot identity | SSID, BSSID and security from a scan; password reused from macOS when it knows the network, otherwise typed; setup never joins | Typed SSID: typos, and two networks can share a name. A test join during setup: it drops Wi-Fi and cuts off running agents |

## 1. Menu bar

### Icon and countdown

- **Idle:** the closed-eye icon on its own.
- **Starting:** the eye opens at once, and the countdown shows the time the
  session will have, in the same format as below. Starting takes a few
  seconds, because Insomnia sets up its crash-recovery job and turns off
  sleep with an admin command. Choosing items from the menu does nothing
  until the start finishes or fails. The menu still opens, with "Starting…"
  at the top in place of the header.
- **Session running:** the open-eye icon, then the remaining time.
- **Session with no time limit:** the open-eye icon followed by `∞`.
- **Start failed:** the eye closes again and gets the warning badge. The
  menu opens with "Couldn't start: the recovery agent couldn't be set up" (the reason varies) as its first line, in the same
  words as today's right-click error line, above the usual idle items. The
  line and the badge stay until the next start succeeds, or until the user
  opens the menu and closes it again. No notification is sent, because the
  user is looking at the menu bar when it happens.
- When the lid-close actions or a recovery problem need attention, the eye
  gets the existing warning badge. The countdown stays.
- **Motion:** the eye keeps its blink when opening and closing, and its
  pupil shrinks away as the lid drops, both as today. With Reduce Motion on,
  both become short crossfades. The countdown digits change in one step,
  with no content transition: animating them measured at about 46% of a
  core against about 2% without (upstream PR #111, 2026-10-17). Nothing
  else in the bar animates.
- **VoiceOver:** the status item reads "Insomnia" when idle, "Insomnia,
  starting" while starting, "Insomnia, 5 hours 12 minutes left" while
  running, and "Insomnia, awake with no time limit" for a session with no
  time limit. It never uses the abbreviated `5h 12m`. A warning adds ", needs
  attention".

### Countdown format

The menu bar shows the time left as one or two units:

| Time left | Shows |
| --- | --- |
| 3 days 4 hours 20 minutes | `3d 4h` |
| 3 days 0 hours 20 minutes | `3d` |
| 5 hours 12 minutes | `5h 12m` |
| 5 hours 0 minutes | `5h` |
| 42 minutes 10 seconds | `43m` |
| 20 seconds | `1m` |

Rules (all in one pure function, `CountdownFormat.text(remaining:)`):

1. Round the remaining time **up** to a whole minute, so the bar never reads
   `0m` while a session is still running. It reads `1m` until the session
   ends.
2. Split that into days, hours and minutes.
3. Show the largest non-zero unit and the next unit down. A zero second
   unit is left out (`5h`, not `5h 0m`).
4. Days show days and hours, never minutes.

Redraw at each wall-clock minute boundary, and when the session is extended,
ended, or the Mac wakes. `StatusWidthWriter` is still the only thing that sets
the item's width, and only when the text width changes.

**Keeping the width steady.** Every width change makes the menu bar re-lay
out, which stalls the app for 8 to 130 ms (see the 2026-09-17 smoothness
design in `docs/superpowers/specs/`). To keep changes rare:

- Digits use monospaced figures (`.monospacedDigit()`).
- The item's width only grows during a session, never shrinks. It is reset
  when the session ends, and when the text pattern drops a level (from days
  to hours, or from hours to minutes).
- With this, the width changes at most a handful of times per session. The
  trade-off is some empty space after `5h`, which is accepted.

Remove `CountdownShape`, the 1 Hz timer and `formatCountdown`.

### The menu

Clicking the eye or the countdown, with either button, opens one menu. Its
contents depend on whether a session is running.

**No session running**

```
Keep awake for
   30 minutes
   1 hour
   2 hours
   4 hours
   8 hours
   1 day
   No time limit
┌──────────────────────────────┐
│ Custom: 45m, 2h, 1d          │      ← text field
└──────────────────────────────┘
   Start for 45 minutes   ↵           ← appears when the field holds a valid time
   Save "45 minutes" as a template
───────────────
<status and warning lines, if any>
───────────────
Settings…                         ⌘,
Quit Insomnia                     ⌘Q
```

**Session running**

```
Awake until 6:40 PM
───────────────
Add time
   30 minutes
   1 hour
   …
┌──────────────────────────────┐
│ Custom: 45m, 2h, 1d          │
└──────────────────────────────┘
   Add 45 minutes   ↵
Remove time limit
End session
───────────────
<status and warning lines>
───────────────
Settings…                         ⌘,
Quit Insomnia                     ⌘Q
```

**Session with no time limit**

```
Awake with no time limit
───────────────
Set a time limit
   30 minutes
   1 hour
   …
┌──────────────────────────────┐
│ Custom: 45m, 2h, 1d          │
└──────────────────────────────┘
   End in 45 minutes   ↵
End session
───────────────
<status and warning lines>
───────────────
Settings…                         ⌘,
Quit Insomnia                     ⌘Q
```

- Template items start a session (or add the time) and close the menu.
- **No time limit** sits after the templates, always. It isn't a template,
  so it can't be removed and doesn't count toward the 8.
- **Remove time limit** turns a running timed session into one with no
  time limit. **Set a time limit** does the reverse: the session ends that
  long from now (not from when it started).
- The header reads "Awake until 6:40 PM" when the session ends today,
  "Awake until Sat 6:40 PM" when it ends this week, and "Awake until Oct 30,
  6:40 PM" after that. It doesn't repeat the time left, because the menu bar
  already shows it.
- **End session** ends at once, with no hold or confirmation. Starting again
  is two clicks. The hold-to-end control goes away.
- Extending past the 30-day ceiling caps at 30 days. The item reads
  "Add 1 day (capped at 30 days)" when that applies.
- Status and warning lines are today's right-click items, unchanged:
  sleep-held, lid state, frozen apps, browser relaunch, hotspot warnings,
  recovery problems, "Stop waiting for …" for audio.
- Quit keeps today's rule: it undoes the session first and refuses while a
  change is still waiting to be undone.

### Custom time field

- A text field inside the menu (`NSMenuItem.view` holding an
  `NSTextField`). It takes focus when the user types, so they can open the
  menu and start typing at once.
- The two action rows under it appear only while the field holds a valid
  time. Enter does the first one (Start, or Add).
- If the text can't be read, a muted row under the field says "Try 45m, 2h
  or 1d".
- Esc clears the field. A second Esc closes the menu.
- **Fallback:** if keyboard focus in the menu's text field turns out to be
  unreliable on macOS 26, use a "Custom…" item that opens a small popover
  anchored to the status item, holding the same field and buttons. Decide
  this in the first prototype, and record the result here.

### Duration parser

`DurationParser.parse(_:) -> TimeInterval?` is pure and accepts:

| Input | Means |
| --- | --- |
| `45` | 45 minutes (a bare number is minutes) |
| `45m`, `45 min`, `45 minutes` | 45 minutes |
| `2h`, `2 hr`, `2 hours`, `1.5h` | hours |
| `1h30m`, `1h 30m`, `1:30` | 1 hour 30 minutes |
| `3d`, `3 days`, `2d4h` | days, with optional hours and minutes |

- Case and spaces don't matter.
- The result must be at least 1 minute and at most 30 days. Anything outside
  that, a zero, a negative number, or text that can't be read returns `nil`.
- Labels come from one formatter: `30 minutes`, `1 hour`, `1 hour 30
  minutes`, `2 days`, `1 day 4 hours`.

### Templates

- **Default templates for a fresh install:** 30 minutes, 1 hour, 2 hours,
  4 hours, 8 hours, 1 day. Today's defaults also include 12 hours and
  3 days; those two are dropped to keep the menu short.
- **Existing users** keep the presets they have, including 12 hours and
  3 days. If they have more than 8, the 8 shortest are kept, and the rest
  are named in the log.
- **Adding one:** from the menu ("Save … as a template") or in Settings.
  Saving a duration that's already a template does nothing. At most 8
  templates; when the list is full, the save row reads "Templates full.
  Remove one in Settings".
- **Order:** always sorted shortest first, so there's nothing to reorder.
- The "default preset" and "default field" settings go away, because the
  menu has no fields to focus. Empty-field Enter no longer starts anything.

### Sessions with no time limit

What the user sees:

- The session runs until they end it, quit, or a battery or heat rule ends
  it. Lid-close actions, battery and heat rules, and failover work as in a
  timed session.
- The 30-day ceiling doesn't apply.
- There is no 5-minutes-left reminder.

How it stays safe if the app dies: the engine keeps its timed model, and a
session with no time limit is a timed session on a **rolling deadline**.

- On start, the end time is set 60 minutes ahead.
- While the app runs, it extends the end time to 60 minutes ahead every 15
  minutes, through the existing extend path, which re-arms the recovery
  agent and rewrites `session.json`.
- `session.json` gains `"openEnded": true`, so the UI knows to show `∞`
  instead of the countdown.
- If the app crashes, is force-quit, or the Mac restarts, renewals stop. The
  recovery agent then puts sleep back once the last deadline passes: within
  an hour, with no change to `backstop.sh`.
- At launch, a session with `openEnded` whose deadline hasn't passed is
  picked up again as one with no time limit. Renewals resume.
- A renewal that fails (for example, a busy recovery lock) is retried on the
  next 15-minute tick. Since four renewals fit in one deadline, three can
  fail in a row before the session lapses. If the deadline passes anyway,
  the session ends with the reason "Couldn't keep the session going", rather
  than leaving sleep held without a deadline.
- Renewals are silent: no log line above debug level, no notification, and
  no redraw of the menu bar.

**Set a time limit** clears `openEnded` and sets the end time to now plus
the chosen duration (capped at 30 days). **Remove time limit** sets
`openEnded` and moves the end time to 60 minutes ahead.

## 2. Settings

One window, a single grouped `Form`, no tabs. From top to bottom:

```
Apps
  Pause when the lid closes
    [■ Slack ×] [■ WhatsApp ×] [■ Discord ×] [+]
    Paused apps stop using battery while the lid is closed, and carry on
    when you open it.

  Keep at full speed
    [■ Claude ×] [■ Ghostty ×] [■ Cursor ×] [+]
    These apps are never paused or slowed down during a session.

Durations
    [30m ×] [1h ×] [2h ×] [4h ×] [8h ×] [1d ×] [+]

Hotspot backup
    Krish's iPhone            Change…   Remove
    Joins this network if your Wi-Fi drops during a session.

Open at login                                   [toggle]

▸ Advanced
```

### Open at login

The toggle shows what macOS has on file, not the saved setting, as today.
It also keeps today's states and recovery:

- **Waiting for approval:** a line under the toggle reads "Waiting for
  approval in System Settings" with an **Open Login Items** button.
- **macOS refused the change:** its error shows under the toggle.
- **Re-registering after a reinstall:** unchanged.
- **Refreshing:** the status is read again when the window appears and
  whenever the app becomes active.

### App lists

Both lists work the same way.

- **Chips:** each app is a chip showing its 16 pt icon and its name at
  caption size. A chip is a button: clicking its × or pressing Delete while
  it has focus removes it.
- **"+" button:** opens a sheet (a modal Dialog) with a search field and a
  grid of installed apps, each with a 32 pt icon and its name. Clicking an
  app toggles it in this list. A checkmark marks apps already in the list.
  Close the sheet with Done or Esc.
- **One list per app:** an app can be in only one of the two lists. In the
  picker, an app that's in the other list shows "In Keep at full speed" (or
  "In Pause when the lid closes") under its name. Choosing it moves it, and
  doesn't ask first.
- **Hidden entries:** a saved bundle ID whose app isn't installed is not
  shown, but it stays in the config. If the app is installed later, it comes
  back.
- **Defaults:** the existing freeze list and agent list, shown only for
  installed apps. A fresh install of someone with none of the defaults shows
  the "+" button on its own, and the helper line under it.

**What counts as an installed app** (`InstalledApps.scan()`, pure filtering
over a list of bundle records so it can be tested):

- Included: `.app` bundles in `/Applications` and `~/Applications`, up to
  two folders deep (this catches `/Applications/Setapp/…`).
- Left out:
  - anything whose bundle ID starts with `com.apple.`, or that lives under
    `/System`;
  - Insomnia itself;
  - bundles with no bundle ID;
  - bundles marked `LSBackgroundOnly`.
- Menu bar apps (`LSUIElement`) such as Tailscale stay in, since people put
  them on the full-speed list.
- Duplicate bundle IDs keep the copy in `/Applications`.
- Sorted by display name, ignoring case.
- Rescanned each time the sheet opens. The chips read names and icons from
  the same scan, cached for the life of the Settings window.

Removed: the bundle-ID text field and the "Add running app…" menu.

### Durations

The same chips, with the label from the shared formatter (`30m`, `1h`,
`1d 4h`). "+" opens a popover with the custom field and an Add button,
using the same parser as the menu.

### Hotspot backup

See section 3.

### Advanced

A `DisclosureGroup`, collapsed by default. Insomnia remembers whether it was
open between launches. It holds everything else, in these groups:

| Group | Setting (label as shown) | Options | Default |
| --- | --- | --- | --- |
| When the lid closes | Turn off the display and keyboard light | on / off | on |
| | Mute sound | on / off | on |
| | Low Power Mode | on / off | on |
| | Pause Docker when no containers are running | on / off | off |
| | Pause every other app | on / off | off |
| Battery and heat | Low Power Mode below | 0–100%, steps of 5 | 40% |
| | End the session below | 0–95%, steps of 5 (0 turns it off) | 10% |
| | Slow down or end the session when the Mac gets too hot | on / off | on |
| Full-speed apps | Turn off App Nap for these apps | on / off | off |
| Coding agents | Type "continue" into tmux panes after | 10–900 s, steps of 10 | 90 s |
| | Press Return after typing | on / off | off |
| | tmux panes | list of `session:window.pane` | empty |
| About | Version · Check for updates · Show settings file in Finder | — | — |

The battery floors keep today's rule: the end floor always stays below the
Low Power Mode floor, and moving one into the other pushes it along.

Copy rules for this window:

- Name things by what the user sees. No `SIGSTOP`, `NSAppSleepDisabled`,
  bundle IDs or Keychain service names.
- Each toggle gets at most one line of help. The long footers go to the
  README.
- Warnings appear above the section they're about, once each. That covers
  the one-time lid-close change, display refusals, a hotspot password that
  can't be read, and Location Services being off.

The current lid-close, agent, battery, network and App sections are
replaced by this layout. The `Config` fields behind them stay as they are,
except as listed in section 6.

## 3. Hotspot backup

### Setup

1. **Change…** (or **Set up…** when nothing is saved) opens a sheet.
2. **Location Services.** macOS hides network names and hardware addresses
   without it. If access isn't granted yet, the sheet shows one line: "macOS
   only shows Wi-Fi names to apps with Location Services. Insomnia never
   reads your location." It has an **Allow** button. If access was denied,
   the button is **Open Location Services** instead. The network list
   appears once access is granted.
3. **The network list.** The sheet scans with
   `CWInterface.scanForNetworks(withName: nil)` when it opens, then every
   10 seconds while it's open, plus a Rescan button. Each row shows:
   - the network name;
   - signal bars from RSSI;
   - a lock icon when the network has a password;
   - "Connected" on the network the Mac is on now;
   - "Saved on this Mac" on networks macOS already knows, read from the
     Wi-Fi interface's known-network profiles
     (`CWConfiguration.networkProfiles`).

   The list is sorted by signal. Networks with the same name are grouped
   into one row, showing the strongest signal and remembering every BSSID
   seen. Networks with no name are hidden.
4. **Under the list:** "Don't see your iPhone? On the iPhone, open
   Settings > Personal Hotspot and keep that screen open while you choose."
5. **Choosing a network never joins it.** The scan already gives the name,
   the BSSIDs and the security type, so Wi-Fi stays where it is and running
   agents aren't cut off. What happens next depends on the network:
   - **Open network:** **Save** appears on its own.
   - **Secured, and macOS knows it:** **Use saved password** asks macOS for
     the password it stored (`CWKeychainFindWiFiPassword`). macOS shows its
     own dialog asking for an administrator's name and password; Insomnia
     never sees them. On success, the password is copied into Insomnia's
     own Keychain item, so failover never prompts later. If the user
     cancels the dialog, or macOS has no password on file (for example, a
     network joined through Instant Hotspot), a password field appears
     instead.
   - **Secured, and macOS doesn't know it:** a password field and **Save**.
6. **Save checks what it can without joining.** A WPA password must be 8 to
   63 characters, and the network must still be in the latest scan. A
   password that passes is saved as "Not tried yet". Whether it actually
   works is only known at the first real join.
7. **The saved row** shows the network name and one of these:
   - "Not tried yet";
   - "Worked on Oct 23", after a successful failover join;
   - "Password didn't work on Oct 23", after a rejected join, with
     **Change…** highlighted.

   A rejected password during failover also sends one notification: "The
   hotspot password didn't work. Update it in Settings." Failover stops
   trying that network until the password is changed, rather than retrying
   a known-bad password every 30 seconds.
8. **Try now (optional).** For anyone who wants to check before relying on
   it, the saved row has a **Try now** button. This is the only path that
   joins during setup, and it says so first: "Your Wi-Fi drops for a few
   seconds while Insomnia tries this network."
   - While it runs, failover and the tmux nudge's offline timer are paused.
   - Afterwards, Insomnia disconnects so macOS rejoins the previous network
     on its own. If that doesn't happen within 20 seconds, it shows
     "Couldn't get you back on Home Wi-Fi. Choose it in the Wi-Fi menu." (with the real network name)

What gets saved:

| Field | Where | Notes |
| --- | --- | --- |
| SSID | `config.json` → `hotspot.ssid` | |
| BSSIDs | `config.json` → `hotspot.bssids` | Every BSSID seen for this network, up to 4, newest first. Taken from the scan, so no join is needed |
| Security type | `config.json` → `hotspot.security` | From `CWNetwork`, used to rule out a look-alike open network |
| Password | Login Keychain, as today | Same access-list and replace rules as spec section 7. Typed by the user, or copied once from macOS's saved password |
| Last result | `config.json` → `hotspot.lastJoin` | `{ result: worked or rejected, at: date }`, or absent for "Not tried yet" |

### When failover starts

During a session only, as today. Failover starts when either of these
happens:

- **Wi-Fi drops:** the Wi-Fi path is unsatisfied for 5 seconds. This is
  today's trigger.
- **Wi-Fi has no internet (new):** Wi-Fi is connected, but the internet
  check fails three times in a row, 10 seconds apart.

**The internet check** is an HTTP GET of
`http://captive.apple.com/hotspot-detect.html` with a 5-second timeout.
It passes when the response body contains `Success`. While the path is
satisfied, the check runs only after `NWPathMonitor` reports a change, and
then every 30 seconds while the last check failed. It never polls while
things are healthy.

### Which network to join

`HotspotMatcher.pick(saved:scan:) -> CWNetwork?` is pure:

1. **BSSID match:** a scan result whose BSSID is one of the saved BSSIDs,
   and whose security type matches.
2. **Name match:** otherwise, a scan result with the saved SSID and the same
   security type. If more than one matches, take the strongest. After a
   successful join, add its BSSID to `hotspot.bssids`, because iPhones can
   change it.
3. **Nothing:** otherwise return `nil` and keep the existing backoff (5, 10,
   20, 30, then every 30 seconds).

The scan is unfiltered (`withName: nil`), because a BSSID match needs every
result. The join and Keychain read are the same as today.

### Privacy

Two things are new compared with today:

- **The internet check** is new outbound traffic. It's a plain HTTP request
  to Apple's captive-portal address, sent only during a session and only
  after a network change or a failed check. It carries no data about the
  Mac. The README's privacy section has to say so, since it currently
  promises that the only network request is the update check, sent when you
  click.
- **Hardware addresses (BSSIDs)** of the saved hotspot are written to
  `config.json` and can appear in the log, next to network names, which are
  already logged. The README's note to check logs before sharing them
  covers BSSIDs too.

The installed-app scan reads app bundles on disk and sends nothing anywhere.

### Moving from the old setup

A config with only `hotspotSSID` becomes `hotspot.ssid` with no BSSIDs.
Failover still works by name match. Settings shows "Choose this network again
from the list so Insomnia can recognise it" above the hotspot row until the
network is chosen again.

## 4. Notifications

All of today's notifications stay, with the same triggers:

- the session ended, with the reason;
- the 5-minutes-left reminder;
- the battery floor was reached;
- the battery couldn't be read;
- a heat action was taken;
- the network came back;
- the recovery agent restored sleep;
- something else disabled sleep;
- the one-time lid-close settings change.

The 5-minutes-left reminder isn't sent for a session with no time limit,
and the rolling deadline never triggers it.

One change: the 5-minutes-left reminder gets an **Add 1 hour** action
button, which extends the session the same way the menu item does. Its body
changes from pointing at the pills to "Add time from the menu bar, or press
Add 1 hour."

## 5. Docs to update when this ships

- `docs/spec.md` sections 7 (network failover), 10 (settings) and 11
  (menu bar UI).
- The README's "Using it" steps, its hotspot section, and its privacy
  section.
- `docs/assets/session-flow.svg` and its alt text. Both show typed fields
  and press-and-hold.
- `docs/extras.md`, for the hotspot setup.

## 6. Config changes

`Config` stays a forgiving `Codable` struct that fills in defaults for keys
it doesn't find. Version the file with `"version": 2`.

| v1 key | v2 |
| --- | --- |
| `presets` | `templates`: same seconds, sorted, deduplicated, capped at 8 |
| `defaultPreset`, `defaultFocusField` | dropped |
| `maxDuration` | dropped as a setting; a 30-day constant for timed sessions |
| `session.json` | gains `openEnded` (absent means timed); older builds ignore it and see a session ending within the hour |
| `hotspotSSID` | `hotspot.ssid` (see "Moving from the old setup") |
| `freezeList`, `agentList` | unchanged, except that a bundle ID in both is removed from `freezeList` (keeping the protective choice) |
| new | `hotspot.bssids`, `hotspot.security`, `hotspot.lastJoin`, `advancedExpanded` |

Migration runs once on load, writes the file back as v2, and is logged.
Older builds reading a v2 file fall back to defaults for the keys they
can't find, which the decoder already handles.

## 7. Code: what goes and what stays

**Removed:**

- `DurationInput`, `PillView`, `KeyCatcherPanel`, `HoldToEndButton`
- the pill stagger and fold animations in `StatusRootView`, `Motion`
- `CountdownShape`, `formatCountdown`
- the bundle-ID list editor in `SettingsView`

**New:**

- `CountdownFormat`, `DurationParser`, `DurationLabel`
- `OpenEndedLease` (the rolling deadline for sessions with no time limit)
- `TemplateList` (add, remove, sort, cap)
- `InstalledApps`, `AppChip`, `AppPickerSheet`
- `HotspotSetupSheet`, `HotspotMatcher`, `InternetCheck`
- `StatusMenu` rebuilt around the two menu layouts above

**Changed:**

- `StatusItemController`: a click opens the menu; no key monitors.
- `NetworkFailover`: the no-internet trigger and an unfiltered scan, with
  `HotspotMatcher` choosing the network.
- `HotspotJoiner`: joins a given `CWNetwork`.
- `Config`: v2 and the migration.

**Kept as is:**

- `SessionManager`, `SleepGuard`, `LidActions`, `Freezer`, `FreezePlanner`
- `FloorRules`, `PowerMonitor`, `DisplayPower`, `AudioControl`,
  `BrowserThrottle`
- `LaunchdBackstop`, the recovery journal, `OwnerOnly`, Keychain storage
- the installer and uninstaller

## 8. Testing

CI runs `swift build -c release -Xswiftc -warnings-as-errors` and `swift test` (`.github/workflows/ci.yml`). There is no UI test
target, so:

**Unit tests (pure logic):**

- `CountdownFormat`: each row of the table in section 1, plus the 59-second,
  60-second, 23h 59m 30s, and exactly-one-day edges.
- `DurationParser`: every row of its table, plus `0`, `-5`, `31d`, `1.5`
  (minutes), empty text and nonsense text.
- `TemplateList`: deduplication, the cap of 8, sorting, and that removing
  the last template leaves an empty list rather than the defaults.
- `InstalledApps` filtering: Apple apps, `/System`, self, `LSBackgroundOnly`,
  duplicates, and the two-folder depth.
- App list moves: adding to one list removes from the other.
- `HotspotMatcher`: a BSSID match beats a stronger name match, a
  security-type mismatch is rejected, a name-only match records the new
  BSSID, and an empty scan returns `nil`.
- The failover trigger with the internet check: three failures start
  failover, one success resets the count, and nothing runs outside a session.
- A rejected hotspot password stops further joins to that network until the
  password changes, and posts one notification.
- Hotspot save checks: an 8 to 63 character WPA password passes, 7 and 64
  fail, and an open network needs no password.
- `CountdownFormat` width: the reserved width never shrinks within a
  pattern, and is reset when the pattern drops a level.
- Rolling deadline (a pure `OpenEndedLease` over a fake clock):
  - renewal moves the end time to 60 minutes ahead;
  - Set a time limit clears `openEnded` and caps at 30 days;
  - Remove time limit sets it;
  - a lapsed deadline ends the session with its own reason;
  - a relaunch before the deadline resumes renewals;
  - no 5-minutes-left reminder is scheduled for an open-ended session.
- The v1 → v2 migration: each row of the table in section 6, plus an app
  that's on both lists.

Mutation-check each of these: break the source, watch the test fail, then
restore it.

**Manual checks** (recorded in the PR):

- The menu opens on left and right click.
- Typing goes into the custom field without clicking it first. If not, use
  the fallback in section 1.
- The countdown changes only at minute boundaries.
- A session with no time limit shows `∞`. After force-quitting the app,
  sleep comes back within an hour.
- The Location Services prompt, the denied state, and the network list
  filling in.
- A real iPhone hotspot: choosing it from the list keeps Wi-Fi where it
  is, and turning off home Wi-Fi during a session joins the hotspot.
- **Use saved password** on a network macOS knows: macOS's admin dialog
  appears, the password is copied, and cancelling the dialog falls back to
  the password field.
- A wrong saved password: the failover join is rejected, one notification
  arrives, and Settings shows "Password didn't work".
- **Try now** drops Wi-Fi, doesn't trigger failover, and returns to the
  previous network.
- A start refused (for example, with the sudoers rule removed) shows the
  badge and the "Couldn't start" line.
- The app picker sheet with VoiceOver: each app reads as "Slack, in list"
  or "Slack".

## 9. Open questions

1. **Switching back from the hotspot.** After failover, should Insomnia
   rejoin home Wi-Fi when it comes back, or leave that to macOS? Currently
   macOS decides, which can leave the Mac on the phone's data for hours.
2. **iPhone BSSID stability.** If an iPhone's hotspot BSSID turns out to
   change on every restart, the BSSID match adds little over a name match.
   Measure on a real phone before relying on it.
3. **Reading macOS's saved Wi-Fi password.** `CWKeychainFindWiFiPassword`
   is old CoreWLAN API. Confirm in the first prototype that it still works
   on macOS 26 from an ad-hoc-signed app, and that the admin dialog
   appears. If it doesn't, drop **Use saved password** and always ask for
   the password.
4. **Joining a known network without its password.** It's possible that
   `associate(to:password: nil)` joins a network macOS already knows, using
   macOS's own copy. That would remove both the admin dialog and Insomnia's
   copy. Try it in the same prototype; if it works reliably, prefer it.
5. **Browser relaunch.** The "Relaunch Chrome unthrottled" items stay in the
   menu. They could move to Advanced, if they're rarely used.
