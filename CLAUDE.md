# Insomnia

macOS menu bar app for timed awake sessions on Apple Silicon MacBooks (Swift 6.2 package, no Xcode project). This repo is a fork of krishhgg/Insomnia being reworked into a simpler app; the engine stays, the menu bar, settings and hotspot setup are being rebuilt.

## Before you change anything

1. Read docs/spec.md: what the product does, feature by feature. Features marked **Planned** are the redesign target and not built yet.
2. Read docs/decisions.md: why, and what was already turned down. Don't re-propose a rejected option without saying what changed. The newest entry on a topic wins. It logs only the owner's decisions; upstream's choices aren't binding unless docs/engineering.md lists them as a measured constraint.
3. For implementation work, read docs/engineering.md. While the redesign is in progress, docs/redesign-spec.md is the build brief for it; docs/spec.md wins where they disagree.
4. If the request conflicts with the spec or decisions, say so before editing.

## After you change something

- User-visible behaviour or settings changed → update docs/spec.md in the same commit (and flip **Planned** to built when a redesign piece ships). Implementation, contracts or release flow → docs/engineering.md.
- The owner decided something (including a "no") → add a dated row to docs/decisions.md; mark replaced rows **Superseded** and update that topic's "Where it stands" and "Replaced" lines.
- Fixed a known issue → remove it from the spec in the same commit.
- Never write secrets into docs or git. Logs and docs may name Wi-Fi networks; never commit real SSIDs, BSSIDs or passwords.

## Ground rules

- Never change sleep, power or process state outside an active session, and journal every change before making it. Recovery must be able to undo anything a session did.
- The sudoers rule is exactly four `pmset` commands. Don't add commands, wildcards or another privileged path; README.md, docs/install.md, SECURITY.md and docs/spec.md list the same four.
- Tests use fakes and a temporary `INSOMNIA_HOME`; no test may touch real power settings, Wi-Fi, Keychain or processes.
- Put decisions in pure, testable types (formatters, parsers, matchers, planners) and keep UI thin. There is no UI test target, so UI behaviour is checked by hand and the PR says so.
- Copy names what the user sees: no `SIGSTOP`, bundle IDs, Keychain service names or other internals in the app's UI.

Build:

```bash
swift build -c release -Xswiftc -warnings-as-errors
```

Test:

```bash
swift test
```

Install a local build (asks for your password, writes the sudoers rule and launchd agent):

```bash
./scripts/install.sh
```
