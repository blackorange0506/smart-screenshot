---
name: processSmartScreenshot
description: "Pick a smartScreenshot capture from the capture folder (newest by default, optional negative offset to walk back through history) and PROCESS it — read the XML hierarchy to understand what's on screen, read any marks.json sidecar to see what the user annotated, correlate every mark to its target view, and report findings (and stand ready to action any change-request comments after confirming with the user). Use this whenever the user wants Claude to look at, analyze, summarise, or act on a captured smartScreenshot — phrases like '/processSmartScreenshot', 'process smartscreenshot', 'process the screenshot', 'analyze the smart screenshot', 'what did I mark on the screenshot', 'review my annotations', 'what's on the captured screen', 'look at the previous capture'. Supports a relative offset to walk back through history: 0 (or omitted) = newest, -1 = previous, -2 = the one before that, -N = N back. Trigger eagerly — this is the canonical entry point for reviewing already-captured smartScreenshots."
argument-hint: "[-N]"
allowed-tools: Read, Glob, Grep, Bash(bash .claude/skills/processSmartScreenshot/scripts/select_smartScreenshot.sh:*), Bash(cat .claude/smart-screenshot/config.json), Bash(grep:*), Bash(ls:*)
---

# /processSmartScreenshot

Pick a captured smartScreenshot (newest by default, or `-N` back) and **process** it: understand the screen from the XML hierarchy, surface what the user marked in the annotator, and correlate every mark to its on-screen view so any next step (a code change, a question, a follow-up capture) is grounded in a specific node — not just a pixel.

This is the **read** counterpart to `/smartScreenshot` (which captures). It does not capture, it does not modify the PNG, and it does not launch the annotator.

## How to invoke

From the project root:

```bash
bash .claude/skills/processSmartScreenshot/scripts/select_smartScreenshot.sh         # newest capture
bash .claude/skills/processSmartScreenshot/scripts/select_smartScreenshot.sh -1      # previous capture
bash .claude/skills/processSmartScreenshot/scripts/select_smartScreenshot.sh -3      # three captures back
```

The script prints labelled paths on stdout, one per existing artifact. Lines for absent artifacts are omitted.

```
STEM=smartScreenShot_2026-05-07_192033_v187_Add-format
XML=<dir>/<stem>.xml
PNG=<dir>/<stem>.png
BOUNDS_PNG=<dir>/<stem>.bounds.png          (only if --with-bounds was used at capture)
TAPS_PNG=<dir>/<stem>.taps.png              (only if --with-taps was used at capture)
MARKS=<dir>/<stem>.marks.json               (only if the user annotated the standard PNG)
BOUNDS_MARKS=<dir>/<stem>.bounds.marks.json (only if the user annotated the bounds PNG)
```

## What Claude does after running the script

1. **Run the selector** with the user's offset (or no arg for newest). Read the printed `KEY=path` lines.
2. **Read the XML** (`XML=…`) to identify the screen. `resource-id` names the node — for a Compose app it is the test tag (no package prefix), for a classic Android app `<package>:id/<name>`. If `.claude/smart-screenshot/config.json` names a `testTagsFile`, read it: it maps a tag back to the composable or view that drew it. For untagged nodes fall back to visible `text` / `content-desc` and `bounds`. `class` is rarely informative on a Compose screen (`android.view.View` throughout).

   **The capture may be from iOS** — `STEM` starts `smartScreenShot_ios_` and the root element carries `platform="ios"`. Everything above still holds, `resource-id` included (it is the accessibility identifier — the Compose test tag on a Compose Multiplatform app). Three differences: `class` is the synthetic constant `XCUIElement` and carries no information (Maestro discards the real element type); `clickable`/`focusable`/`scrollable` are **absent** rather than `false`; and there is no `adb shell input tap` to follow up with. Bounds are pixels on both platforms, so mark correlation is unaffected.
3. **If `MARKS=…` is present, read it.** Each mark has:
   - `geometry` — pixel coordinates,
   - `comment` — the user's note (this is *the user's intent*, treat it as a request or question),
   - `view` — the hierarchy node already correlated by the annotator (resource_id, class, text, content_desc, bounds). Trust this, don't re-derive it.
4. **If `BOUNDS_MARKS=…` is present, read it too.** Same shape; refers to the bounds-overlay PNG (e.g. spacing/padding observations).
5. **Report**:
   - One-line screen identity ("Settings screen — `settingsScreen_root`").
   - For each mark: `#<id> <type> @ <coords> on <view summary>` — followed by the comment verbatim.
   - For each comment that looks **actionable** (a change request, e.g. "make it green", "move this", "shrink padding"), trace it to the relevant code in the repo — via the node's id / test tag where it has one, otherwise via its visible string (resource files or a literal in the UI code) → the enclosing composable / view. Summarise the smallest change, and **ask the user before editing**.
   - For comments that look like **questions or observations**, answer them directly using the XML/PNG context without editing anything.
6. **Don't launch the annotator.** This skill is for reading. Re-annotating an old capture is out of scope — if the user wants that, they can run `/smartScreenshot` to take a fresh capture.

## When there are no marks

If `MARKS=` and `BOUNDS_MARKS=` are both absent, just summarise what's on the screen from the XML so the user can decide what to do next. Don't invent annotations.

## Environment overrides

- `SMART_SCREENSHOT_DIR` — capture directory (config `outputDir`, default `<project>/smartScreenShot`).

## Exit codes (selector script)

- `0` — success; paths printed on stdout.
- `1` — no captures, missing folder, or offset out of range (lists how many captures exist).
- `2` — bad argument (e.g. non-integer offset).

## Edge cases

- **No `marks.json`** — the user took the capture but didn't annotate. Process the XML and PNG only.
- **`view: null` on a mark** — the user marked outside the view tree (rare). Treat as a free-floating note tied to a pixel coordinate; the comment is still meaningful.
- **Multiple captures within one second** — collision suffix (`_2`, `_3`) on the stem; the selector still picks them by mtime, so `-1` is "the one captured immediately before the newest".
- **Capture exists but its XML failed** — there's no `.xml` in the folder, so this skill can't process it. The user can re-capture.

## Example

```
$ bash .claude/skills/processSmartScreenshot/scripts/select_smartScreenshot.sh -1
STEM=smartScreenShot_2026-05-07_195713_v187_Add-format
XML=/work/app/smartScreenShot/smartScreenShot_2026-05-07_195713_v187_Add-format.xml
PNG=/work/app/smartScreenShot/smartScreenShot_2026-05-07_195713_v187_Add-format.png
MARKS=/work/app/smartScreenShot/smartScreenShot_2026-05-07_195713_v187_Add-format.marks.json
```

Claude then reads the XML and the `.marks.json`, reports the screen identity and the marks, and offers to action any change-request comments.
