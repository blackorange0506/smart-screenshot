#!/usr/bin/env bash
# Run one of the package's Python scripts with whatever Python 3 the machine has:
#
#   bash .claude/smart-screenshot/bin/py.sh detect_project.py [args…]
#   bash .claude/smart-screenshot/bin/py.sh .claude/skills/smartScreenshot/scripts/selftest_maestro_to_uiautomator.py
#   (a bare name is looked up in this directory; a path with a slash is used as given)
#
# `python3` on macOS and Linux; on Windows (Git Bash) it is usually `python` or the `py`
# launcher, and a bare `python3` fails — this wrapper is the one command the skills and the
# docs use on every OS. The resolution lives in config.sh (ss_py).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")" && pwd)"
# shellcheck source=config.sh
. "$HERE/config.sh"
[ $# -ge 1 ] || { echo "usage: py.sh <script.py in $HERE, or a path> [args…]" >&2; exit 2; }
script="$1"; shift
case "$script" in */*) ;; *) script="$HERE/$script" ;; esac
[ -f "$script" ] || { echo "py.sh: no such script: $script" >&2; exit 2; }
ss_py "$script" "$@"
