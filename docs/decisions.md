# Decisions

Why this fork of Insomnia is the way it is. Each entry gives the decision, the reason, and what was turned down. When a later decision covers the same thing, the older row is marked **Superseded YYYY-MM-DD** and kept. **The newest row on a topic wins.** Rows marked *(planned)* describe the redesign target, not the current build.

Only the owner's decisions are logged here. Upstream's design choices (krishhgg/Insomnia, before the fork) are not carried over; where one constrains the build, it appears in [engineering.md](engineering.md) as a fact.

Sources: the Claude Code sessions of 2026-10-23 and 2026-10-24 that started the redesign.

## Scope

**Where it stands:** a simpler fork. Keep upstream's engine (sleep guard, lid-close actions, recovery) and rebuild the menu bar, settings and hotspot setup so the app can be used without reading the README.

**Replaced:** none.

<details>
<summary>3 decisions</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-23 | **Redo the app as a simple macOS menu bar app; users should only have to think about which apps are added.** | The owner's brief. | Keeping upstream's breadth of options at the top level. |
| 2026-10-23 | **Keep the engine; rebuild the UI, settings, hotspot setup and saved-settings shape.** | Nothing requested needs the engine changed. | A full rewrite. |
| 2026-10-23 | **This fork keeps its own decision log; upstream's decisions aren't carried over.** | "Ignore the decisions not made by me. I just forked this." | Importing upstream's history as decisions. |

</details>

## Sessions

**Where it stands:** *(planned)* a session is timed (up to 30 days) or has no time limit. Today every session is timed.

**Replaced:** none.

<details>
<summary>1 decision</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-24 | **Sessions can have no time limit, offered as "No time limit" in the menu.** *(planned)* | "Sessions can be unlimited. Lets provide that option." | Timed sessions only. |

</details>

## Menu bar

**Where it stands:** the menu bar shows the eye alone, at one fixed width. Clicking it opens a short menu. Its first line says Active or Inactive and isn't clickable. Under it is a 4×2 grid of ∞, 10m, 30m, 1h, 2h, 4h, 8h and 12h: a cell starts or switches the session, the highlighted cell ends it, and the menu stays open meanwhile. Only lines that need attention are shown, in plain words.

**Replaced:** a menu of templates with a custom-time field and Save as template (2026-10-23) → a grid with no custom field (2026-10-24) · a two-unit countdown in the menu bar (2026-10-23) → the eye alone (2026-10-24).

