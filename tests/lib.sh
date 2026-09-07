#!/usr/bin/env bash
# Tiny assertion helpers shared by tests/*.test.sh. No framework.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")/.." && pwd)"
TMP_BASE="$ROOT/tests/.tmp"
# Python 3 by whatever name it has here (python3 / python / py -3): ss_py.
. "$ROOT/template/.claude/smart-screenshot/bin/config.sh"
mkdir -p "$TMP_BASE"
FAILS=0
PASSES=0
pass() { PASSES=$((PASSES + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }
assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 400)" ;; esac
}
assert_not_contains() { # name haystack needle
  case "$2" in *"$3"*) fail "$1" "unexpected [$3]" ;; *) pass "$1" ;; esac
}
assert_match() { # name string extended-regex
  if printf '%s\n' "$2" | grep -qE -- "$3"; then pass "$1"; else fail "$1" "[$2] does not match /$3/"; fi
}
assert_file() { if [ -f "$2" ]; then pass "$1"; else fail "$1" "no file $2"; fi; }
assert_no_file() { # name path — a leftover directory is listed, so a failure says what was left behind
  if [ ! -e "$2" ]; then pass "$1"
  elif [ -d "$2" ]; then fail "$1" "unexpected dir $2 holding: $(cd "$2" && find . | sed 's|^\./||' | tr '\n' ' ')"
  else fail "$1" "unexpected file $2"; fi
}
# number of CR bytes in a file — through Python, since a bare CR as a grep pattern is fragile
cr_count() { ss_py -c 'import sys; print(open(sys.argv[1], "rb").read().count(b"\r"))' "$1"; }
new_tmp() { local d; d="$(mktemp -d "$TMP_BASE/$1.XXXXXX")"; printf '%s' "$d"; }
# install the template into a fresh directory (quietly) and print its path
new_project() { # name
  local d; d="$(new_tmp "$1")"
  bash "$ROOT/install.sh" --target "$d" --no-detect >/dev/null 2>&1 || { echo "install failed" >&2; return 1; }
  printf '%s' "$d"
}
# a bash whose PATH starts with the fake adb; FAKE_ADB_LOG records every call
with_fake_adb() { # log-file command…
  local logf="$1"; shift
  FAKE_ADB_LOG="$logf" PATH="$ROOT/tests/fixtures/fake-adb-bin:$PATH" "$@"
}
report() {
  printf '%s: %d passed, %d failed\n' "$1" "$PASSES" "$FAILS"
  [ "$FAILS" -eq 0 ]
}
