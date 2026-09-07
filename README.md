# smart-screenshot

Two Claude Code skills that let Claude *read* a mobile screen instead of squinting at a picture:

- **`/smartScreenshot`** captures the current screen of an Android device or an iOS simulator as
  a **paired PNG + XML hierarchy dump** — every visible node with its exact pixel bounds,
  resource-id / test tag, text and content-description — filed under `smartScreenShot/` with a
  date + version + commit-slug filename. It then opens a small local **annotator** where you
  draw points, rectangles and polylines on the screenshot and comment them; each mark is saved
  together with the hierarchy node underneath it.
- **`/processSmartScreenshot`** reads a capture back — newest, or `-N` back — reports what is on
  the screen, lists your marks with the views they landed on, and offers to act on the comments
  that read as change requests.

The XML is the point. Claude can grep it, compute tap coordinates from it, and tie "this button"
to a specific node; the PNG stays for the human and for rendering questions.

```
smartScreenShot_2026-05-07_143022_v186_fix-the-th.png
smartScreenShot_2026-05-07_143022_v186_fix-the-th.xml
smartScreenShot_2026-05-07_143022_v186_fix-the-th.marks.json      (after annotating)
smartScreenShot_ios_2026-05-07_143540_v186_fix-the-th.png         (--ios)
smartScreenShot_ios_2026-05-07_143540_v186_fix-the-th.xml
```

## Requirements

| Needed            | For                | Notes                                                                                   |
|-------------------|--------------------|-----------------------------------------------------------------------------------------|
| bash 3.2+         | everything         | macOS `/bin/bash`, any Linux, or **Git Bash** on Windows (part of Git for Windows)     |
| Python 3          | everything         | under any of its names — `python3`, `python`, or the `py` launcher                      |
| git               | the commit slug    | optional; without it the filename just has no slug                                      |
| `adb`             | Android captures   | Android platform-tools on PATH; a device or emulator with USB debugging enabled          |
| Xcode + `simctl`  | iOS captures       | **macOS only**; simulators only, no physical iPhone                                     |
| Java + [Maestro]  | iOS captures       | `curl -Ls https://get.maestro.mobile.dev \| bash`; Maestro reads the iOS view hierarchy |
| `jq`, `xmllint`   | optional           | used when present; the config reader falls back to Python, the XML check to `grep`      |

[Maestro]: https://maestro.mobile.dev

Android captures work on macOS, Linux and Windows. iOS captures need macOS — the other two
platforms refuse `--ios` with a clear message.

## Install

macOS and Linux:

```bash
git clone https://github.com/blackorange0506/smart-screenshot ~/src/smart-screenshot
cd ~/your/project
bash ~/src/smart-screenshot/install.sh
```

Windows — the same commands from **Git Bash**, the shell Claude Code itself uses there (WSL
works too and is plain Linux):

```bash
git clone https://github.com/blackorange0506/smart-screenshot /c/src/smart-screenshot
cd /c/your/project
bash /c/src/smart-screenshot/install.sh
```

The installer copies the package into `.claude/` (two skills, a setup skill, the shared
libraries), git-ignores the capture folder, pins the scripts to LF in `.gitattributes`, and
writes `.claude/smart-screenshot/config.json` — pre-filled with what it can detect in the repo:
the Android `applicationId` (with flavour and build-type suffixes), the iOS bundle id, where the
build number lives, and a `TestTags.kt` if there is one. Re-running upgrades the package files
and leaves your config and captures alone.

| Flag           | Effect                                                                     |
|----------------|----------------------------------------------------------------------------|
| `--target DIR` | install into `DIR` instead of the current directory                        |
| `--no-detect`  | write the config with empty values instead of detecting                    |
| `--dry-run`    | print what would change (and what would be detected), write nothing        |
| `--force`      | reset `config.json` from the example (the old one is kept as `config.json.bak`) |

If Claude Code is already open in the project, restart it: a new `.claude/skills/` directory is
only seen from the next session. Then, optionally, run `/smartScreenshotSetup` — it walks
through the config values, checks the tools on the machine, and runs the device-free self-tests.

`bash ~/src/smart-screenshot/uninstall.sh` removes everything the installer added, keeps your
captures (and, with `--keep-config`, the config).

