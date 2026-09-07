#!/usr/bin/env bash
# Help and argument handling of both capture scripts and the selector — no device, no adb.
. "$(dirname "${BASH_SOURCE[0]//\\//}")/lib.sh"
T="$ROOT/template"
CAP="$T/.claude/skills/smartScreenshot/scripts/smartScreenshot.sh"
SEL="$T/.claude/skills/processSmartScreenshot/scripts/select_smartScreenshot.sh"
NOADB="$(new_tmp noadb)"

# The help paths must not need adb (nor python): a PATH of just the system directories.
out="$(PATH=/usr/bin:/bin bash "$CAP" --help 2>&1)"; rc=$?
assert_eq "--help exits 0" 0 "$rc"
assert_contains "--help is the Android help" "$out" "--with-bounds            Also capture"
out="$(bash "$CAP" --ios --help 2>&1)"; rc=$?
assert_eq "--ios --help exits 0" 0 "$rc"
assert_contains "--ios --help is the iOS help" "$out" "Usage: ios_smartScreenshot.sh"
out="$(bash "$CAP" --ios --android --ios --help 2>&1)"
assert_contains "last platform flag wins (ios)" "$out" "Usage: ios_smartScreenshot.sh"
out="$(bash "$CAP" --android --ios --android --help 2>&1)"
assert_contains "last platform flag wins (android)" "$out" "Usage: smartScreenshot.sh"

out="$(bash "$CAP" --bogus 2>&1)"; rc=$?
assert_eq "unknown flag exits 1" 1 "$rc"
assert_contains "unknown flag is named" "$out" "Unknown argument: --bogus"

for f in --with-bounds --with-taps --annotate; do
  out="$(bash "$CAP" --ios $f 2>&1)"; rc=$?
  assert_eq "--ios $f is refused" 1 "$rc"
  assert_contains "--ios $f names the flag" "$out" "$f"
done
out="$(bash "$CAP" --ios --no-annotate --with-taps 2>&1)"; rc=$?
assert_eq "--ios rejects the overlay before any device work" 1 "$rc"
assert_contains "…and says why" "$out" "no iOS equivalent"

# ios_smartScreenshot.sh refuses to run at all off macOS, before looking for maestro.
if ! is_macos; then
  out="$(bash "$T/.claude/skills/smartScreenshot/scripts/ios_smartScreenshot.sh" --no-annotate 2>&1)"; rc=$?
  assert_eq "iOS off macOS exits 1" 1 "$rc"
  assert_contains "iOS off macOS says so" "$out" "need macOS"
fi

out="$(bash "$SEL" --help 2>&1)"; rc=$?
assert_eq "selector --help exits 0" 0 "$rc"
assert_contains "selector help" "$out" "Usage: select_smartScreenshot.sh"
out="$(bash "$SEL" abc 2>&1)"; rc=$?
assert_eq "selector bad offset exits 2" 2 "$rc"
out="$(SMART_SCREENSHOT_DIR="$NOADB/none" bash "$SEL" 2>&1)"; rc=$?
assert_eq "selector missing folder exits 1" 1 "$rc"
assert_contains "selector missing folder message" "$out" "not found"

report help
