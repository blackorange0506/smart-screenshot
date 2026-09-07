#!/usr/bin/env bash
# select_smartScreenshot.sh: mtime ordering, offsets, labelled lines, exit codes.
. "$(dirname "${BASH_SOURCE[0]//\\//}")/lib.sh"
P="$(new_project selector)"
SEL="$P/.claude/skills/processSmartScreenshot/scripts/select_smartScreenshot.sh"
D="$P/smartScreenShot"; mkdir -p "$D"
mk() { # stem mtime(YYYYMMDDhhmm) extra-suffixes…
  local stem="$1" t="$2"; shift 2
  : > "$D/$stem.xml"; : > "$D/$stem.png"; touch -t "$t" "$D/$stem.xml"
  for s in "$@"; do : > "$D/$stem$s"; done
}
mk smartScreenShot_2026-01-01_100000_v1_old 202601011000
mk smartScreenShot_ios_2026-01-02_100000_v1_mid 202601021000 .marks.json
mk smartScreenShot_2026-01-03_100000_v1_new 202601031000 .bounds.png .taps.png .bounds.marks.json .marks.json
: > "$D/smartScreenShot_2026-01-04_100000_v1_orphan.png"   # a PNG whose XML failed: not a capture

out="$(cd / && bash "$SEL" 2>/dev/null)"; rc=$?
assert_eq "newest: exit 0" 0 "$rc"
assert_eq "newest: STEM" "STEM=smartScreenShot_2026-01-03_100000_v1_new" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "newest: XML line" "XML=$D/smartScreenShot_2026-01-03_100000_v1_new.xml" "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "newest: all seven lines" "STEM XML PNG BOUNDS_PNG TAPS_PNG MARKS BOUNDS_MARKS" "$(printf '%s\n' "$out" | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//')"

out="$(bash "$SEL" -1 2>/dev/null)"
assert_eq "-1: the iOS capture" "STEM=smartScreenShot_ios_2026-01-02_100000_v1_mid" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "-1: lines" "STEM XML PNG MARKS" "$(printf '%s\n' "$out" | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//')"
out="$(bash "$SEL" 2 2>/dev/null)"
assert_eq "+2 == -2" "STEM=smartScreenShot_2026-01-01_100000_v1_old" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "-2: no png sidecars" "STEM XML PNG" "$(printf '%s\n' "$out" | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//')"

out="$(bash "$SEL" -3 2>&1 >/dev/null)"; rc=$?
assert_eq "out of range exits 1" 1 "$rc"
assert_contains "out of range lists the captures" "$out" "Only 3 capture(s) available"
assert_contains "…with their offsets" "$out" " -2  smartScreenShot_2026-01-01_100000_v1_old.xml"

# SMART_SCREENSHOT_DIR and config outputDir
mkdir -p "$P/other"; mk_other() { : > "$P/other/$1.xml"; }; mk_other cap_x
out="$(SMART_SCREENSHOT_DIR="$P/other" bash "$SEL" 2>/dev/null | sed -n 1p)"
assert_eq "SMART_SCREENSHOT_DIR" "STEM=cap_x" "$out"
printf '{ "outputDir": "other" }' > "$P/.claude/smart-screenshot/config.json"
out="$(bash "$SEL" 2>/dev/null | sed -n 1p)"
assert_eq "config outputDir" "STEM=cap_x" "$out"
rm -rf "$P/other"
out="$(bash "$SEL" 2>&1)"; rc=$?
assert_eq "empty folder exits 1" 1 "$rc"

report selector
