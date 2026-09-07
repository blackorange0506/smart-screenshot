#!/usr/bin/env bash
#
# uninstall.sh — remove what install.sh added to a project.
#
#   bash /path/to/smart-screenshot/uninstall.sh [--target DIR] [--keep-config] [--dry-run]
#
# Removes the package files listed in .claude/smart-screenshot/MANIFEST and the .gitattributes
# lines install.sh added. Keeps the capture folder and its .gitignore entry, and — with
# --keep-config — config.json. Runs on macOS, Linux and Windows (Git Bash).

set -eu

TARGET="$(pwd)"
KEEP_CONFIG=0
DRY=0

log()  { printf '\033[0;36m[smart-screenshot]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[smart-screenshot ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
dry()  { printf '\033[0;35m[dry-run]\033[0m %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target) [ $# -ge 2 ] || err "--target needs a directory"; TARGET="${2//\\//}"; shift 2 ;;
    --target=*) TARGET="${1#--target=}"; TARGET="${TARGET//\\//}"; shift ;;
    --keep-config) KEEP_CONFIG=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown argument: $1" ;;
  esac
done

TARGET="$(cd "$TARGET" && pwd)"
PKG="$TARGET/.claude/smart-screenshot"
[ -f "$PKG/MANIFEST" ] || err "no .claude/smart-screenshot/MANIFEST in $TARGET — nothing installed here (or an older install; delete .claude/smart-screenshot and .claude/skills/{smartScreenshot,processSmartScreenshot,smartScreenshotSetup} by hand)"

rm_file() {
  local f="$TARGET/$1"
  [ -e "$f" ] || return 0
  if [ "$DRY" = 1 ]; then dry "rm $1"; else rm -f "$f"; fi
}

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  rm_file "$rel"
done < "$PKG/MANIFEST"
for extra in .claude/smart-screenshot/VERSION .claude/smart-screenshot/MANIFEST .claude/smart-screenshot/config.json.bak; do
  rm_file "$extra"
done
if [ "$KEEP_CONFIG" = 1 ]; then
  log "keeping .claude/smart-screenshot/config.json"
else
  rm_file .claude/smart-screenshot/config.json
fi

# The .gitignore entry for the capture folder stays: it may hold captures the user wants kept
# out of git. The .gitattributes lines install.sh added go.
GITATTRIBUTES="$TARGET/.gitattributes"
if [ -f "$GITATTRIBUTES" ] && grep -qF '.claude/smart-screenshot/** text eol=lf' "$GITATTRIBUTES"; then
  if [ "$DRY" = 1 ]; then dry "remove the smart-screenshot lines from .gitattributes"; else
    grep -vxF -e '.claude/smart-screenshot/** text eol=lf' \
              -e '.claude/skills/smartScreenshot/scripts/* text eol=lf' \
              -e '.claude/skills/processSmartScreenshot/scripts/* text eol=lf' \
              "$GITATTRIBUTES" > "$GITATTRIBUTES.tmp" || true
    if [ -s "$GITATTRIBUTES.tmp" ]; then mv "$GITATTRIBUTES.tmp" "$GITATTRIBUTES"; else rm -f "$GITATTRIBUTES.tmp" "$GITATTRIBUTES"; fi
    log ".gitattributes: smart-screenshot lines removed"
  fi
fi

# Empty directories left behind (and any bytecode cache a Python without
# PYTHONDONTWRITEBYTECODE may have written next to the scripts).
if [ "$DRY" = 0 ]; then
  rm -rf "$PKG/bin/__pycache__" "$TARGET/.claude/skills/smartScreenshot/scripts/__pycache__"
  for d in .claude/skills/smartScreenshot/scripts .claude/skills/smartScreenshot \
           .claude/skills/processSmartScreenshot/scripts .claude/skills/processSmartScreenshot \
           .claude/skills/smartScreenshotSetup .claude/skills \
           .claude/smart-screenshot/bin .claude/smart-screenshot/lib .claude/smart-screenshot .claude; do
    [ -d "$TARGET/$d" ] && rmdir "$TARGET/$d" 2>/dev/null || true
  done
fi
log "smart-screenshot removed from $TARGET (captures untouched)"
