---
name: smartScreenshotSetup
description: "The configuration walkthrough for smart-screenshot: detect the app's Android package(s), iOS bundle id, version fallback and test-tag file, check the tools (adb, xcrun, maestro, Python), and write .claude/smart-screenshot/config.json. Runs only when the user invokes it: '/smartScreenshotSetup', '/smartScreenshotSetup android', '/smartScreenshotSetup ios', '/smartScreenshotSetup tools', '/smartScreenshotSetup --yes'."
argument-hint: "[android|ios|version|tags|output|tools|summary] [--yes]"
disable-model-invocation: true
allowed-tools: Read, Edit, Write, Glob, Grep, AskUserQuestion, Bash(bash .claude/smart-screenshot/bin/py.sh:*), Bash(bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --help), Bash(bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --ios --help), Bash(command:*), Bash(adb devices:*), Bash(adb version), Bash(xcrun simctl list:*), Bash(ls:*), Bash(cat .claude/smart-screenshot/config.json)
---

# /smartScreenshotSetup

Guided setup of smart-screenshot, run inside the project after `install.sh`. Nothing here is
required: a capture already works with the config `install.sh` wrote (it pre-fills what
`detect_project.py` can find). Each step explains why it exists, shows the current value, asks,
and writes. Any step can be skipped, and re-run later by name.

```
/smartScreenshotSetup            all steps in order
/smartScreenshotSetup ios        one step
/smartScreenshotSetup --yes      every default, no questions
```

## Ground rules

- The config is `.claude/smart-screenshot/config.json`; its shape is `config.example.json` next
  to it. Edit with `Edit` (or `Write` when missing), keep the keys the example has, keep it valid
  JSON. Never delete a value the user set by hand unless they say so.
- Detection comes from `bash .claude/smart-screenshot/bin/py.sh detect_project.py --json`
  (nothing is written by that call). Run it once at the start and reuse the result.
- Environment variables (`SMART_SCREENSHOT_*`) override the config per run; mention them when a
  value is machine-specific (a device serial, a simulator udid) rather than project-wide.
- Unknown step name → list the step ids and stop.
- Finish every run (single step or all) with the **summary**, unless the run *was* only the
  summary step.

## Step 1 — `android`: package(s)

Explain: the capture is named after the installed app's `versionCode`, so the script has to know
*which* app. Without a value it uses whatever app is in the foreground, which is right most of the
time but wrong when a dialog from another app is up.

Show the detected `android.package` / `android.packages` (flavour × build-type combinations,
debug first). Ask: keep, edit, or leave empty (foreground detection). Write `android.package`
(one id) or `android.packages` (a priority list — the first *installed* one wins).
`android.deviceSerial` / `android.deviceHost` stay empty unless the user has a fixed device or a
wireless adb host. `--yes`: keep what was detected.

## Step 2 — `ios`: bundle id and simulator

Explain: `--ios` needs macOS, Xcode's `simctl`, Java and the Maestro CLI. The bundle id names the
app whose `CFBundleVersion` goes into the filename; the simulator list says which simulator to
prefer, booted or not.

Show the detected `ios.bundleId` and the current `ios.simulators`. On macOS, offer
`xcrun simctl list devices available` to pick names from. Ask; write `ios.bundleId`,
`ios.simulators`; `ios.maestroBin` only when maestro lives somewhere unusual. On Linux or Windows
say the step is moot and skip. `--yes`: keep what was detected.

## Step 3 — `version`: fallback when the app is not installed

Explain: when the app is not on the device the version would be `0`; `version.file` +
`version.regex` (one capture group) name where the build number lives in the repo instead.

Show the detected pair (a `versionCode = 42` literal in a gradle file, a
`providers.gradleProperty("key")` → `gradle.properties` + `^key=(.*)$`, `pubspec.yaml`'s
`+build`, or `CURRENT_PROJECT_VERSION` in a pbxproj). Ask; write. `--yes`: keep.

## Step 4 — `tags`: the test-tag file

Explain: on a Compose screen `resource-id` is the `Modifier.testTag`; a file that lists the tags
(`TestTags.kt`, say) lets Claude map an id in a dump back to the composable that drew it. The
skills read `testTagsFile` when it is set.

Show the detected path; ask; write `testTagsFile` (repo-relative). If the app is Compose and
has no root `testTagsAsResourceId = true`, say so — without it every `resource-id` is empty.
`--yes`: keep.

## Step 5 — `output`: capture folder and slug

Show `outputDir` (default `smartScreenShot`, git-ignored by `install.sh`) and `slugMaxLength`
(default 10). Ask; write. If the folder changes, tell the user to update `.gitignore` (the
installer added the old name). `--yes`: unchanged.

## Step 6 — `tools`: what this machine has

No config change. Run and report, one line each:

- `command -v adb` and `adb devices -l` — Android captures need adb and a device with USB
  debugging; a device listed as `unauthorized` needs the on-device prompt accepted.
- `command -v xcrun`, `xcrun simctl list devices booted`, `command -v java`, and the maestro
  binary (`~/.maestro/bin/maestro`, `ios.maestroBin`, or `command -v maestro`) — iOS captures
  need all four; Maestro installs with `curl -Ls https://get.maestro.mobile.dev | bash`.
- `bash .claude/smart-screenshot/bin/py.sh -c 'import sys; print(sys.version)'` — Python 3 by
  whatever name it has here.
- `bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --help` and `--ios --help` —
  both print and exit 0 without touching a device.
- `bash .claude/smart-screenshot/bin/py.sh .claude/skills/smartScreenshot/scripts/selftest_maestro_to_uiautomator.py`
  — the iOS converter's self-test, device-free.

## Step 7 — `summary`

Print the effective config as a short table: Android package(s), iOS bundle id + simulators,
version fallback, test-tag file, output dir, slug length, annotator port — and, per platform,
whether a capture can run on this machine right now (from step 6, when it ran). Then the two
commands to try: `/smartScreenshot --no-annotate` and `/processSmartScreenshot`.