<details>
<summary>20 decisions</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-23 | **Clicking the icon opens a menu of templates (minutes, hours, days) to start a session, with a field to type a custom time and a way to save a new template.** **Superseded 2026-10-24** | The owner's brief. | Upstream's typed Days / Hours / Minutes fields in the menu bar. |
| 2026-10-23 | **The countdown shows at most two units and never seconds: days and hours, hours and minutes, or minutes.** **Superseded 2026-10-24** | "Makes more sense to show maybe up to 2 values." | Seconds. |
| 2026-10-23 | **Units are written as suffixes: `2d 5h`, `5h 12m`, `42m`, `1m`.** **Superseded 2026-10-24** | `02:05` is ambiguous between days and hours and hours and minutes. | Colons (`DD:HH`, `HH:MM`). |
| 2026-10-24 | **The menu's durations are a grid: ∞, 10m, 30m, 1h, 2h, 4h, 8h, 12h. No custom-time field.** | The custom field and the list "made the menu too long when clicked". | A list of templates; typing a custom time in the menu. |
| 2026-10-24 | **The first line is not clickable and says whether a session is active.** | Owner's request. | A header that repeats the end time only. |
| 2026-10-24 | **Grid cells toggle: clicking one starts or switches to it, and it's highlighted; clicking the highlighted cell ends the session. No separate End button.** | Chosen from two options. | Clicking the eye starts ∞ at once, with a separate End session item. |
| 2026-10-24 | **The lid, watts, battery and Wi-Fi line is left out of the menu.** | "Don't think we need the long line in the menu." | Keeping it. |
| 2026-10-24 | **Throttled browsers show as a "Throttled" heading over their icons, with no labels; clicking an icon offers Relaunch unthrottled or Advanced settings.** | Owner's request. | A warning line plus one "Relaunch … unthrottled" item per browser. |
| 2026-10-24 | **The running grid cell is filled in the accent colour and counts down the time left; clicking it ends the session and its label goes back to normal.** | "Show which grid item was clicked, and modify that grid item label so it counts down." | A highlight with a fixed label. |
| 2026-10-24 | **A dot in the accent colour goes in front of the Active line.** **Superseded 2026-10-24** | Owner's request. | Text alone. |
| 2026-10-24 | **The menu follows macOS’s Battery menu: a first row with the eye (open or closed) and the state in bold, the end time in grey on the right, grey section headings, standard text size, separators between sections.** | Owner’s request, with a screenshot of the Battery menu. | A dot before Active; small text for warnings. |
| 2026-10-24 | **The running cell is drawn by hand: accent fill, white text.** | NSButton’s accent bezel turns grey in a menu, whose window is never active; the owner expected the Battery menu’s look. | NSButton bezel colour. |
| 2026-10-24 | **The eye is centred by its visible shape, in the menu bar and the menu; the menu’s eye blinks when the state changes.** | The open eye sat 1.75 pt high; "maybe eye should animate in the menu too". | Centring the 18 pt canvas. |
| 2026-10-24 | **24h is the eighth duration, filling a 3 by 3 grid; exactly a day reads "24h"; a saved list of the old seven defaults gains it.** | "Add 1 more grid item option for 24h so it fills up the 3x3 grid." | A half-empty last row. |
| 2026-10-24 | **The grid has three columns.** | The menu was too wide with four; owner suggested fewer columns. | Four wider columns. |
| 2026-10-24 | **The status item is the eye as the button’s image in the standard square slot; it no longer animates.** | "Keep it to minimum or to apple’s standard"; the custom view sat high and wide. | A custom-drawn view with a blink. |
| 2026-10-24 | **All copy is short: no help lines that repeat a title, no engineer explanations, no raw errors; ending a session yourself posts no notification.** | "Deslop the whole app for long labels or redundant text." | The longer explanatory copy. |
| 2026-10-24 | **The menu bar shows the eye alone and never gets wider; no countdown.** | "The menu should stay as a single icon. Shouldn't get wider at all." | A two-unit countdown next to the eye. |
| 2026-10-24 | **The menu stays open after a grid cell is clicked; the first line and highlight update in place.** | Owner's request. | Closing the menu on each choice. |
| 2026-10-24 | **The menu leaves out status and diagnostic lines (journal state, paused-app counts, raw errors) and shows only what needs attention, in plain words.** | "Should omit any slop labels in the dropdown menu." | "Sleep held per journal — not verified live", "3 apps frozen · last gap", raw error text. |

</details>

## Settings

**Where it stands:** *(planned)* progressive disclosure. The top level shows two equal app lists, durations, hotspot and Open at login; everything else is folded under Advanced. Only installed apps are shown, as a small icon and name.

**Replaced:** none.

<details>
<summary>3 decisions</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-23 | **Use progressive disclosure to hide most settings away and clean the window up.** *(planned)* | The owner's brief. | One long window. |
| 2026-10-23 | **Only apps the user downloaded are shown, each as its icon and a small title; apps they don't have are hidden.** *(planned)* | Users should only think about whether apps are added. | Typed bundle identifiers; showing defaults for apps that aren't installed. |
| 2026-10-23 | **Two equal lists at the top: "Pause when the lid closes" and "Keep at full speed".** *(planned)* | Chosen from mockups. | One list with the other under Advanced; one grid with three states per app. |

</details>

## Hotspot backup

**Where it stands:** *(planned)* when there's no internet, Insomnia falls back to a hotspot chosen from a list of networks the Mac can see. It remembers the name, the hardware address and the password. Choosing never joins the network; the password comes from macOS if it already knows the network, or the user types it.

