# Insomnia spec

What Insomnia does, feature by feature, as behaviour. How the build does it is in [engineering.md](engineering.md); why it is this way is in [decisions.md](decisions.md).

## Product

Insomnia keeps a MacBook awake, lid open or closed, for as long as you choose (a set time, or until you end it), then puts everything back. It lives in the menu bar as an eye icon, with no Dock icon and no main window. While the lid is closed it saves battery by pausing apps you don't need, muting sound and dimming the screen, and keeps the apps you do need (coding agents, terminals, editors) at full speed. If Wi-Fi drops, it can move the Mac to your phone's hotspot.

It is meant for a Mac on a stable, ventilated surface, never in a closed bag.

**Outcomes it is judged on**

1. A session always ends when it should (at its end time, when you end it, on a battery or heat limit, or on Quit), and even a crash can't leave sleep held for more than an hour past the last deadline. Afterwards sleep behaviour is back to how it was.
2. Anything a session changed (sleep, Low Power Mode, paused apps, sound, brightness) is undone, or the user is told exactly what wasn't.
3. Agents keep working with the lid closed, and the battery lasts longer than it would with the Mac simply kept awake.
4. Starting a session takes one click, and the app can be set up without reading the README.
5. Losing Wi-Fi during a session costs seconds, not a stalled agent.

## 1. Sessions

- A session is timed or has no time limit.
- A timed session lasts at most 30 days, including time added; adding past that caps at 30 days.
- A session with no time limit runs until you end it, quit, or a battery or heat rule ends it. If Insomnia crashes or is force-quit, the recovery agent still puts sleep back within an hour.
- During a session, closing the lid doesn't sleep the Mac. Opening it doesn't end the session.
- A session ends when its time runs out, when you end it, when you quit, or when a battery or heat rule ends it (section 5). Ending it puts back sleep and undoes every lid-close action.
- Starting takes a few seconds, because Insomnia sets up its crash-recovery job and turns off sleep with an admin command. A start can be refused; the reason is shown (section 2).
- If something other than Insomnia has turned sleep off, Insomnia says so once per launch and leaves it alone.

## 2. Menu bar

### The icon

The status item is the eye, as the button's image in macOS's standard square slot, so it has the same width and vertical position as the system's own icons.

| State | Menu bar shows | VoiceOver reads |
| --- | --- | --- |
| Idle | Closed eye | "Insomnia" |
| Starting or running | Open eye | "Insomnia, starting", "Insomnia, 5 hours 12 minutes left" or "Insomnia, awake with no time limit" |
| Something needs attention | The eye with a small orange dot | adds ", needs attention" |

The eye is centred by its visible shape, so open (lashes up) and closed (lashes down) both sit on the menu bar’s centre line. The time left is in the menu, not the menu bar.

### The menu

Left or right click opens the same menu. It follows the layout of macOS's Battery menu: standard menu text throughout, a bold first row, grey section headings and separators between sections.

```
(eye) Active          until 6:40 PM    <- the eye is open or closed, as in the menu bar
Couldn't start. Try again.             <- only what needs attention, in orange
---------------------------------
Keep awake for                         <- grey heading
[ ∞  ] [ 10m ] [ 30m ]
[ 1h ] [ 2h  ] [ 4h  ]
[ 8h ] [ 12h ]
---------------------------------
Throttled                              <- only when a browser is throttled
(Chrome icon)
---------------------------------
Settings…                       ⌘,
Quit Insomnia                   ⌘Q
```

- **The first row** shows the eye (closed when inactive, open when active, as in the menu bar; it blinks open or shut in place when the state changes while the menu is open), the state in bold ("Inactive", "Starting…", "Active"), and on the right in grey, "until 6:40 PM" ("until Sat 6:40 PM", "until Oct 30, 6:40 PM" further out) or "No time limit". It isn't clickable.
- **Under it**, only lines that need attention, in orange: "Couldn't start. Try again." (until the next start, or until the menu has been opened and closed once; the reason is in the log), "Not keeping the Mac awake", "Sleep is still turned off", "Hotspot password missing", "Hotspot password needs re-entering", "Something went wrong", "A power command is stuck", "Another app has turned sleep off", "Couldn't relaunch the browser", and "Headphones is still muted" with "Stop waiting for Headphones".
- **Keep awake for** is a grid of ∞ (no time limit) and the durations from Settings (10m, 30m, 1h, 2h, 4h, 8h, 12h and 24h by default), three to a row, filling a 3 by 3 grid. The menu stays open after a click and updates in place.
  - With nothing running, clicking a cell starts that session.
  - While a session runs, its cell is filled in the accent colour with white text, like the Battery menu’s active mode, and its label counts down the time left ("2h" becomes "1h 59m", …; ∞ stays ∞). Clicking another cell switches to it: the session then ends that long from now, or has no time limit for ∞. Clicking the running cell ends the session and its label goes back to normal.
  - While starting, the grid is greyed out.
  - A running session with no matching cell gets an End session item under the grid.
