# Contributing

Read [docs/spec.md](docs/spec.md), [docs/decisions.md](docs/decisions.md) and [docs/engineering.md](docs/engineering.md) before changing anything; [CLAUDE.md](CLAUDE.md) has the ground rules.

## Pull requests

- Work on a branch and open a pull request into `main`. CI builds and tests it on macOS 26.
- Build and test locally first:

  ```bash
  swift build -c release -Xswiftc -warnings-as-errors
  swift test
  ```

- There's no UI test target. Check menu and Settings changes by hand, and say what you checked in the pull request.
- Update the spec, decisions and engineering notes in the same pull request when behaviour, a decision or the build changes.
- Titles and commit subjects are `type(scope): description`, for example `fix(menu): keep the grid open after a click`. Release notes are built from `feat`, `fix`, `update`, `style` and `perf` subjects.

## Releasing

Run `./scripts/bump-version.sh <major.minor.patch>` in a pull request. Merging it into `main` publishes a signed, notarized release that installed copies update to. Merges that don't change the version publish nothing. docs/engineering.md has the runbook.

## Security

Report vulnerabilities as [SECURITY.md](SECURITY.md) describes, not in an issue.
