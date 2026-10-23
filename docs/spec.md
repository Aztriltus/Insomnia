# Insomnia spec

What Insomnia does, feature by feature, as behaviour. Anything marked **Planned** is not built yet. How the build does it is in [engineering.md](engineering.md); why it is this way is in [decisions.md](decisions.md).

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

### Icon and countdown

| State | Menu bar shows | VoiceOver reads |
| --- | --- | --- |
| Idle | Closed eye | "Insomnia" |
| Starting | Open eye and the time the session will have | "Insomnia, starting" |
| Running | Open eye and the time left | "Insomnia, 5 hours 12 minutes left" |
| Running with no time limit | Open eye and `∞` | "Insomnia, awake with no time limit" |
| Start failed | Closed eye with a warning badge | "Insomnia, needs attention" |
| Needs attention during a session | Open eye with a warning badge, countdown stays | adds ", needs attention" |

The time left shows one or two units and never seconds:

| Time left | Shows |
| --- | --- |
| 3 days 4 hours 20 minutes | `3d 4h` |
| 3 days 0 hours | `3d` |
| 5 hours 12 minutes | `5h 12m` |
| 5 hours 0 minutes | `5h` |
| 42 minutes 10 seconds | `43m` |
| 20 seconds | `1m` |

- Time rounds up to the minute, so the bar never reads `0m` while a session runs.
- The text changes once a minute. Its width only grows during a session, except when it drops from days to hours or hours to minutes, so the menu bar doesn't jiggle.
- The eye blinks open and closed. With Reduce Motion on, it crossfades instead.

### The menu

Left or right click opens the same menu.

**No session:**

- "Keep awake for" followed by your templates (for example 30 minutes, 1 hour, 2 hours, 4 hours, 8 hours, 1 day), then **No time limit**. Choosing one starts a session.
- A custom field that takes `45`, `45m`, `2h`, `1h30m`, `1:30`, `1.5h`, `3d` or `2d4h`. A bare number means minutes. Anything from 1 minute to 30 days.
  - While it holds a valid time, the line under it reads "Start for 45 minutes ↩" (Return does it), with a Save as template button.
  - While it holds text that can't be read: "Try 45m, 2h or 1d".
  - Esc clears it; a second Esc closes the menu.
- Status and warning lines, if any.
- Settings… (⌘,) and Quit Insomnia (⌘Q).

**Session running:**

- "Awake until 6:40 PM" (or "Sat 6:40 PM", or "Oct 30, 6:40 PM" when further out). The time left isn't repeated.
- "Add time" followed by the templates, then the custom field with "Add 45 minutes".
- Remove time limit.
- End session. It ends at once, with no hold or confirmation.

**Session with no time limit:** "Awake with no time limit" heads the menu, then "Set a time limit" with the templates and the custom field ("End in 45 minutes"), which end the session that long from now. Then End session, the status lines, Settings… and Quit.
- Status and warning lines, Settings…, Quit Insomnia.

**Starting:** the menu shows "Starting…" and the status lines, Settings and Quit, until the start finishes.

**Start failed:** "Couldn't start: reason" heads the menu above the idle items. It and the badge clear on the next successful start, or once the menu has been opened and closed.

**Status and warning lines** include: sleep being held, lid state, paused apps, Docker, a throttled browser with a "Relaunch … unthrottled" item, a hotspot password problem, a recovery problem, a command still running, and sound still muted on a disconnected output with a "Stop waiting for …" item.

**Quit** undoes the session first, and refuses while a change is still waiting to be undone.

### Templates

- A fresh install has 30 minutes, 1 hour, 2 hours, 4 hours, 8 hours and 1 day. People upgrading keep the presets they had (the 8 shortest, if they had more).
- Up to 8, always sorted shortest first. No time limit is always offered and isn't a template. Saving a duplicate does nothing; saving into a full list says "Templates full. Remove one in Settings".

## 3. Settings

One window. The top level holds:

| Setting | What it does | Default |
| --- | --- | --- |
| Pause when the lid closes | Apps shown as small icon and name chips; paused while the lid is closed, resumed when it opens | Slack, WhatsApp, Discord (when installed) |
| Keep at full speed | Apps never paused or slowed down during a session | Common terminals, editors, AI apps, agent browsers, Docker, Tailscale, LM Studio, Ollama (when installed) |
| Durations | The templates, as chips with add and remove | as in section 2 |
| Hotspot backup | The saved hotspot, with Change… and Remove (section 6) | not set |
| Open at login | Shows what macOS has on file; a pending approval shows "Waiting for approval in System Settings" with Open Login Items; an error shows under it | off |
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
| About | Version, Check for updates, Show settings file in Finder | | |

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
2. A list of nearby networks, refreshed every 10 seconds and on Rescan, shows name, signal, a lock for secured networks, "Connected" and "Saved on this Mac". Same-name networks show as one row.
3. Under it: "Don't see your iPhone? On the iPhone, open Settings > Personal Hotspot and keep that screen open while you choose."
4. Choosing a network:
   - Open network: Save.
   - Secured and saved on this Mac: Use saved password, which shows macOS's own administrator dialog, then copies the password; cancelling falls back to typing it.
   - Otherwise: type the password and Save. It must be 8 to 63 characters.
5. The saved row shows "Not tried yet", "Worked on Oct 23", or "Password didn't work on Oct 23", with Change… and Remove.
6. **Planned:** a **Try now** button that joins on purpose, after warning that Wi-Fi drops for a few seconds, then returns to the previous network.

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
- Check for updates asks GitHub only when clicked and installs nothing; upgrading means running the installer again.

## 11. Privacy and data

| What | Where | Leaves the Mac? |
| --- | --- | --- |
| Settings | `~/Library/Application Support/Insomnia/config.json`, owner-only | no |
| Session state and recovery journal | same folder, owner-only | no |
| Logs (may name Wi-Fi networks, hardware addresses, processes and tmux panes) | `~/Library/Logs/Insomnia/`, owner-only | no; check before sharing |
| Hotspot password | your login Keychain, readable without a prompt only by the build that saved it | no |
| Location Services | used only to read Wi-Fi names and hardware addresses; your location is never requested | no |
| Installed-app list | read from app bundles on disk when Settings needs it | no |
| Update check | two requests to GitHub, only when you click | yes, carrying only the app version |
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