- **Throttled:** each throttled browser's icon, with no label. Clicking one offers "Relaunch unthrottled" and "Advanced settings…".
- **Quit** undoes the session first, and refuses while a change is still waiting to be undone.

### Durations

- Up to 8, always shortest first, edited in Settings. Exactly one day reads "24h". ∞ is always in the grid and isn't one of them.
- A fresh install, and anyone upgrading from an earlier build, starts with 10m, 30m, 1h, 2h, 4h, 8h, 12h and 24h. A saved list that is exactly the earlier seven defaults gains 24h; an edited list is left alone.

## 3. Settings

One window. The top level holds:

| Setting | What it does | Default |
| --- | --- | --- |
| Open at login | Shows what macOS has on file; a pending approval shows "Waiting for approval in System Settings" with Open Login Items; an error shows under it | off |
| Version | The installed version, with Check for updates (Sparkle; also checks once a day on its own and installs on your say-so) | |
| Pause when the lid closes | Apps shown as small icon and name chips; paused while the lid is closed, resumed when it opens | Slack, WhatsApp, Discord (when installed) |
| Keep at full speed | Apps never paused or slowed down during a session | Common terminals, editors, AI apps, agent browsers, Docker, Tailscale, LM Studio, Ollama (when installed) |
| Durations | The grid's durations, as chips with add and remove (up to 8) | 10m, 30m, 1h, 2h, 4h, 8h, 12h, 24h |
| Hotspot backup | The saved hotspot, with Change… and Remove (section 6) | not set |
| Advanced | Collapsed group; remembers whether it was open | collapsed |

**App lists**

- Only apps you installed are shown (in Applications or your own Applications folder). Apple's apps, background-only helpers and Insomnia itself are left out. Menu bar apps are included.
- "+" opens a searchable grid of installed apps with icons. Clicking toggles the app in that list.
- An app is in at most one list; picking it for the other list moves it.
- An app you've removed from the Mac disappears from the list, and comes back if you reinstall it.

**Advanced**

| Group | Setting | Options | Default |
| --- | --- | --- | --- |
| When the lid closes | Turn off the display and keyboard light | on / off | on |
| | Mute sound | on / off | on |
| | Low Power Mode | on / off | on |
| | Pause Docker when no containers are running | on / off | off |
| | Pause every other app | on / off | off |
| Battery and heat | Low Power Mode below | 0–100%, steps of 5 | 40% |
| | End the session below | 0–95%, steps of 5; 0 turns it off | 10% |
| | Slow down or end the session when the Mac gets too hot | on / off | on |
| Full-speed apps | Turn off App Nap for these apps | on / off | off |
| Coding agents | Type "continue" into tmux panes after | 10–900 s | 90 s |
| | Press Return after typing | on / off | off |
| | tmux panes | list | empty |
| About | Show settings file in Finder | | |

The end floor always stays below the Low Power Mode floor; moving one into the other pushes it along.

## 4. When the lid closes

During a session only. Without a session, the lid does nothing special.

| Action | Default | On lid open |
| --- | --- | --- |
| Display and keyboard light go off (brightness saved first) | on | brightness put back |
| Apps on the pause list are paused | on, list as above | resumed |
| Every other app is paused, except protected apps | off | resumed |
| Sound is muted | on | each output Insomnia muted is unmuted, even after switching outputs |
| Low Power Mode on | on | off, unless a battery or heat rule still needs it |
| Docker Desktop paused when no container runs | off | resumed |

