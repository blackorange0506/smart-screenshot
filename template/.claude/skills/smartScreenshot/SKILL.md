---
name: smartScreenshot
description: "Capture the current app screen as BOTH a PNG screenshot and an XML hierarchy dump — Android by default, an iOS simulator with --ios — archived under the capture folder (default smartScreenShot/) with a date+version+commit-slug filename. The XML is what Claude reads to reason about the screen (exact bounds, resource-ids, text, content-desc, flags); the PNG keeps the visual. Use this whenever the user wants Claude to look at the current screen — phrases like 'smart screenshot', '/smartScreenshot', 'capture the screen', 'screenshot and ui dump', 'dump the ui', 'screenshot with hierarchy', 'show me what's on the screen', 'capture screen + layout', 'smart screenshot on ios', 'capture the ios screen with hierarchy', 'dump the ios ui hierarchy'. Trigger eagerly — this is the canonical entry point for textual + visual screen capture."
argument-hint: "[--ios] [--with-bounds] [--with-taps] [--annotate] [--no-annotate]"
allowed-tools: Read, Glob, Grep, Bash(bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh:*), Bash(bash .claude/smart-screenshot/bin/py.sh:*), Bash(grep:*), Bash(head:*), Bash(tail:*), Bash(ls:*), Bash(cat .claude/smart-screenshot/config.json)
---

# /smartScreenshot

Capture the **current screen** as a **paired snapshot**:

- a **PNG screenshot** — preserves the visual rendering,
- an **XML hierarchy dump** — exact bounds, class, resource-id, text, and content-description for every visible node, machine-parseable and grep-friendly.

Both files share one stem and land in the capture folder (`outputDir` in `.claude/smart-screenshot/config.json`, default `smartScreenShot/` at the project root).

