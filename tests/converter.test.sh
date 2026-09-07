#!/usr/bin/env bash
# The iOS converter's own self-test, through the py.sh wrapper so the wrapper is covered too.
. "$(dirname "${BASH_SOURCE[0]//\\//}")/lib.sh"
P="$(new_project converter)"
out="$(cd "$P" && bash .claude/smart-screenshot/bin/py.sh .claude/skills/smartScreenshot/scripts/selftest_maestro_to_uiautomator.py 2>&1)"; rc=$?
assert_eq "selftest exits 0" 0 "$rc"
assert_contains "selftest passed" "$out" "SELFTEST PASSED"
assert_not_contains "no failures" "$out" "FAIL "
out="$(cd "$P" && bash .claude/smart-screenshot/bin/py.sh nope.py 2>&1)"; rc=$?
assert_eq "py.sh missing script exits 2" 2 "$rc"
# A conversion from the command line with the union fallback, no PNG: hard failure.
out="$(printf '{"attributes":{"bounds":"[0,0][10,10]"}}' | ss_py "$P/.claude/skills/smartScreenshot/scripts/maestro_to_uiautomator.py" --json - 2>&1)"; rc=$?
assert_eq "no png, no scale -> exit 1" 1 "$rc"
assert_contains "…and says so" "$out" "no PNG"
report converter