- Protected apps are never paused automatically: full-speed apps, Apple's apps, editors, terminals, browsers, AI apps, password managers, local databases, Tailscale, local model servers, and meeting, recording and dictation apps (Zoom, Teams, Webex, FaceTime, Wispr Flow, Granola, Otter, OBS, Loom). Putting one on the pause list on purpose overrides this.
- Insomnia only resumes an app it can prove it paused. One it can't prove stays paused and is reported.
- On Mac laptops with Apple silicon or a T2 chip, closing the lid disconnects the built-in microphone in hardware; recording with the lid closed needs an external mic.
- Chrome, Chromium, Arc and Comet slow down hidden windows, which is every window with the lid closed. When a running one lacks the flags that stop this, the menu offers to relaunch it unthrottled, asking first because relaunching quits it.

## 5. Battery and heat

- On battery, Low Power Mode turns on below 40% and the session ends below 10% (both changeable; 0 turns the end off).
- When the Mac gets seriously hot, Low Power Mode turns on; at critical heat the session ends. On by default.
- These rules only work while the app runs.

## 6. Hotspot backup

**Setup never joins the network**, so Wi-Fi isn't interrupted.

1. Change… opens a sheet. Without Location Services access, the sheet asks for it first ("macOS only shows Wi-Fi names to apps with Location Services. Insomnia never reads your location."), with Allow, or Open Location Services if it was denied.
2. A list of nearby networks, refreshed every 10 seconds and on Rescan, shows name, signal, a lock for secured networks, "Connected" and "Saved". Same-name networks show as one row. Below them come the networks macOS has saved that aren’t in range, marked "Not in range": usually the iPhone hotspot, which only broadcasts while its Personal Hotspot screen is open. They can be chosen too; Insomnia records the hotspot’s hardware address the first time it sees it.
3. Under it: "Not listed? Open Personal Hotspot on your iPhone."
4. Choosing a network:
   - Open network: Save.
   - Secured and saved on this Mac: Use saved password, which looks in your keychain first (where an iCloud-synced hotspot’s password usually is) and only then shows macOS’s own administrator dialog; cancelling falls back to typing it.
   - Otherwise: type the password and Save. It must be 8 to 63 characters.
5. The saved row shows "Not tried yet", "Worked on Oct 23", or "Password didn't work on Oct 23", with Change… and Remove.
6. **Try now** asks first ("Your Wi-Fi drops for a few seconds."), then joins the hotspot once with the saved password, with failover paused so the drop isn’t taken for an outage. It records "Worked on …" or "Password didn’t work on …", then disconnects so macOS rejoins the previous network. If that doesn’t happen within 20 seconds it says "Couldn’t get back on Home. Choose it in the Wi-Fi menu."; if the hotspot isn’t broadcasting, "Not in range. Open Personal Hotspot on your iPhone and try again."

**macOS’s own auto-join.** Only macOS can wake an iPhone hotspot that isn’t broadcasting, and only when System Settings > Wi-Fi > Ask to join hotspots is Automatically. Settings shows a warning row, "Set Ask to join hotspots to Automatically", with Open Wi-Fi Settings. macOS usually won’t let Insomnia read that setting (it needs Full Disk Access), so the row has a Done button that hides it for good; when Insomnia can read the setting, the row follows it instead: hidden for Automatically, shown for Ask or Never.

**Not tried yet** changes after Try now, or the first time failover joins the hotspot, to "Worked on Oct 24" or "Password didn’t work on Oct 24". The saved password is tied to the build of Insomnia that saved it, so after a reinstall it has to be chosen again.

**Failover**, during a session only, starts when Wi-Fi drops for 5 seconds, or stays connected with no internet for three checks 10 seconds apart. Insomnia joins the saved network, recognised by its hardware address first and its name second, retrying after 5, 10, 20 and 30 seconds, then every 30 seconds. A rejected password sends one notification ("The hotspot password didn't work. Update it in Settings.") and stops retries until the password changes.

**Older setups** that saved only a name keep working by name, and Settings asks you to choose the network again from the list.

## 7. Coding agents in tmux

After a set time offline (90 seconds by default), Insomnia can type `continue` into tmux panes you list in Settings and also mark yourself with `tmux set-option -p -t <pane> @insomnia-nudge on`. It presses Return only if you turn that on. Mark a pane you don't type in.

## 8. Notifications