**Replaced:** checking the network by joining it during setup → no join during setup (2026-10-23).

<details>
<summary>8 decisions</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-23 | **The hotspot is chosen from a list of networks the Mac can see, and Insomnia remembers its SSID, hardware address (BSSID) and password.** *(planned)* | "So we don't guess by just typing the SSID." | A typed SSID. |
| 2026-10-23 | **Setup checks the network by joining it once.** *(planned)* **Superseded 2026-10-23** | Proves the password works. | — |
| 2026-10-23 | **Setup never joins: it takes what it needs from the scan, reuses the password macOS saved if it knows the network, and otherwise asks the user to type it.** *(planned)* | A test join drops Wi-Fi and cuts off running agents (owner's correction). | Joining during setup. |

</details>

## Testing

**Where it stands:** the suite keeps only the essentials and runs in under a minute.

**Replaced:** upstream's full suite (about 1,250 tests, 20 minutes) → the essentials (about 515 tests, under a minute) (2026-10-24).

<details>
<summary>1 decision</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-24 | **Cut the test suite to the essentials: the session engine, recovery, lid actions, floors, failover, config, the menu, and a core set of recovery-script cases.** | "The full test suite is slow for such a small app." | Keeping upstream's edge-case suites (branding, release workflow, brightness, hung commands, keychain internals and others). |

| 2026-10-24 | **The setup sheet also lists networks macOS has saved that aren’t in range, so the iPhone hotspot can be chosen without opening its Personal Hotspot screen.** | "Usually I won’t do that when I need it to auto-connect." | Listing only what a scan sees. |
| 2026-10-24 | **Use saved password tries the user’s own keychain before macOS’s administrator dialog.** | The admin dialog is macOS’s; no API fills in its name. | Prefilling the dialog. |
| 2026-10-24 | **Settings checks macOS’s Ask to join hotspots (`AutoHotspotMode`) and asks for Automatically when it’s Ask or Never.** | Only macOS can wake a hotspot that isn’t broadcasting; Ask needs someone at the Mac. | Leaving it to the README. |
| 2026-10-24 | **Try now joins the saved hotspot once to check the password, with failover paused, then disconnects so macOS rejoins the previous network.** | "Are we able to offer a step to let users try?" | Leaving the status at Not tried yet until a real outage. |
| 2026-10-24 | **The auto-join row is a requirement with a warning icon and a Done button, because a normally launched app is refused that preferences file.** | The row showed while the setting was Automatically; "it needs to show warning icon so it looks more like a requirement". | Claiming the setting is off when it can’t be read; asking for Full Disk Access. |

</details>

## Distribution

**Where it stands:** a DMG built by `scripts/build-dmg.sh`, ad-hoc signed and not notarized; installing runs the bundled installer. TestFlight isn't possible for this app.

**Replaced:** none.

<details>
<summary>7 decisions</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-24 | **Distribute as a DMG holding the app, the installer scripts, double-clickable Install and Uninstall commands, and a Read Me.** | "Can we build a dmg so I can distribute?" Insomnia needs its installer (sudoers rule, recovery agent), so drag-to-Applications can't work. | A drag-to-Applications DMG. |
| 2026-10-24 | **Ship under the fork’s own bundle ID, `com.zacheryng.insomnia`; the scripts still quit an app with upstream’s ID.** | Builds are signed with the owner’s Developer ID. | Keeping `com.kgarg.insomnia`. |
| 2026-10-24 | **Developer ID signing with the hardened runtime, and notarization of the app and the DMG, when the identity and notary profile exist; ad-hoc otherwise.** | "Yes set it up." Removes the Gatekeeper prompts, and a team-pinned signature survives updates. | Ad-hoc only. |
| 2026-10-24 | **Over-the-air updates with Sparkle, from an appcast on the fork’s GitHub Releases (`releases/latest/download/appcast.xml`), released with `scripts/release.sh`.** | "So they can just check for updates and get it when I update it." | GitHub Pages for the appcast; upstream’s report-only update check. |
| 2026-10-24 | **The installer trusts a bundle signed by team H37KGF95Y9 and accepted by Gatekeeper as notarized, without `--allow-unverified-origin`.** | Its old warning ("not notarized", "origin not verified") was wrong for signed builds. | Warning on every prebuilt bundle. |
| 2026-10-24 | **Upstream’s release workflow is manual-only in the fork.** | A `v*` tag would otherwise publish an unsigned zip and collide with the release from `release.sh`. | Keeping tag and nightly triggers. |
| 2026-10-24 | **No TestFlight.** | TestFlight only carries App Store builds, which must be sandboxed; Insomnia runs `sudo pmset`, pauses other apps' processes, uses private display APIs and installs a launchd agent. | Reworking the app for the App Store. |

</details>

## Spec review

**Where it stands:** the gap fixes from the 2026-10-23 review are accepted and written into the redesign spec.

**Replaced:** none.

<details>
<summary>1 decision</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-23 | **Accepted the review's gap fixes: a starting state and a start-failed state in the menu bar; a steady countdown width; notifications kept, with Add 1 hour on the reminder; the Open at login states kept; defaults listed for every Advanced setting; existing presets kept on upgrade; failover paused during an optional hotspot join; privacy notes for the internet check and hardware addresses; old docs to update when the redesign ships.** *(planned)* | Owner: "Apply all". | — |

</details>

## Docs review

**Where it stands:** the drafted docs and the defaults Claude chose were approved on 2026-10-24, except where a later row says otherwise.

**Replaced:** none.

<details>
<summary>2 decisions</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-24 | **Accepted Claude's spec defaults:** a bare number means minutes and the field takes 1 minute to 30 days (the field was later removed); up to 8 templates, shortest first, with 30m, 1h, 2h, 4h, 8h and 1d for a fresh install (later replaced by the grid's seven); both clicks open the same menu; End session ends at once; the countdown rounds up to the minute and its width only grows; an app is in one list at most; "no internet" is three failed captive-portal checks 10 s apart; the hotspot is matched by hardware address, then by name; a rejected password notifies once and stops retries; the reminder gets Add 1 hour. *(planned)* | Owner: "Other than that, looks good." | — |
| 2026-10-24 | **Docs layout:** upstream's `docs/spec.md` becomes `docs/design-notes.md`, and the new behaviour spec takes its path; `docs/redesign-spec.md` stays as the build brief until the redesign ships; upstream leftovers (bundle ID, update-check URLs, merge-gate workflow) wait for later. | Approved with the review. | Deleting the redesign brief now. |

