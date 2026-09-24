# Install Codex Navigator

[← Back to the overview](../README.md)


Codex Navigator is built from source on your Mac. There is no installer download and no account to create.

### Requirements

- macOS 14 (Sonoma) or later on Apple Silicon or Intel.
- Xcode Command Line Tools (Swift 5.9 or newer). Install with `xcode-select --install`, or install Xcode from the App Store.
- The Codex desktop app or the Codex CLI, signed in. Navigator reads its local history from `~/.codex` and talks to the `codex` executable for live features.
- `/usr/bin/python3`, which the Command Line Tools provide. No pip packages are needed.

### Build and open

```sh
git clone https://github.com/danielhinkles/Codex-Navigator.git
cd Codex-Navigator
bash scripts/build.sh
open 'dist/Codex Navigator.app'
```

The build takes about a minute the first time. It produces `dist/Codex Navigator.app`, which you can drag into `/Applications` if you like. The app is ad-hoc signed on your own machine and is not notarised; if macOS asks, right-click the app and choose **Open** once.

The first launch indexes your local Codex history progressively; recently updated sessions come first. Later launches show cached sessions immediately. Navigator keeps its own data in `~/Library/Application Support/Codex Navigator/` and never edits Codex's files.

### Check the install

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo
```

The first command runs the backend tests. The second opens the app with fictional demo data and no Codex connection, which is a safe way to look around.

### Update or uninstall

To update, pull the latest source and run `bash scripts/build.sh` again. To uninstall, delete `Codex Navigator.app` and, if you also want to remove the local index and preferences, delete `~/Library/Application Support/Codex Navigator/`.

Optional environment overrides: `NAVIGATOR_CODEX` (path to the `codex` executable), `CODEX_HOME` (Codex history location, default `~/.codex`), `NAVIGATOR_CACHE` (Navigator data directory).


For first-launch guidance and troubleshooting, see the [User Guide](USER-GUIDE.md).