**Android is the default**; `--ios` captures an iOS simulator instead (macOS only) and produces the same two artifacts under an `_ios`-infixed stem. See [Platforms](#platforms---android-default---ios) for what differs.

## Why both formats

The XML is what Claude actually reads to reason about layout — pixel-exact bounds, every resource-id, every text/content-desc, plus `clickable`/`focusable`/`scrollable`/`enabled` flags per node. The PNG is for the human (and for the rare case where rendering quirks matter — overlapping content, custom drawing). When in doubt, prefer this skill over a plain screenshot so Claude has structured context.

## How to invoke

Always from the project root, with the full path:

```bash
bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --no-annotate           # Android; capture only
bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh                         # Android; capture + open the annotator
bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --with-bounds --no-annotate   # + bounds variant       (Android only)
bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --annotate              # + bounds variant; annotate the bounds PNG (Android only)
bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --with-taps --no-annotate     # + taps variant         (Android only)

bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --ios --no-annotate     # iOS simulator; capture only
bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --ios                   # iOS; capture + annotator
```

`--android` is the default and rarely needs typing. Both platform flags take no value and the **last one wins**, so `--ios --android` is Android.

**Which form Claude runs.** The annotator is a local web page the *user* draws on; it blocks the script until the user is done. So:

- When the user just wants Claude to look at the screen (the common case), pass **`--no-annotate`** and read the XML afterwards.
- When the user wants to mark things up ("let me annotate", "I'll show you where"), run the script **without** `--no-annotate` **in the background** (the Bash tool's `run_in_background`), tell the user the annotator URL from the log, and wait for them to say they are done. Then run `/processSmartScreenshot` (or read `<stem>.marks.json` directly). The server stops when the background job is stopped.

The script prints log lines to stderr and the produced paths to stdout in capture order:

- standard PNG path (always)
- bounds PNG path (only with `--with-bounds`)
- taps PNG path (only with `--with-taps`)
- **last line: XML path** (the primary artifact for downstream tooling — `tail -1` always works)

```bash
XML_PATH=$(bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --no-annotate | tail -1)
```

## What Claude does after a capture

1. Read the XML (the last stdout line) with the Read tool. Identify the screen from the `resource-id`s, then the visible `text` / `content-desc`, then `bounds`.
2. If `.claude/smart-screenshot/config.json` names a `testTagsFile`, read it: it is the vocabulary that maps a `resource-id` back to the composable / view that drew it.
3. Answer the user's question about the screen, quoting node ids and bounds where they matter. Look at the PNG only when rendering itself is in question (overlaps, custom drawing, colours).

## Filename convention

```
smartScreenShot_<YYYY-MM-DD>_<HHMMSS>_v<versionCode>_<commit-slug>.png         (always)
smartScreenShot_<YYYY-MM-DD>_<HHMMSS>_v<versionCode>_<commit-slug>.bounds.png  (--with-bounds)
smartScreenShot_<YYYY-MM-DD>_<HHMMSS>_v<versionCode>_<commit-slug>.taps.png    (--with-taps)
smartScreenShot_<YYYY-MM-DD>_<HHMMSS>_v<versionCode>_<commit-slug>.xml         (always)

smartScreenShot_ios_<YYYY-MM-DD>_<HHMMSS>_v<CFBundleVersion>_<commit-slug>.png (--ios)
smartScreenShot_ios_<YYYY-MM-DD>_<HHMMSS>_v<CFBundleVersion>_<commit-slug>.xml (--ios)
```

- **Date / time** — local date + `HHMMSS`, so multiple captures in a day sort and never collide.
- **Version** — the installed app's `versionCode` (Android, from `dumpsys package`) or `CFBundleVersion` (iOS, from the installed bundle's `Info.plist`). Which app: `android.package` / `ios.bundleId` in the config, else the first installed entry of `android.packages`, else the app in the foreground (Android) or the one third-party app the simulator is running (iOS). When the app is not installed, `version.file` + `version.regex` in the config name where the number lives in the repo (`gradle.properties`, say); with no fallback the version is `0` and the capture still succeeds.
- **The `_ios` infix** — both platforms file into one folder, and `/processSmartScreenshot` orders captures purely by mtime without ever parsing the name. Without the infix, "the latest capture" would be a coin flip between platforms.
- **Commit slug** — last commit subject with a leading ticket reference (`ABC-123`, `[ABC-123]`, `#123`) stripped, slugified, capped at `slugMaxLength` characters (default 10). Omitted when there is no git or no commit.
- **Collision safety** — the suffix `_2`/`_3`/… is checked against **all four** possible artifact paths together so variants never split (you can't end up with a `_2.png` next to a non-`_2.bounds.png`).

Example: `smartScreenShot_2026-05-07_143022_v186_fix-the-th.png` + `.bounds.png` + `.xml`.

## Overlays (`--with-bounds`, `--with-taps`)

Each overlay flag adds **one extra PNG alongside the standard one** — the standard capture is never replaced. All variants share a single stem; the XML is captured once and is unaffected by overlays (`uiautomator dump` reads the view tree from the OS, not pixels).

| Invocation                            | Files produced                                                       |
|---------------------------------------|----------------------------------------------------------------------|
| (no overlay flag)                     | `<stem>.png`, `<stem>.xml`                                           |
| `--with-bounds`                       | `<stem>.png`, `<stem>.bounds.png`, `<stem>.xml`                      |
| `--with-taps`                         | `<stem>.png`, `<stem>.taps.png`, `<stem>.xml`                        |
| `--with-bounds --with-taps`           | `<stem>.png`, `<stem>.bounds.png`, `<stem>.taps.png`, `<stem>.xml`   |

- **`--with-bounds`** — enables Developer Options' "Show layout bounds" (`setprop debug.layout true` + the activity-service redraw), sleeps ~400 ms, captures `<stem>.bounds.png`, then restores the prior state.
- **`--with-taps`** — enables "Show taps", captures `<stem>.taps.png`, restores the prior state. **Caveat:** tap circles only render *while a finger is touching the screen*. The taps PNG will look like the standard one unless you're touching during capture (~½ s after the script logs `Capturing taps…`). For reliable tap visualization, prefer `adb shell screenrecord` instead.
- **State restoration** runs in a single `cleanup` trap, so prior device state (`debug.layout`, `show_touches`) is restored even if the script is interrupted or a capture fails.

## Platforms (`--android` default, `--ios`)

|                | `--android`                          | `--ios`                                          |
|----------------|--------------------------------------|--------------------------------------------------|
| runs on        | macOS, Linux, Windows (Git Bash)     | macOS only                                       |
| screenshot     | `adb exec-out screencap -p`          | `xcrun simctl io <udid> screenshot`               |
| hierarchy      | `adb shell uiautomator dump`         | `maestro hierarchy` → `maestro_to_uiautomator.py` |
| device chosen  | adb-lib's `select_device`            | ios-lib's `select_simulator` (boots it if needed) |
| stem           | `smartScreenShot_…`                  | `smartScreenShot_ios_…`                           |
| overlays       | `--with-bounds`, `--with-taps`       | **hard error** — no iOS equivalent exists         |
| annotator      | same                                 | same, on the standard PNG                         |

`--ios` `exec`s `ios_smartScreenshot.sh`, a separate script because none of it is adb and the Android cleanup trap has nothing to restore there.

**Why Maestro.** `xcrun simctl` has no accessibility or hierarchy command at all — `io` offers only `enumerate`, `poll`, `recordVideo`, `screenshot`. Maestro drives the simulator through a bundled XCTest driver. A **cold run installs that driver and can take a minute**; warm runs are a few seconds, because the capture passes `--no-reinstall-driver` (Maestro's default is to reinstall on *every* invocation). If a dump fails or times out, the script retries once *with* a reinstall, which is the cure for a stale driver. Maestro also leaves a per-run folder under `~/.maestro/tests/` — harmless.

**Bounds are rescaled, and the XML says by how much.** Maestro reports every XCUIElement frame in **points** (iPhone 15: 393×852) while the screenshot is in **pixels** (1179×2556). The converter multiplies by a scale it takes from, in order: the root frame measured against the PNG; the simulator's own `mainScreenScale`; the union of all node bounds. If none is available the conversion **fails** rather than assuming 1.0, because bounds silently 3× off would be undetectable downstream. The scale used is recorded on the root element:

```xml
<hierarchy rotation="0" platform="ios" scale="3.0000" bundle-id="com.example.app"
           device-name="iPhone 15" device-udid="…" source="maestro hierarchy">
```

**Reading an iOS XML** — the differences from an Android one:

- **`resource-id` is the element's accessibility identifier.** For a Compose Multiplatform app that is `Modifier.testTag`, exactly as on Android; for SwiftUI it is `.accessibilityIdentifier(...)`.
- **`class` is always the constant `XCUIElement`.** Maestro discards `elementType` before serializing, so the real type is not recoverable; the constant carries no information.
- **`clickable`, `focusable`, `scrollable`, `long-clickable`, `password` are absent**, not `false`. iOS has no equivalent for them. An omitted attribute is neither a lie nor a guess.
- `text` falls back to the accessibility label when there is no title/value, and `content-desc` holds the label only when it differs from `text` (otherwise the placeholder).
- **Bounds are pixels on both platforms**, so the annotator, grep recipes and mark correlation work identically.

The grep recipes at the bottom of this file work on both. A *follow-up* action does not: `adb shell input tap <x> <y>` has no simctl equivalent.

## What the XML looks like on a Compose UI

If the app is Jetpack Compose / Compose Multiplatform rather than Android XML layouts:

- **`resource-id` is a test tag, not an Android resource** — provided the app sets `Modifier.semantics { testTagsAsResourceId = true }` at its root. Any node carrying `Modifier.testTag("x")` then reports `resource-id="x"`, with no package prefix. Point `testTagsFile` in the config at the file that lists the tags, and read it to map a dumped id back to the composable.
- **Untagged nodes have an empty `resource-id`.** Fall back to `text`, `content-desc`, and `bounds`.
- **`class` is uninformative.** Most nodes come back as `android.view.View`; the whole screen often sits under a single `ComposeView`. Don't infer widget type from `class`.
- **The tree is shallower than the composable tree.** uiautomator sees the merged semantics tree, so a Row of icon + label may collapse into one node whose `text` is the concatenation. `Modifier.clickable` merges its descendants, which is why tags sit on the clickable node rather than its label.

If a node you need has no `resource-id`, the fix is a one-line app change: a `Modifier.testTag(...)` at the call site. Say so rather than guessing at bounds.

## Annotating

The annotator is **on by default**. After a successful capture, the script starts a tiny local Python server (loopback only, random free port unless `SMART_SCREENSHOT_PORT` / `annotator.port` is set), opens the annotator in the default browser, and waits. Annotations save as a sidecar JSON next to the chosen PNG — the **PNG is never modified**. Ctrl+C in the terminal (or stopping the background job) shuts the server down.

| Flag                  | Annotation target  | Sidecar saved to              |
|-----------------------|--------------------|-------------------------------|
| (default)             | `<stem>.png`       | `<stem>.marks.json`           |
| `--annotate`          | `<stem>.bounds.png` (implies `--with-bounds`) | `<stem>.bounds.marks.json` |
| `--no-annotate`       | — (skipped)        | —                             |

The two sidecars can coexist for one capture, so the same screen can be annotated once on the clean PNG and once on the bounds PNG without overwriting either.

### What the annotator can do

Three mark types, each with a free-text **comment**:

| Tool       | How                             | Geometry                          |
|------------|---------------------------------|-----------------------------------|
| **Point**  | click once on the image         | `{x, y}`                          |
| **Rect**   | click + drag                    | `{x, y, w, h}`                    |
| **Polyline** | click each vertex; double-click last (or click "✓ Finish polyline") | `{points: [[x,y], …]}` |

`⌘/Ctrl+S` saves. Marks auto-save to `localStorage` while you work, so a refresh won't lose them.

### View correlation — the part that matters for Claude

Every mark **also stores the matching hierarchy node**, so when Claude reads the dump together with the marks file, "this region" is always tied to a specific view, not just pixels. The annotator picks the **deepest** node whose bounds contain the mark (centroid for rects/polylines), and embeds:

```json
"view": {
  "resource_id": "com.example.app:id/btn_save",
  "class": "android.widget.Button",
  "text": "Save",
  "content_desc": "",
  "bounds": [100, 1150, 800, 1250]
}
```

If no node contains the point (rare — e.g. the user marked outside the view tree), `view` is `null`.

### Sidecar JSON format (`<stem>.marks.json`)

```json
{
  "image": "smartScreenShot_2026-05-07_192033_v187_Add-format.png",
  "image_size": {"w": 1080, "h": 2400},
  "marks": [
    {
      "id": 1,
      "type": "point",
      "geometry": {"x": 540, "y": 1200},
      "comment": "tap target after step 3",
      "view": {
        "resource_id": "com.example.app:id/btn_save",
        "class": "android.widget.Button",
        "text": "Save",
        "content_desc": "",
        "bounds": [100, 1150, 800, 1250]
      }
    },
    {
      "id": 2,
      "type": "rect",
      "geometry": {"x": 100, "y": 200, "w": 880, "h": 120},
      "comment": "header — text overflows on long titles",
      "view": { "resource_id": "…:id/title_bar", "class": "…", "text": "…", "bounds": [80, 180, 1000, 340] }
    },
    {
      "id": 3,
      "type": "polyline",
      "geometry": {"points": [[100,100],[200,200],[300,150]]},
      "comment": "expected scroll path",
      "view": null
    }
  ]
}
```

Pretty-printed, stable key ordering, one mark per JSON object — easy to diff and grep.

### Why a local server (not a static HTML file)

The annotator needs to `fetch()` the `<stem>.xml` to compute view correlation, and to `POST` the saved JSON straight into the capture folder. Both are blocked under `file://` by browser CORS / sandboxing. The server is loopback-only (`127.0.0.1`), serves only the capture folder + the skill's `annotator.html`, validates `?path=` against traversal, and exits on Ctrl+C.

## Settings and environment overrides

Project settings live in `.claude/smart-screenshot/config.json` (`/smartScreenshotSetup` walks through them; `install.sh` pre-fills what it can detect). Environment variables override the config for one run:

Android only:

- `SMART_SCREENSHOT_PACKAGE` — the app whose versionCode names the capture (config `android.package` / `android.packages`).
- `SMART_SCREENSHOT_DEVICE_SERIAL` (or adb's own `ANDROID_SERIAL`) — pick a device when multiple are connected (config `android.deviceSerial`).
- `SMART_SCREENSHOT_DEVICE_HOST` — `host:port` for wireless adb, used during recovery if no device is visible (config `android.deviceHost`).

iOS only:

- `SMART_SCREENSHOT_IOS_SIM` — a simulator by name or udid; booted if shut down (config `ios.simulators`, a preference list).
- `SMART_SCREENSHOT_IOS_BUNDLE_ID` — the app's bundle id (config `ios.bundleId`).
- `MAESTRO_BIN` — path to the maestro CLI (config `ios.maestroBin`; default `~/.maestro/bin/maestro`, then `PATH`).
- `SMART_SCREENSHOT_IOS_TIMEOUT` — seconds allowed for the first hierarchy dump (config `ios.hierarchyTimeout`, default 90; the reinstall retry gets double).

Both:

- `SMART_SCREENSHOT_DIR` — output directory (config `outputDir`, default `<project>/smartScreenShot`).
- `SMART_SCREENSHOT_PREFIX` — filename stem prefix (default `smartScreenShot`, or `smartScreenShot_ios` under `--ios`).
- `SMART_SCREENSHOT_PORT` — preferred annotator port (config `annotator.port`; default random free).

## Edge cases

- **uiautomator fails on some surfaces** (Android Auto, certain TV launchers, secure-flag protected windows): the PNG is still saved, the XML is missing, and the script exits non-zero with a clear error so the caller knows which half is missing. `--ios` behaves identically when Maestro fails — the XML is deleted rather than left half-written, since `/processSmartScreenshot` treats any `<stem>.xml` as a valid capture.
- **No git / no commits**: slug is omitted; filename becomes `smartScreenShot_<date>_<time>_v<vc>.{png,xml}`.
- **App not installed / not identified**: the version comes from the config fallback, else `0`; the capture still succeeds and a log line says so.
- **Locked / off screen**: `screencap` returns a black PNG and `uiautomator dump` returns a tiny tree; the capture succeeds but reflects what the device is actually showing — wake the device first.
- **Several devices, no terminal**: the script lists the serials and asks for `SMART_SCREENSHOT_DEVICE_SERIAL`; on a terminal it offers a numbered chooser.
- **iOS on Linux or Windows**: refused up front with a clear message; only `--android` is available there.
- **iOS, no simulator booted**: `select_simulator` boots the configured (or newest) iPhone rather than failing.
- **iOS, maestro or java missing**: refused up front with an install hint, before any simulator is touched. Same for `--with-bounds`/`--with-taps`/`--annotate`, so a rejected flag never leaves a simulator booted behind it.
- **A real iOS device is out of scope** — simulators only.

## Reading the XML in follow-up turns

Each `<node>` has `bounds="[x1,y1][x2,y2]"`, `resource-id`, `text`, `content-desc`, `class`, and a handful of boolean flags. Greppable patterns:

```bash
# Find a node by text
grep -oE '<node[^>]*text="Submit"[^>]*/?>' smartScreenShot/<file>.xml

# List every resource-id present
grep -oE 'resource-id="[^"]+"' smartScreenShot/<file>.xml | sort -u
```

Both recipes work on an iOS capture too — bounds are pixels on both platforms. Bounds give exact tap coordinates if the user wants Claude to drive a follow-up `adb shell input tap` on Android.

## Trusting the iOS conversion

The Maestro→XML converter is the one piece of this skill that can be wrong invisibly: if the point→pixel scale were off, every mark would simply land on the wrong view, plausibly, forever. So it has a self-test — planted fixtures, a hand-built PNG header, and an assertion per failure mode, including a negative control that fails if the scale is quietly 1.0.

```bash
bash .claude/smart-screenshot/bin/py.sh .claude/skills/smartScreenshot/scripts/selftest_maestro_to_uiautomator.py
```

It needs no simulator, no Maestro and no network.
