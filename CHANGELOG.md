# Changelog

## 0.1.0 — 2026-09-08

- First release, extracted from a private project. Two skills — `/smartScreenshot` (Android by
  default, `--ios` for a simulator on macOS) and `/processSmartScreenshot` — plus a
  `/smartScreenshotSetup` walkthrough, an installer / uninstaller in the shape of prompt-todo's,
  and a `config.json` in place of the hard-coded app ids: `android.package` / `android.packages`,
  `ios.bundleId`, `ios.simulators`, `version.file` + `version.regex` for the build number when
  the app is not installed, `testTagsFile`, `outputDir`, `slugMaxLength`, `annotator.port`. With
  nothing configured the capture names itself after the foreground app; `install.sh` pre-fills
  the config from the repo's gradle / Xcode files.
- Runs on macOS (`/bin/bash` 3.2 included), Linux and Windows under Git Bash: Python 3 is found
  under any of its names, the selector no longer needs `mapfile`, the PNG check uses `od` rather
  than `xxd`, adb's CR LF output is stripped, the browser opens through `open` / `xdg-open` /
  Python's `webbrowser`, and the sidecar and the config are written LF-only. `--ios` refuses to
  run off macOS before looking for anything.
- Device-free tests: a fake `adb` that answers every command the capture issues and logs the
  overlay toggles, the annotator server over HTTP, the selector, the converter self-test,
  detection, install / uninstall. CI on Ubuntu, macOS (both bashes) and Windows.
- A banlist check keeps the words that would identify the original project out of the repo:
  a tracked, non-identifying list plus an optional git-ignored `scripts/banlist.local.txt`.