| Notification | When |
| --- | --- |
| Session ended (or Session restored, Sleep restored, Session not started) | A session ends, with the reason: time up, ended by you, quit, battery, heat, recovery, or a failed start. Adds a line when sound is still muted on a disconnected output |
| 5 minutes left | Five minutes before the end of a timed session (never for one with no time limit), with an **Add 1 hour** button |
| Low Power Mode on / off | A battery or heat rule turned it on, or the charger or battery level turned it off (lid-caused changes are silent) |
| Network recovered | Wi-Fi came back after at least the nudge threshold, with how many tmux panes were nudged |
| Hotspot not joined | Once per outage, when the hotspot can't be joined (for example, an unreadable password) |
| The hotspot password didn't work | A failover join was rejected |
| Restore incomplete, Session not ended, Recovery journal unreadable, Session file unreadable | Something a session changed couldn't be undone yet; the menu says what |
| Power command still running | A sleep or Low Power Mode command didn't exit |
| Sleep is disabled by something else | Once per launch |
| Browser not relaunched | A relaunch you asked for didn't happen |
| Lid-close settings changed | Once, when an update changed lid-close defaults |

## 9. Recovery

- Every change is written to a recovery journal on disk before it's made. Ending the session undoes what the journal lists.
- If the app crashes or quits mid-session, a recovery agent that runs every minute tries the same undo once the session's end time has passed. It leaves a live session alone.
- Some things need you: the recovery agent can't restore sound (open Insomnia again), doesn't watch battery or heat, and won't resume an app it can't prove was paused.
- A recovery warning in the menu should be dealt with before leaving the Mac alone.

## 10. Install and privileges

- macOS 26 or later on Apple Silicon. Installed by a script, not the App Store; releases come as a stable channel and daily nightlies.
- The installer asks for your password once and installs the app in `~/Applications`, the recovery agent, and a sudoers rule that lets your account run exactly these four commands without a password:
  - `/usr/bin/pmset -a disablesleep 1`
  - `/usr/bin/pmset -a disablesleep 0`
  - `/usr/bin/pmset -b lowpowermode 1`
  - `/usr/bin/pmset -b lowpowermode 0`
- Any program running as you can use that rule too.
- The uninstaller undoes any open session first, then removes the app, the agent and the rule (and, with `--purge`, settings and logs).
- Distributed as a DMG with an Install command. Updates arrive over the air with Sparkle from the fork’s GitHub Releases: checked once a day and from Settings, signed with an EdDSA key, and installed in place.

## 11. Privacy and data

| What | Where | Leaves the Mac? |
| --- | --- | --- |
| Settings | `~/Library/Application Support/Insomnia/config.json`, owner-only | no |
| Session state and recovery journal | same folder, owner-only | no |
| Logs (may name Wi-Fi networks, hardware addresses, processes and tmux panes) | `~/Library/Logs/Insomnia/`, owner-only | no; check before sharing |
| Hotspot password | your login Keychain, readable without a prompt only by the build that saved it | no |
| Location Services | used only to read Wi-Fi names and hardware addresses; your location is never requested | no |
| Installed-app list | read from app bundles on disk when Settings needs it | no |
| Update check | Sparkle fetches the appcast from GitHub Releases once a day and when you click | yes, carrying the app and macOS versions |
| Internet check | an HTTPS request to Apple's captive-portal page during a session, only after a network change or a failed check | yes, carrying nothing about the Mac |

## Quality bar

- `swift build` with warnings as errors and `swift test` pass in CI on every change.
- Each release passes the real-Mac checks in [releasing.md](releasing.md#real-mac-checks-before-a-release), recorded in [release-validation.md](release-validation.md).
- Redesign pieces ship with the manual checks listed in redesign-spec.md's testing section, recorded in the PR.

## Known issues

All confirmed in code (2026-10-23), none reproduced on a Mac yet.

- The menu's "N apps frozen" counts processes, so one app with helpers reads as several apps.
- "Low Power Mode off" says "Back above the floor" even when heat turned it on, and after a relaunch a lid-caused switch-off is announced.
- Quitting with no session running still posts "Session restored. Insomnia quit."
- "Network recovered" says "Nudged 0 tmux panes" when no panes are set up.
- Today's time fields accept up to 30d 23h 59m, and the session is cut to 30 days without saying so. (The redesign's parser rejects anything over 30 days.)
- Edge, Brave and Vivaldi are never checked for throttling.
- The 5-minutes-left reminder is sent outside the app's normal notification path, so it isn't logged like the others.
