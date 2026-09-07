#!/usr/bin/env bash
# Run every tests/*.test.sh with the bash that runs this script; exit 1 if any fails.
cd "$(dirname "${BASH_SOURCE[0]//\\//}")/.." || exit 1
rc=0
for t in tests/*.test.sh; do
  printf '\n== %s (%s)\n' "$t" "$BASH_VERSION"
  bash "$t" || rc=1
done
rm -rf tests/.tmp
[ "$rc" -eq 0 ] && printf '\nALL TESTS PASSED\n' || printf '\nSOME TESTS FAILED\n'
exit "$rc"
