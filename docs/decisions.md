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

**Where it stands:** clicking the eye opens a short menu. Its first line says Active or Inactive and isn't clickable. Under it is a 4×2 grid of ∞, 10m, 30m, 1h, 2h, 4h, 8h and 12h: a cell starts or switches the session, and the highlighted cell ends it. There's no custom-time field and no lid, watts, battery or Wi-Fi line. The countdown shows at most two units with suffixes and no seconds.

**Replaced:** a menu of templates with a custom-time field and Save as template (2026-10-23) → a grid with no custom field (2026-10-24).

<details>
<summary>8 decisions</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-23 | **Clicking the icon opens a menu of templates (minutes, hours, days) to start a session, with a field to type a custom time and a way to save a new template.** **Superseded 2026-10-24** | The owner's brief. | Upstream's typed Days / Hours / Minutes fields in the menu bar. |
| 2026-10-23 | **The countdown shows at most two units and never seconds: days and hours, hours and minutes, or minutes.** | "Makes more sense to show maybe up to 2 values." | Seconds. |
| 2026-10-23 | **Units are written as suffixes: `2d 5h`, `5h 12m`, `42m`, `1m`.** | `02:05` is ambiguous between days and hours and hours and minutes. | Colons (`DD:HH`, `HH:MM`). |
| 2026-10-24 | **The menu's durations are a grid: ∞, 10m, 30m, 1h, 2h, 4h, 8h, 12h. No custom-time field.** | The custom field and the list "made the menu too long when clicked". | A list of templates; typing a custom time in the menu. |
| 2026-10-24 | **The first line is not clickable and says whether a session is active.** | Owner's request. | A header that repeats the end time only. |
| 2026-10-24 | **Grid cells toggle: clicking one starts or switches to it, and it's highlighted; clicking the highlighted cell ends the session. No separate End button.** | Chosen from two options. | Clicking the eye starts ∞ at once, with a separate End session item. |
| 2026-10-24 | **The lid, watts, battery and Wi-Fi line is left out of the menu.** | "Don't think we need the long line in the menu." | Keeping it. |
| 2026-10-24 | **Throttled browsers show as a "Throttled" heading over their icons, with no labels; clicking an icon offers Relaunch unthrottled or Advanced settings.** | Owner's request. | A warning line plus one "Relaunch … unthrottled" item per browser. |

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
<summary>3 decisions</summary>

| Date | Decision | Why | Turned down |
| --- | --- | --- | --- |
| 2026-10-23 | **The hotspot is chosen from a list of networks the Mac can see, and Insomnia remembers its SSID, hardware address (BSSID) and password.** *(planned)* | "So we don't guess by just typing the SSID." | A typed SSID. |
| 2026-10-23 | **Setup checks the network by joining it once.** *(planned)* **Superseded 2026-10-23** | Proves the password works. | — |
| 2026-10-23 | **Setup never joins: it takes what it needs from the scan, reuses the password macOS saved if it knows the network, and otherwise asks the user to type it.** *(planned)* | A test join drops Wi-Fi and cuts off running agents (owner's correction). | Joining during setup. |

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
- "Try now" is deferred; setup never joins.

## Open questions

- After failover, should Insomnia rejoin home Wi-Fi when it returns, or leave that to macOS?
- Do iPhone hotspot hardware addresses stay the same across restarts? Measure before relying on the address match.
- Does reading macOS's saved Wi-Fi password (`CWKeychainFindWiFiPassword`) still work on macOS 26 from an ad-hoc-signed app?
- Does joining a known network without a password use macOS's own copy reliably? If so, prefer it over copying the password.
- Is typing in a text field inside the menu reliable on macOS 26? If not, use a "Custom…" popover.
- Should "Relaunch … unthrottled" move to Advanced?
- Should this fork keep merging from upstream? The redesign rewrites the files most upstream changes touch.
- The 7 known issues at the end of the spec: fix now, fold into the redesign, or leave?
