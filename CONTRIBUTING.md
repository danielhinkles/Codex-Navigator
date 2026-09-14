# Contributing to Codex Navigator

Thanks for helping improve Navigator. For bugs and feature ideas, [open an issue](https://github.com/danielhinkles/Codex-Navigator/issues). For a substantial change, describe the proposal in an issue first so its scope can be discussed.

## Develop locally

Follow the [installation guide](docs/INSTALL.md), then read [AGENTS.md](AGENTS.md) and the [Technical Reference](docs/TECHNICAL-REFERENCE.md).

```sh
python3 scripts/verify.py
bash scripts/build.sh
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo
```

The default verification runner runs offline Python and standalone Swift checks without submitting a model turn. Some checks require local loopback networking or macOS preference access. App building and native UI checks are available through `python3 scripts/verify.py --build --ui`.

Live checks are separate opt-ins: `--live-history` reads local Codex history; `--live` submits one ephemeral model turn and can consume account usage. Review the scripts before using either option.

## Keep organisation local

Dragging, grouping, pinning, sorting, and assigning existing items must only change Navigator metadata. Never move source folders or directly edit Codex’s saved state. Explicit New Project registration through the project API is the documented exception. Keep the regression coverage for these boundaries.

## Send a focused change

Explain the problem, resulting behaviour, and checks you ran. For interface changes, include screenshots using `--demo` and check keyboard navigation and light/dark appearance. Update the relevant guide when behaviour changes.

Do not include private conversations, credentials, personal filesystem paths, or real history caches in issues, screenshots, or test fixtures. Keep generated builds and verification logs out of commits.
