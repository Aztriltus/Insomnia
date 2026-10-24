<p align="center">
  <img src="docs/assets/eye-open.svg" alt="Insomnia: an open eye with a round pupil and five lashes above it" width="112">
</p>

<h1 align="center">Insomnia</h1>

<p align="center">
  <strong>Keep your Mac awake, lid open or closed, for as long as you choose.</strong>
</p>

<p align="center">
  An eye in your MacBook's menu bar. No Dock icon, no main window.
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/License-MIT-536D78?style=flat-square"></a>
  <img alt="macOS 26 or later" src="https://img.shields.io/badge/macOS-26%2B-303336?style=flat-square">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-only-303336?style=flat-square">
</p>

> **Use a stable, well-ventilated surface, not a closed bag.** Insomnia is
> experimental. Recovery can fail, and a running timer is not a safety
> guarantee. [Apple's ventilation guidance](https://support.apple.com/en-us/102336)

A simplified fork of [krishhgg/Insomnia](https://github.com/krishhgg/Insomnia): the same engine with a new menu, Settings and hotspot setup.

## Install

Needs macOS 26 or later on an Apple Silicon Mac.

1. Download the DMG from the [latest release](https://github.com/Aztriltus/Insomnia/releases/latest) and open it.
2. Double-click **Install Insomnia** and enter your Mac password when Terminal asks. It's used once, to let Insomnia turn sleep off and on.
3. Insomnia opens as an eye in the menu bar.

Insomnia updates itself: it checks once a day, and **Check for updates** at the top of Settings checks now. To uninstall, double-click **Uninstall Insomnia** in the DMG.

<details>
<summary><strong>What the installer changes on your Mac</strong></summary>

- The app, at `~/Applications/Insomnia.app`.
- A **recovery agent**, a `launchd` job that runs every minute. If the app is gone when a session should have ended, it undoes the session's changes. It only runs an app signed by the same developer.
- A **sudoers rule** at `/etc/sudoers.d/insomnia` that lets your user account run exactly these four commands without a password:

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -b lowpowermode 1
/usr/bin/pmset -b lowpowermode 0
```

Any program running as you can use that rule too, so review it before you install. [docs/install.md](docs/install.md#what-gets-installed) lists every file.

</details>

## Using it

Click the eye. The menu opens with **Active** or **Inactive**, and below it a grid: ∞ (no time limit), 10m, 30m, 1h, 2h, 4h, 8h, 12h and 24h.

- **Start:** click a cell. It fills with your accent colour and counts down.
- **Switch:** click another cell.
- **End:** click the running cell again.

The eye in the menu bar is open during a session and closed otherwise. A session with no time limit keeps a rolling deadline an hour ahead, so if Insomnia crashes, the recovery agent still turns sleep back on within an hour. You don't have to close the lid, and opening it doesn't end the session.

On battery, Insomnia turns on Low Power Mode below 40% and ends the session below 10%. When the Mac gets too hot it slows down, then ends the session. All three are on by default; change them under Settings > Advanced.

## Settings

- **Open at login** and **Check for updates**.
- **Pause when the lid closes:** apps paused while the lid is closed and resumed when it opens. Starts with Slack, WhatsApp and Discord, if installed.
- **Keep at full speed:** apps never paused or slowed down.
- **Durations:** the grid's times, up to eight.
- **Hotspot backup:** your iPhone hotspot, joined when Wi-Fi drops during a session.
- **Advanced:** lid, battery, heat, coding-agent and file options.

Only apps you installed are listed, as an icon and a name.

## When the lid closes

During a session, closing the lid turns off the display and keyboard light, mutes sound, turns on Low Power Mode and pauses the apps in **Pause when the lid closes**. Opening the lid undoes each of these. Each can be turned off under Settings > Advanced.

Closing the lid disconnects the built-in microphone in hardware, so a meeting with the lid closed needs AirPods or an external mic. [docs/lid-close.md](docs/lid-close.md) has the details.

## Hotspot backup

If Wi-Fi drops, or stays connected with no internet, during a session, Insomnia joins your iPhone's hotspot.

1. In System Settings > Wi-Fi, set **Ask to join hotspots** to **Automatically**. Only macOS can wake a hotspot that isn't broadcasting; Settings warns you when this is off.
2. In Settings > Hotspot backup, choose **Set up…** and pick your iPhone. Networks your Mac has joined before are listed even when they're out of range, and their password comes from macOS, which may ask for your Mac password.
3. Choose **Try now** to check the password. Your Wi-Fi drops for a few seconds and comes back.

To tell whether Wi-Fi has internet, Insomnia loads Apple's captive-portal page during a session, after a network change or a failed check. Nothing about your Mac is sent. [docs/extras.md](docs/extras.md) has the details.

## Throttled browsers

Chrome, Chromium, Arc and Comet slow down hidden windows, which is every window with the lid closed. When one of them is throttled, the menu shows its icon under **Throttled**; click it to relaunch the browser unthrottled. Relaunching quits it, so it asks first.

## How recovery works

<p align="center">
  <img src="docs/assets/recovery-flow.svg" alt="The app and a launchd backstop coordinate through a shared lock and recovery journal. The app handles normal cleanup. The backstop checks every minute and attempts due recovery, leaving valid active sessions alone. Failed or unreadable recovery evidence stays on disk; saved audio needs the app and unconfirmed stopped processes need inspection." width="880">
</p>

Insomnia writes each change to a recovery journal before it makes it. Ending the session undoes what the journal lists. If the app crashes or quits, the recovery agent does the same once the session's end time has passed. It can't restore sound or watch the battery; open Insomnia again for those. If the menu shows a warning, deal with it before you leave the Mac. [docs/recovery.md](docs/recovery.md) explains each case.

Settings live in `~/Library/Application Support/Insomnia/config.json` and logs in `~/Library/Logs/Insomnia/`. Logs can name Wi-Fi networks and apps, so check them before you share one.

## Development

Needs Xcode with Swift 6.2 or later.

```bash
swift build
swift test
./scripts/install.sh
```

Read [docs/spec.md](docs/spec.md), [docs/decisions.md](docs/decisions.md) and [docs/engineering.md](docs/engineering.md) before changing anything. Releases are built, signed and published with `./scripts/release.sh`; see the runbook in docs/engineering.md. [Security reporting](SECURITY.md) · [Contributing](CONTRIBUTING.md)

## License

[MIT](LICENSE)
