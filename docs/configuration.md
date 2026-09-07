# Configuration

Everything lives in `.claude/smart-screenshot/config.json`; `config.example.json` next to it is
the reference shape. Every key is optional — a missing or empty value means "use the default".
Environment variables override the config for one run and are meant for the machine-specific
values (a device serial, a simulator udid) rather than project-wide ones.

`install.sh` writes the file from the example and fills the empty values with what
`bin/detect_project.py` finds in the repository. `/smartScreenshotSetup` walks through the same
values inside Claude Code. To see what detection would propose without writing anything:

```bash
bash .claude/smart-screenshot/bin/py.sh detect_project.py          # human-readable
bash .claude/smart-screenshot/bin/py.sh detect_project.py --json
bash .claude/smart-screenshot/bin/py.sh detect_project.py --write .claude/smart-screenshot/config.json   # fill empties
```

## Keys

| Key                     | Default              | Env override                      | Meaning |
|-------------------------|----------------------|-----------------------------------|---------|
| `outputDir`             | `smartScreenShot`    | `SMART_SCREENSHOT_DIR`            | Capture folder, relative to the project root unless absolute. `install.sh` git-ignores it (anchored, `/smartScreenShot/`). |
| `slugMaxLength`         | `10`                 | —                                 | Length cap of the commit slug in the filename. |
| `android.package`       | —                    | `SMART_SCREENSHOT_PACKAGE`        | The app whose `versionCode` names the capture. |
| `android.packages`      | `[]`                 | —                                 | A priority list instead of one id — the first entry *installed on the device* wins. Put the debug variants first. |
| `android.deviceSerial`  | —                    | `SMART_SCREENSHOT_DEVICE_SERIAL`, `ANDROID_SERIAL` | Pick a device when several are connected. |
| `android.deviceHost`    | —                    | `SMART_SCREENSHOT_DEVICE_HOST`    | `host:port` for wireless adb; used when no device is visible. |
| `ios.bundleId`          | —                    | `SMART_SCREENSHOT_IOS_BUNDLE_ID`  | The app whose `CFBundleVersion` names the capture. |
| `ios.simulators`        | `["iPhone 16", "iPhone 15"]` | `SMART_SCREENSHOT_IOS_SIM` | Preferred simulators by name, best first. The first one that exists is used, booted if needed — even when another simulator is already running. The env var takes a name or a udid. |
| `ios.maestroBin`        | `~/.maestro/bin/maestro`, then `PATH` | `MAESTRO_BIN`     | Path to the maestro CLI. |
| `ios.hierarchyTimeout`  | `90`                 | `SMART_SCREENSHOT_IOS_TIMEOUT`    | Seconds allowed for the first hierarchy dump; the retry with a driver reinstall gets double. |
| `version.file`          | —                    | —                                 | Where the build number lives when the app is not installed (relative to the project root). |
| `version.regex`         | —                    | —                                 | A Python regex with one capture group applied to that file (`MULTILINE`); the first match is the version. |
| `testTagsFile`          | —                    | —                                 | The file that lists the app's test tags (`TestTags.kt`, say). The skills read it to map a `resource-id` back to the code that drew the node. |
| `annotator.port`        | `0` (random)         | `SMART_SCREENSHOT_PORT`           | Preferred annotator port; a random free one when it is taken. |

Two more environment variables have no config counterpart:

- `SMART_SCREENSHOT_PREFIX` — the filename stem prefix (default `smartScreenShot`, or
  `smartScreenShot_ios` under `--ios`). Useful when one folder collects captures of two apps.
- `SMART_SCREENSHOT_PY` — force the Python command (`python3`, `python`, `py`).

## How the app is chosen

The version in the filename is the *installed* app's, read from the device, so the script needs
to know which app. In order:

1. `SMART_SCREENSHOT_PACKAGE` / `SMART_SCREENSHOT_IOS_BUNDLE_ID`.
2. `android.package` / `ios.bundleId`.
3. Android only: the first entry of `android.packages` that `pm list packages` reports.
4. Android: the package that owns the focused window (`dumpsys window`, then `dumpsys
   activity`). iOS: the one non-Apple app the simulator is running (`launchctl list`); several
   running apps or none means "not identified".

When the app is not installed or not identified the version comes from `version.file` +
`version.regex`; with nothing configured it is `0`. The capture itself always proceeds — the
version only affects the filename — and a log line says which source was used.

## What detection finds

`detect_project.py` walks the repository (skipping `build/`, `node_modules/`, `.git/`,
`DerivedData/`, `Pods/` and the like) and proposes:

- **`android.package` / `android.packages`** from `applicationId` in `build.gradle` /
  `build.gradle.kts`, combined with every `applicationIdSuffix` in the same file. Build-type and
  flavour suffixes are not distinguishable by a regex, so every pairing is listed and the ones
  ending in `.debug` come first; an unused combination costs nothing because the first
  *installed* entry wins. A single id with no suffixes becomes `package`. An
  `AndroidManifest.xml` `package=` is the fallback for older projects.
- **`ios.bundleId`** from `PRODUCT_BUNDLE_IDENTIFIER` in `*.pbxproj` / `*.xcconfig`, ignoring
  test targets and `$(…)` placeholders; the most frequent value wins.
- **`version`** from the first of: a `versionCode = 42` literal, a
  `versionCode = providers.gradleProperty("key")` (→ `gradle.properties`, `^key=(.*)$`),
  `pubspec.yaml`'s `version: 1.2.3+45` (→ the build number), `CURRENT_PROJECT_VERSION` in a
  pbxproj.
- **`testTagsFile`** from a file named `TestTags.kt`, `TestTags.swift`, `TestTags.ts` or
  `test_tags.dart`.

`--write` fills only the values that are empty in the config; `--force` overwrites.