</details>

## Defaults not yet confirmed

These came from Claude after the review, not from the owner. Confirm or change each, then log it above.

- A session with no time limit is a rolling 60-minute deadline renewed every 15 minutes, so a crash puts sleep back within an hour.
- The menu bar shows `∞` for a session with no time limit.
- "Remove time limit" and "Set a time limit" switch a running session between the two kinds; a new limit counts from now.
- The internet check uses HTTPS, so no App Transport Security exception is needed.
- The grid's durations are editable in Settings (up to 7), and earlier builds' presets aren't carried over: everyone starts from the grid defaults.
- A running session whose duration isn't in the grid gets an End session item, so it can always be ended.
- While starting, the grid is greyed out.

## Open questions

- After failover, should Insomnia rejoin home Wi-Fi when it returns, or leave that to macOS?
- Do iPhone hotspot hardware addresses stay the same across restarts? Measure before relying on the address match.
- Does reading macOS's saved Wi-Fi password (`CWKeychainFindWiFiPassword`) still work on macOS 26 from an ad-hoc-signed app?
- Does joining a known network without a password use macOS's own copy reliably? If so, prefer it over copying the password.
- Is typing in a text field inside the menu reliable on macOS 26? If not, use a "Custom…" popover.
- Should "Relaunch … unthrottled" move to Advanced?
- Should this fork keep merging from upstream? The redesign rewrites the files most upstream changes touch.
- The 7 known issues at the end of the spec: fix now, fold into the redesign, or leave?
