#!/usr/bin/env bash
#
# install.sh — install smart-screenshot into a project.
#
#   bash /path/to/smart-screenshot/install.sh [--target DIR] [--no-detect] [--dry-run] [--force]
#
# Run it from inside the project (or name it with --target). Idempotent: re-running upgrades
# the package files and leaves your config.json and your captures alone.
#
# What it does:
#   1. preflight: Python 3 (required: python3, python or py -3), git (warning only),
#      adb / xcrun / maestro (reported, not required — they are needed at capture time)
#   2. copies template/.claude/** into <target>/.claude/ (package files, always overwritten)
#   3. adds the capture folder to <target>/.gitignore
#   4. adds two lines to <target>/.gitattributes so the scripts survive a CRLF checkout
#   5. writes .claude/smart-screenshot/config.json from the example if absent, fills its empty
#      values from what detect_project.py finds in the repo (unless --no-detect), stamps
#      VERSION and writes MANIFEST (the list uninstall.sh removes)
#
# bash 3.2 is enough (macOS /bin/bash); on Windows run it from Git Bash (what Claude Code uses).

set -eu

SRC="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")" && pwd)"
TEMPLATE="$SRC/template/.claude"
# shellcheck source=template/.claude/smart-screenshot/bin/config.sh
. "$TEMPLATE/smart-screenshot/bin/config.sh"   # ss_py: python3 / python / py -3
TARGET="$(pwd)"
DETECT=1
DRY=0
FORCE=0

log()  { printf '\033[0;36m[smart-screenshot]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[smart-screenshot WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[smart-screenshot ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
dry()  { printf '\033[0;35m[dry-run]\033[0m %s\n' "$*"; }

usage() {
  sed -n '2,/^# bash 3.2/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) [ $# -ge 2 ] || err "--target needs a directory"; TARGET="$(ss_slashes "$2")"; shift 2 ;;
    --target=*) TARGET="$(ss_slashes "${1#--target=}")"; shift ;;
    --no-detect) DETECT=0; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; err "unknown argument: $1" ;;
  esac
done

[ -d "$TEMPLATE" ] || err "template not found at $TEMPLATE — run this script from a smart-screenshot checkout"
[ -d "$TARGET" ] || err "target is not a directory: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"
[ "$TARGET" != "$SRC" ] || err "the target is the smart-screenshot checkout itself; run from your project (or pass --target)"

# ---- 1. preflight -----------------------------------------------------------

ss_py_resolve || err "Python 3 is required (the annotator server, the iOS converter and the config reader use it); none of python3, python, py -3 works here"
if git -C "$TARGET" rev-parse --show-toplevel >/dev/null 2>&1; then
  # cd && pwd: Git for Windows prints C:/x/y while Git Bash's pwd says /c/x/y; compare like with like.
  GIT_ROOT="$(cd "$(git -C "$TARGET" rev-parse --show-toplevel)" && pwd)"
  [ "$GIT_ROOT" = "$TARGET" ] || warn "target $TARGET is inside the git repo $GIT_ROOT but is not its root; the commit slug still comes from that repo"
else
  warn "$TARGET is not a git repository; captures will carry no commit slug until it is one"
fi

log "installing smart-screenshot $(cat "$SRC/VERSION") into $TARGET"
log "Python: $SMART_SCREENSHOT_PY$(command -v jq >/dev/null 2>&1 || printf '; no jq (the config reader uses Python instead, fine)')"
command -v adb >/dev/null 2>&1   && log "adb found: Android captures are possible here" || log "adb not on PATH: install Android platform-tools before an Android capture"
if is_macos; then
  command -v xcrun >/dev/null 2>&1 && log "xcrun found: iOS simulator captures are possible here" || log "xcrun not found: install Xcode before an iOS capture"
  if [ -x "$HOME/.maestro/bin/maestro" ] || command -v maestro >/dev/null 2>&1; then log "maestro found"; else log "maestro not found: iOS captures need it (curl -Ls https://get.maestro.mobile.dev | bash)"; fi
else
  log "not macOS: only --android captures are available here (iOS needs xcrun simctl)"
fi

# Claude Code watches .claude/skills/ for live changes only when the directory existed at
# session start, so a session already open in a project without one will not see the new
# skills until it is restarted. CLAUDECODE is set in Claude Code's own terminal (the Bash tool).
HAD_SKILLS_DIR=0; [ -d "$TARGET/.claude/skills" ] && HAD_SKILLS_DIR=1
INSIDE_CLAUDE=0; [ -n "${CLAUDECODE:-}" ] && INSIDE_CLAUDE=1

# ---- 2. copy the package files ---------------------------------------------

MANIFEST_TMP="$(mktemp "${TMPDIR:-/tmp}/smart-screenshot-manifest.XXXXXX")"
trap 'rm -f "$MANIFEST_TMP"' EXIT

copy_one() {
  # $1 = path relative to template/.claude
  local rel="$1" src="$TEMPLATE/$1" dst="$TARGET/.claude/$1"
  printf '.claude/%s\n' "$rel" >> "$MANIFEST_TMP"
  if [ "$DRY" = 1 ]; then
    if [ -f "$dst" ]; then
      if cmp -s "$src" "$dst"; then :; else dry "update .claude/$rel"; fi
    else
      dry "add    .claude/$rel"
    fi
    return
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  case "$rel" in *.sh|*.py) chmod +x "$dst" ;; esac
}

( cd "$TEMPLATE" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) | while IFS= read -r rel; do
  case "$rel" in
    .DS_Store|*/.DS_Store) continue ;;
  esac
  copy_one "$rel"
done
[ "$DRY" = 1 ] || log "package files copied to .claude/ ($(wc -l < "$MANIFEST_TMP" | tr -d ' ') files)"