## Use

Connect a device (or boot a simulator), open the screen you want Claude to see, and:

```
/smartScreenshot                  Android: capture, then open the annotator
/smartScreenshot --no-annotate    capture only — what Claude runs when you just ask "what's on the screen?"
/smartScreenshot --with-bounds    also a PNG with Show Layout Bounds on (Android)
/smartScreenshot --with-taps      also a PNG with Show Taps on (Android)
/smartScreenshot --ios            the booted (or configured) iOS simulator
/processSmartScreenshot           read the newest capture and its marks
/processSmartScreenshot -1        the one before
```

Under the hood the skills run two scripts you can also call yourself:

```bash
bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --no-annotate | tail -1   # prints the XML path last
bash .claude/skills/processSmartScreenshot/scripts/select_smartScreenshot.sh -1          # KEY=path lines
```

### The annotator

After a capture the script starts a loopback-only Python server on a random port, opens
`annotator.html` in your browser, and waits. Click for a **point**, drag for a **rectangle**,
click vertices and double-click for a **polyline**; type a comment per mark; `⌘/Ctrl+S` saves
`<stem>.marks.json` next to the PNG. The PNG is never modified. Every mark stores the deepest
hierarchy node whose bounds contain it, so `/processSmartScreenshot` — and Claude — can say
*which view* you meant, not just where you clicked. Ctrl+C in the terminal stops the server.

### What the XML gives Claude

Each `<node>` carries `bounds="[x1,y1][x2,y2]"`, `resource-id`, `text`, `content-desc`, `class`
and the boolean flags uiautomator reports. On a Jetpack Compose / Compose Multiplatform app,
`resource-id` is the `Modifier.testTag` (provided the app sets `testTagsAsResourceId = true` at
its root); point `testTagsFile` in the config at the file that lists the tags and Claude maps an
id back to the composable. On iOS the same XML shape is produced from Maestro's hierarchy, with
bounds rescaled from points to pixels and the scale recorded on the root element — see
[docs/ios.md](docs/ios.md).

## Configure

`.claude/smart-screenshot/config.json`, all keys optional; environment variables override per
run. [docs/configuration.md](docs/configuration.md) has every key and every variable.

```json
{
  "outputDir": "smartScreenShot",
  "slugMaxLength": 10,
  "android": { "package": "", "packages": [], "deviceSerial": "", "deviceHost": "" },
  "ios": { "bundleId": "", "simulators": ["iPhone 16", "iPhone 15"], "maestroBin": "", "hierarchyTimeout": 90 },
  "version": { "file": "", "regex": "" },
  "testTagsFile": "",
  "annotator": { "port": 0 }
}
```

The one value worth setting by hand is the app: `android.package` (or the `android.packages`
priority list for flavours) and `ios.bundleId`. Without them the capture uses the foreground app,
which is right until a dialog from another app is up. `version.file` + `version.regex` name where
the build number lives in the repo, for captures taken when the app is not installed.

## Windows notes

- Run everything from **Git Bash**. Claude Code on Windows hands its Bash tool to Git Bash, so a
  skill that works in your terminal works in Claude.
- `adb` is the same platform-tools binary; `adb devices` must list the device as `device`, not
  `unauthorized`.
- The annotator opens through Python's `webbrowser` module (the default browser); the server
  binds `127.0.0.1` only, so the first run may show a firewall prompt you can decline.
- `--ios` is refused: there is no `simctl` outside macOS.

## Develop

```bash
bash tests/run.sh                 # every tests/*.test.sh — device-free, a fake adb stands in
/bin/bash tests/run.sh            # the same under macOS's bash 3.2
bash scripts/lint.sh              # shellcheck + py_compile
bash scripts/check_banlist.sh     # no trace of the project this was extracted from
```

The banlist has a tracked, non-identifying half (`scripts/banlist.txt`) and an optional
git-ignored one (`scripts/banlist.local.txt`) that the checker also reads; CI runs the tracked half.

CI runs the suite on Ubuntu, macOS (both bashes) and Windows (Git Bash), then installs into a
fresh repo and captures through the fake adb on each.

## License

MIT — see [LICENSE](LICENSE).
