#!/usr/bin/env bash
# Runs shellcheck over every shell script (the fake adb fixture included), py_compile over every
# Python script.
set -eu
cd "$(dirname "${BASH_SOURCE[0]}")/.."
sh_files="$(git ls-files -co --exclude-standard '*.sh' 'tests/fixtures/fake-adb-bin/adb' | tr '\n' ' ')"
# shellcheck disable=SC2086
shellcheck -x -e SC1091,SC2016,SC2015,SC2329,SC2317 $sh_files
py_files="$(git ls-files -co --exclude-standard '*.py' | tr '\n' ' ')"
# shellcheck disable=SC2086
[ -z "$py_files" ] || python3 -m py_compile $py_files
find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "[lint] ok"
