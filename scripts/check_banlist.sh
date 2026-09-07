#!/usr/bin/env bash
# Fail when any banned word appears in the repository's tracked files (plus untracked, unignored
# ones — everything `git ls-files -co --exclude-standard` lists). Two lists, same syntax:
#   scripts/banlist.txt        tracked, non-identifying patterns
#   scripts/banlist.local.txt  git-ignored, optional: the words that would identify the private
#                              project this was extracted from; only present on its author's machines
# Run before every commit and in CI (CI has only the tracked list).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1
files="$(git ls-files -co --exclude-standard | grep -v -e "^scripts/banlist.txt$" -e "^scripts/banlist.local.txt$" -e "^scripts/check_banlist.sh$")"
[ -n "$files" ] || { echo "[banlist] no files"; exit 0; }
hits=0
lists="banlist.txt"
[ -f "$HERE/banlist.local.txt" ] && lists="$lists banlist.local.txt"
for list in $lists; do
  while IFS= read -r pat; do
    case "$pat" in ""|"#"*) continue ;; esac
    flags="-nE"
    case "$pat" in i:*) flags="-inE"; pat="${pat#i:}" ;; esac
    # shellcheck disable=SC2086
    out="$(printf "%s\n" "$files" | xargs grep $flags -- "$pat" 2>/dev/null || true)"
    if [ -n "$out" ]; then
      hits=1
      printf "[banlist] \"%s\" (%s):\n%s\n" "$pat" "$list" "$out"
    fi
  done < "$HERE/$list"
done
if [ "$hits" = 1 ]; then echo "[banlist] FAILED"; exit 1; fi
echo "[banlist] clean ($(printf "%s\n" "$files" | wc -l | tr -d " ") files; lists: $lists)"
