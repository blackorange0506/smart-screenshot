# iOS captures

`/smartScreenshot --ios` produces the same two artifacts as an Android capture — a PNG and a
uiautomator-shaped XML — from a booted iOS **simulator**, so the annotator,
`/processSmartScreenshot` and every grep recipe work unchanged. macOS only; physical devices are
out of scope.

## What it needs

- Xcode with `xcrun simctl` (`sudo xcode-select -s /Applications/Xcode.app` if `simctl` is
  missing).
- Java on `PATH` (or `JAVA_HOME`), because the Maestro CLI is a JVM program.
- [Maestro](https://maestro.mobile.dev): `curl -Ls https://get.maestro.mobile.dev | bash`. The
  script looks in `ios.maestroBin`, then `~/.maestro/bin/maestro`, then `PATH`.

All three are checked before a simulator is touched, so a missing tool is a one-line refusal.

## Why Maestro

`xcrun simctl` has no accessibility or hierarchy command at all — `simctl io` offers only
`enumerate`, `poll`, `recordVideo` and `screenshot`. Maestro's `hierarchy` command drives the
simulator through a bundled XCTest driver and prints the accessibility tree as JSON;
`maestro_to_uiautomator.py` turns that into the XML shape Android produces.

A **cold run installs the XCTest driver** on the simulator and can take a minute; warm runs take
a few seconds because the capture passes `--no-reinstall-driver` (Maestro's default is to
reinstall on every invocation). If a dump fails or times out (`ios.hierarchyTimeout`, default
90 s), the script retries once *with* a reinstall, which is the cure for a stale driver. Maestro
leaves a per-run folder under `~/.maestro/tests/`; it is harmless.

## Points versus pixels

Maestro reports every element frame in **points** (an iPhone 15 is 393×852) while
`simctl io screenshot` writes **pixels** (1179×2556). The converter multiplies every bound by a
scale it takes from, in order of trust:

1. the root frame measured against the PNG (exact, but a live root often reports `[0,0][0,0]`);
2. the simulator's own `mainScreenScale` from the device type's `profile.plist` (exact, measured
   elsewhere);
3. the union of all node bounds (an estimate — anything scrolled off-screen widens it).

If none is available the conversion **fails** rather than assuming 1.0: bounds silently 3× off
would land every mark on the wrong view and nothing downstream could tell. The scale used is
recorded on the root element so a suspicious correlation can be audited from the artifact:

```xml
<hierarchy rotation="0" platform="ios" scale="3.0000" bundle-id="com.example.app"
           device-name="iPhone 15" device-udid="…" source="maestro hierarchy">
```

## Reading an iOS XML

- **`resource-id`** is the element's accessibility identifier — `Modifier.testTag` on a Compose
  Multiplatform app (nothing to opt into; Compose for iOS exposes it already),
  `.accessibilityIdentifier(...)` on SwiftUI.
- **`class`** is always the constant `XCUIElement`. Maestro discards the element type before
  serializing, so the real type is not recoverable; the constant carries no information.
- **`clickable`, `focusable`, `scrollable`, `long-clickable`, `password` are absent**, not
  `false` — iOS has no equivalent, and an omitted attribute is neither a lie nor a guess.
- `text` falls back to the accessibility label when there is no title or value; `content-desc`
  holds the label only when it differs from `text`, otherwise the placeholder.
- **Bounds are pixels**, exactly as on Android.

A follow-up *action* does not carry over: `adb shell input tap x y` has no simctl equivalent, so
acting on an iOS capture means driving the app by hand or through Maestro.

## Which simulator, which app

`ios.simulators` is a preference list by name; the first one that exists wins, booted or not,
even when another simulator is running — a simulator left booted from last week should not
silently become the device under test. With no configured match: the one booted simulator, else
the newest available iPhone is booted. `SMART_SCREENSHOT_IOS_SIM` pins one by name or udid.

The app is `ios.bundleId` (or `SMART_SCREENSHOT_IOS_BUNDLE_ID`), else the one non-Apple app the
simulator is running. Its installed `CFBundleVersion` goes into the filename; when it is not
installed, the config's `version` fallback, else `0`.

## Trusting the converter

The converter is the one piece that can be wrong invisibly, so it has a self-test with planted
fixtures, a hand-built PNG header and one assertion per failure mode — including a negative
control that fails if the scale is quietly 1.0. It needs no simulator, no Maestro, no network:

```bash
bash .claude/smart-screenshot/bin/py.sh .claude/skills/smartScreenshot/scripts/selftest_maestro_to_uiautomator.py
```