PKG="$TARGET/.claude/smart-screenshot"
BIN="$TEMPLATE/smart-screenshot/bin"   # the copy in the target may not exist on --dry-run

# ---- 3. .gitignore: the capture folder --------------------------------------------

OUT_DIR="smartScreenShot"
if [ -f "$PKG/config.json" ]; then
  v="$(SMART_SCREENSHOT_CONFIG="$PKG/config.json" config_get '.outputDir' '')"
  [ -n "$v" ] && OUT_DIR="$v"
fi
GITIGNORE="$TARGET/.gitignore"
ensure_ignored() {
  local line="$1"
  if [ -f "$GITIGNORE" ] && grep -qxF "$line" "$GITIGNORE"; then return; fi
  if [ "$DRY" = 1 ]; then dry "add '$line' to .gitignore"; return; fi
  if [ -f "$GITIGNORE" ] && [ -n "$(tail -c 1 "$GITIGNORE")" ]; then printf '\n' >> "$GITIGNORE"; fi
  printf '%s\n' "$line" >> "$GITIGNORE"
  log ".gitignore: $line"
}
case "$OUT_DIR" in
  /*|[A-Za-z]:/*) log "outputDir is absolute ($OUT_DIR); nothing to git-ignore" ;;
  # Anchored: an unanchored "smartScreenShot/" also matches .claude/skills/smartScreenshot/ on a
  # case-insensitive file system (core.ignorecase=true on macOS and Windows).
  *) ensure_ignored "/${OUT_DIR%/}/" ;;
esac

# ---- 4. .gitattributes: the scripts must stay LF ----------------------------------
# A Windows checkout with core.autocrlf=true would turn them into CRLF, which bash cannot run.

GITATTRIBUTES="$TARGET/.gitattributes"
ensure_attr() {
  local line="$1"
  if [ -f "$GITATTRIBUTES" ] && grep -qxF "$line" "$GITATTRIBUTES"; then return; fi
  if [ "$DRY" = 1 ]; then dry "add '$line' to .gitattributes"; return; fi
  if [ -f "$GITATTRIBUTES" ] && [ -n "$(tail -c 1 "$GITATTRIBUTES")" ]; then printf '\n' >> "$GITATTRIBUTES"; fi
  printf '%s\n' "$line" >> "$GITATTRIBUTES"
  log ".gitattributes: $line"
}
ensure_attr ".claude/smart-screenshot/** text eol=lf"
ensure_attr ".claude/skills/smartScreenshot/scripts/* text eol=lf"
ensure_attr ".claude/skills/processSmartScreenshot/scripts/* text eol=lf"

# ---- 5. config, version, manifest -------------------------------------------------

if [ "$DRY" = 1 ]; then
  if [ -f "$PKG/config.json" ]; then
    [ "$FORCE" = 1 ] && dry "reset .claude/smart-screenshot/config.json from the example (backup: config.json.bak)"
  else
    dry "write .claude/smart-screenshot/config.json from the example"
  fi
  if [ "$DETECT" = 1 ]; then
    dry "fill the empty config values from the repo:"
    ss_py "$BIN/detect_project.py" --root "$TARGET" | sed 's/^/           /'
  fi
  dry "write VERSION and MANIFEST"
  [ "$HAD_SKILLS_DIR" = 1 ] || dry "note: .claude/skills/ is new; a Claude Code session already open in $TARGET will need a restart to see the skills"
  log "dry run finished; nothing was written"
  exit 0
fi

if [ -f "$PKG/config.json" ] && [ "$FORCE" = 1 ]; then
  cp "$PKG/config.json" "$PKG/config.json.bak"
  cp "$PKG/config.example.json" "$PKG/config.json"
  log "config.json reset from the example (--force); previous copy in config.json.bak"
elif [ ! -f "$PKG/config.json" ]; then
  cp "$PKG/config.example.json" "$PKG/config.json"
  log "config.json written with the defaults"
fi
if [ "$DETECT" = 1 ]; then
  ss_py "$PKG/bin/detect_project.py" --root "$TARGET" --write "$PKG/config.json" | sed 's/^/  /'
fi
ss_py -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$PKG/config.json" \
  || err "config.json is invalid JSON; fix it or re-run with --force"
cp "$SRC/VERSION" "$PKG/VERSION"
LC_ALL=C sort -u "$MANIFEST_TMP" > "$PKG/MANIFEST"

cat <<DONE

Installed smart-screenshot $(cat "$SRC/VERSION") in $TARGET
  config:   .claude/smart-screenshot/config.json
  captures: $OUT_DIR/   (git-ignored)
  skills:   /smartScreenshot  /processSmartScreenshot  /smartScreenshotSetup

DONE

if [ "$HAD_SKILLS_DIR" = 0 ] && [ "$INSIDE_CLAUDE" = 1 ]; then
  warn "this ran inside a Claude Code session and .claude/skills/ did not exist when that session started; the running session cannot see the new skills (Claude Code only watches skill directories that existed at startup)"
  cat <<DONE
Next: exit Claude Code, start it again in $TARGET, then run  /smartScreenshotSetup
      (or go straight to /smartScreenshot with a device connected)
DONE
elif [ "$HAD_SKILLS_DIR" = 0 ]; then
  cat <<DONE
Next: open Claude Code in $TARGET and run  /smartScreenshotSetup
      If Claude Code is already open in this project, restart it first: a new .claude/skills/
      directory is only seen from the next session.
DONE
else
  cat <<DONE
Next: open Claude Code in $TARGET and run  /smartScreenshotSetup  (or /smartScreenshot directly)
DONE
fi
