#!/usr/bin/env bash
# install.sh / uninstall.sh: dry run, fresh install, idempotent re-install, detection into
# config.json, .gitignore / .gitattributes lines, uninstall leaves captures and config (opt).
. "$(dirname "${BASH_SOURCE[0]//\\//}")/lib.sh"
P="$(new_tmp install)"
git -C "$P" init -q
mkdir -p "$P/app"; printf 'android { defaultConfig { applicationId = "com.inst.app"\n versionCode = 3 } }\n' > "$P/app/build.gradle.kts"
printf '# existing\n' > "$P/.gitignore"

out="$(bash "$ROOT/install.sh" --target "$P" --dry-run 2>&1)"; rc=$?
assert_eq "dry-run exits 0" 0 "$rc"
assert_contains "dry-run lists adds" "$out" "add    .claude/skills/smartScreenshot/SKILL.md"
assert_contains "dry-run shows detection" "$out" "android.package:  com.inst.app"
assert_no_file "dry-run writes nothing" "$P/.claude"
assert_eq "dry-run leaves .gitignore" "# existing" "$(cat "$P/.gitignore")"

out="$(CLAUDECODE='' bash "$ROOT/install.sh" --target "$P" 2>&1)"; rc=$?
assert_eq "install exits 0" 0 "$rc"
assert_file "skill copied" "$P/.claude/skills/smartScreenshot/SKILL.md"
assert_file "process skill copied" "$P/.claude/skills/processSmartScreenshot/scripts/select_smartScreenshot.sh"
assert_file "setup skill copied" "$P/.claude/skills/smartScreenshotSetup/SKILL.md"
assert_file "lib copied" "$P/.claude/smart-screenshot/lib/adb-lib.sh"
assert_file "annotator copied" "$P/.claude/skills/smartScreenshot/annotator.html"
assert_file "VERSION stamped" "$P/.claude/smart-screenshot/VERSION"
assert_eq "VERSION matches" "$(cat "$ROOT/VERSION")" "$(cat "$P/.claude/smart-screenshot/VERSION")"
assert_file "MANIFEST written" "$P/.claude/smart-screenshot/MANIFEST"
assert_eq "MANIFEST covers every template file" "$(cd "$ROOT/template" && find . -type f -not -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort)" "$(cat "$P/.claude/smart-screenshot/MANIFEST")"
assert_contains "config detected" "$(cat "$P/.claude/smart-screenshot/config.json")" '"package": "com.inst.app"'
assert_contains "config keeps the example keys" "$(cat "$P/.claude/smart-screenshot/config.json")" '"simulators"'
assert_contains ".gitignore has the folder, anchored" "$(cat "$P/.gitignore")" "/smartScreenShot/"
assert_eq ".gitignore existing line kept" "# existing" "$(head -1 "$P/.gitignore")"
assert_contains ".gitattributes" "$(cat "$P/.gitattributes")" ".claude/smart-screenshot/** text eol=lf"
assert_contains "install summary" "$out" "/smartScreenshot  /processSmartScreenshot  /smartScreenshotSetup"
assert_contains "restart advice" "$out" "restart it first"
Q="$(new_tmp install-inside)"
out="$(CLAUDECODE=1 bash "$ROOT/install.sh" --target "$Q" --no-detect 2>&1)"
assert_contains "inside Claude Code: exit-and-restart advice" "$out" "exit Claude Code, start it again"
out="$(CLAUDECODE=1 bash "$ROOT/install.sh" --target "$Q" --no-detect 2>&1)"
assert_contains "inside Claude Code, skills dir existed: plain advice" "$out" "or /smartScreenshot directly"
if ! is_windows; then
  [ -x "$P/.claude/skills/smartScreenshot/scripts/smartScreenshot.sh" ] && pass "scripts executable" || fail "scripts executable"
fi

# the installed copy works from the project root
out="$(cd "$P" && bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh --help | head -1)"
assert_eq "installed skill runs" "Usage: smartScreenshot.sh [-h | --help]" "$out"

# idempotent: user edits survive, package files refresh
printf '{ "outputDir": "myShots", "android": { "package": "mine" } }\n' > "$P/.claude/smart-screenshot/config.json"
printf 'garbage\n' > "$P/.claude/smart-screenshot/lib/adb-lib.sh"
out="$(bash "$ROOT/install.sh" --target "$P" 2>&1)"; rc=$?
assert_eq "re-install exits 0" 0 "$rc"
assert_contains "re-install keeps the user's package" "$(cat "$P/.claude/smart-screenshot/config.json")" '"package": "mine"'
assert_eq "re-install refreshes package files" "$(cat "$ROOT/template/.claude/smart-screenshot/lib/adb-lib.sh")" "$(cat "$P/.claude/smart-screenshot/lib/adb-lib.sh")"
assert_contains "re-install ignores the configured folder" "$(cat "$P/.gitignore")" "/myShots/"
assert_eq "gitattributes lines not duplicated" 1 "$(grep -c 'smart-screenshot/\*\* text' "$P/.gitattributes")"
out="$(bash "$ROOT/install.sh" --target "$P" --force 2>&1)"
assert_file "--force keeps a backup" "$P/.claude/smart-screenshot/config.json.bak"
assert_contains "--force resets then re-detects" "$(cat "$P/.claude/smart-screenshot/config.json")" '"package": "com.inst.app"'

# bad arguments / bad target
out="$(bash "$ROOT/install.sh" --target "$P" --nope 2>&1)"; rc=$?
assert_eq "unknown flag exits 1" 1 "$rc"
out="$(bash "$ROOT/install.sh" --target "$ROOT" 2>&1)"; rc=$?
assert_eq "installing into the checkout is refused" 1 "$rc"

# uninstall: captures stay, config goes unless --keep-config, dirs removed
mkdir -p "$P/smartScreenShot"; : > "$P/smartScreenShot/keep.xml"
out="$(bash "$ROOT/uninstall.sh" --target "$P" --dry-run 2>&1)"
assert_contains "uninstall dry-run" "$out" "rm .claude/skills/smartScreenshot/SKILL.md"
assert_file "uninstall dry-run writes nothing" "$P/.claude/skills/smartScreenshot/SKILL.md"
out="$(bash "$ROOT/uninstall.sh" --target "$P" --keep-config 2>&1)"; rc=$?
assert_eq "uninstall exits 0" 0 "$rc"
assert_file "--keep-config keeps config" "$P/.claude/smart-screenshot/config.json"
assert_no_file "skills removed" "$P/.claude/skills"
assert_no_file "lib removed" "$P/.claude/smart-screenshot/lib"
assert_file "captures kept" "$P/smartScreenShot/keep.xml"
assert_contains ".gitignore entry kept" "$(cat "$P/.gitignore")" "/smartScreenShot/"
assert_no_file ".gitattributes removed when only ours" "$P/.gitattributes"
bash "$ROOT/install.sh" --target "$P" --no-detect >/dev/null 2>&1
bash "$ROOT/uninstall.sh" --target "$P" >/dev/null 2>&1
assert_no_file "full uninstall removes .claude" "$P/.claude"
out="$(bash "$ROOT/uninstall.sh" --target "$P" 2>&1)"; rc=$?
assert_eq "uninstall twice exits 1" 1 "$rc"

report install
