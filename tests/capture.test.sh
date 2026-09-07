#!/usr/bin/env bash
# The Android capture end to end against the fake adb: naming, stdout contract, overlays and
# their restoration, package/version resolution, failure modes. Device-free.
. "$(dirname "${BASH_SOURCE[0]//\\//}")/lib.sh"
P="$(new_project capture)"
CAP="$P/.claude/skills/smartScreenshot/scripts/smartScreenshot.sh"
CFG="$P/.claude/smart-screenshot/config.json"
git -C "$P" init -q; git -C "$P" config user.email t@t; git -C "$P" config user.name t
git -C "$P" add -A; git -C "$P" commit -q -m "ABC-123: Fix the thing quickly"
TODAY="$(date +%Y-%m-%d)"

# 1. plain capture from anywhere, foreground app, version from dumpsys
LOG="$P/adb.log"
out="$(cd / && with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>"$P/err.txt")"; rc=$?
assert_eq "capture exits 0" 0 "$rc"
assert_eq "two stdout lines" 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
png="$(printf '%s\n' "$out" | sed -n 1p)"; xml="$(printf '%s\n' "$out" | sed -n 2p)"
assert_match "png name" "$png" "/smartScreenShot/smartScreenShot_${TODAY}_[0-9]{6}_v42_Fix-the-th\.png$"
assert_match "xml name" "$xml" "/smartScreenShot/smartScreenShot_${TODAY}_[0-9]{6}_v42_Fix-the-th\.xml$"
assert_eq "same stem" "${png%.png}" "${xml%.xml}"
assert_file "png exists" "$png"
assert_file "xml exists" "$xml"
ss_png_ok "$png" && pass "png is a PNG" || fail "png is a PNG"
assert_contains "xml is the dump" "$(cat "$xml")" 'resource-id="btn_save"'
assert_contains "foreground package used" "$(cat "$P/err.txt")" "Using package: com.example.app.debug (foreground app)"
assert_contains "device dump removed" "$(cat "$LOG")" "shell rm -f /sdcard/window_dump.xml"
assert_not_contains "no overlay calls without flags" "$(cat "$LOG")" "setprop"

# 2. overlays: four lines, prior state read, restored afterwards in order
: > "$LOG"
out="$(FAKE_ADB_BOUNDS_STATE=false FAKE_ADB_TAPS_STATE=1 with_fake_adb "$LOG" bash "$CAP" --with-bounds --with-taps --no-annotate 2>/dev/null)"; rc=$?
assert_eq "overlay capture exits 0" 0 "$rc"
assert_eq "four stdout lines" 4 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_match "line 2 is bounds" "$(printf '%s\n' "$out" | sed -n 2p)" '\.bounds\.png$'
assert_match "line 3 is taps" "$(printf '%s\n' "$out" | sed -n 3p)" '\.taps\.png$'
assert_match "line 4 is xml" "$(printf '%s\n' "$out" | sed -n 4p)" '\.xml$'
seq="$(grep -E 'debug.layout|show_touches' "$LOG" | sed 's/adb -s [^ ]* //' | tr '\n' '|')"
assert_eq "overlay sequence: enable, then restore prior state" \
  "shell getprop debug.layout|shell settings get system show_touches|shell setprop debug.layout true|shell settings put system show_touches 1|shell setprop debug.layout false|shell settings put system show_touches 1|" "$seq"

# 3. uiautomator failure: PNG kept and printed, no XML, exit 1
: > "$LOG"
out="$(FAKE_ADB_DUMP_FAIL=1 with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>"$P/err.txt")"; rc=$?
assert_eq "dump failure exits 1" 1 "$rc"
assert_eq "dump failure prints the png only" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_match "…and it is the png" "$out" '\.png$'
assert_no_file "no xml left behind" "${out%.png}.xml"
assert_contains "dump failure is explained" "$(cat "$P/err.txt")" "uiautomator dump failed"

# 4. pinned package (env) not installed -> version from the config fallback
printf 'app.versionCode=7\n' > "$P/gradle.properties"
ss_py - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
c["version"] = {"file": "gradle.properties", "regex": "^app\\.versionCode=(.*)$"}
json.dump(c, open(p, "w"), indent=2)
PY
out="$(SMART_SCREENSHOT_PACKAGE=com.other.app with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>"$P/err.txt")"
assert_match "fallback version in the name" "$out" '_v7_Fix-the-th\.xml$'
assert_contains "fallback is logged" "$(cat "$P/err.txt")" "not installed"
# 4b. no fallback and nothing identifiable -> v0, still a capture
ss_py - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c["version"] = {"file": "", "regex": ""}; json.dump(c, open(p, "w"))
PY
out="$(FAKE_ADB_FOREGROUND="" SMART_SCREENSHOT_PACKAGE='' with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>"$P/err.txt")"; rc=$?
assert_eq "unknown app still captures" 0 "$rc"
assert_match "…as v0" "$out" '_v0_Fix-the-th\.xml$'
assert_contains "…and says why" "$(cat "$P/err.txt")" "Could not tell which app"

# 5. config android.packages: first installed entry wins, debug first
ss_py - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c["android"]["packages"] = ["com.nope.debug", "com.example.app.debug", "com.example.app"]; json.dump(c, open(p, "w"))
PY
with_fake_adb "$LOG" bash "$CAP" --no-annotate >/dev/null 2>"$P/err.txt"
assert_contains "android.packages: first installed" "$(cat "$P/err.txt")" "Using package: com.example.app.debug (first installed entry"
ss_py - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c["android"]["packages"] = []; c["android"]["package"] = "com.example.app"; json.dump(c, open(p, "w"))
PY
with_fake_adb "$LOG" bash "$CAP" --no-annotate >/dev/null 2>"$P/err.txt"
assert_contains "android.package pins" "$(cat "$P/err.txt")" "Using package: com.example.app (pinned)"

# 6. SMART_SCREENSHOT_DIR + PREFIX
out="$(SMART_SCREENSHOT_DIR="$P/elsewhere" SMART_SCREENSHOT_PREFIX=shot with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>/dev/null | tail -1)"
assert_match "dir and prefix overrides" "$out" "/elsewhere/shot_${TODAY}_[0-9]{6}_v42_Fix-the-th\.xml$"

# 7. devices: none / several
out="$(FAKE_ADB_DEVICES="" with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>&1)"; rc=$?
assert_eq "no device exits 1" 1 "$rc"
assert_contains "no device message" "$out" "No connected Android device"
TWO="$(printf 'AAA\tdevice model:One\nBBB\tdevice model:Two')"
out="$(FAKE_ADB_DEVICES="$TWO" with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>&1 </dev/null)"; rc=$?
assert_eq "two devices, no tty -> exit 1" 1 "$rc"
assert_contains "two devices listed" "$out" "BBB (Two)"
: > "$LOG"
out="$(FAKE_ADB_DEVICES="$TWO" SMART_SCREENSHOT_DEVICE_SERIAL=BBB with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>/dev/null)"; rc=$?
assert_eq "pinned serial works" 0 "$rc"
assert_contains "pinned serial is used for every call" "$(grep screencap "$LOG")" "adb -s BBB exec-out screencap -p"
out="$(FAKE_ADB_DEVICES="$TWO" ANDROID_SERIAL=AAA with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>&1 >/dev/null)"
assert_contains "ANDROID_SERIAL honoured" "$out" "Using device: AAA (pinned)"
out="$(FAKE_ADB_DEVICES="$TWO" SMART_SCREENSHOT_DEVICE_SERIAL=CCC with_fake_adb "$LOG" bash "$CAP" --no-annotate 2>&1)"; rc=$?
assert_eq "pinned serial absent -> exit 1" 1 "$rc"

# 8. no adb at all (a PATH of just the system directories, which carry bash but not adb)
if PATH=/usr/bin:/bin command -v adb >/dev/null 2>&1; then
  pass "skip: adb lives in /usr/bin here"
else
  out="$(PATH=/usr/bin:/bin bash "$CAP" --no-annotate 2>&1)"; rc=$?
  assert_eq "no adb exits 1" 1 "$rc"
  assert_contains "no adb message" "$out" "adb not found"
fi

report capture
