#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for every smart-screenshot script. Source it, never run it:
#
#   . "$SCRIPT_DIR/../../../smart-screenshot/bin/config.sh"
#
# What it gives the caller:
#   log_info / log_warn / log_error / die    -> stderr, so stdout stays machine-readable
#   ss_py script.py args…                    -> Python 3, whatever it is called on this machine
#   ss_root                                  -> the project root (the directory holding .claude/)
#   config_get '.android.package' 'default'  -> a scalar from .claude/smart-screenshot/config.json
#   config_list '.ios.simulators'            -> one element per line
#   ss_output_dir / ss_commit_slug / ss_version_fallback / ss_pick_stem
#   ss_png_ok / ss_xml_ok / ss_open_url
#
# Never fails the caller on a missing or broken config: every reader falls back to its default,
# so a capture works right after install.sh, before config.json has been touched.
#
# Runs on macOS (/bin/bash 3.2 included), Linux and Windows under Git Bash / MSYS2 — the shell
# Claude Code's Bash tool uses there; WSL is plain Linux. On Windows the interpreter is usually
# `python` or the `py` launcher rather than `python3`, and paths may arrive with backslashes.

set -u

# ---------- logging -------------------------------------------------------

SS_LOG_TAG="${SS_LOG_TAG:-smart-screenshot}"
log_info()  { printf '[%s] %s\n' "$SS_LOG_TAG" "$*" >&2; }
log_warn()  { printf '[%s] WARN: %s\n' "$SS_LOG_TAG" "$*" >&2; }
log_error() { printf '[%s] ERROR: %s\n' "$SS_LOG_TAG" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# ---------- platform ------------------------------------------------------

# Backslashes -> slashes, so dirname/cd work on a Windows path (`C:\x\y` -> `C:/x/y`, which
# Git Bash accepts). A no-op on Unix paths.
ss_slashes() { printf '%s' "${1//\\//}"; }
is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
is_macos()   { [ "$(uname -s 2>/dev/null)" = Darwin ]; }

# ---------- python --------------------------------------------------------
#
# Which command runs Python 3 here: `python3` (Unix, Microsoft Store Python), `python`
# (python.org installers on Windows, some Linux), or the `py -3` launcher (Windows). A
# candidate counts only if it actually runs and is a 3.x — the Windows Store ships a
# `python3.exe` stub that only opens the Store, and `python` may be 2.x. Cached in
# SMART_SCREENSHOT_PY for the process (set it beforehand to force one).

_ss_py_ok() { "$@" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; }
ss_py_resolve() {
  if [ -z "${SMART_SCREENSHOT_PY:-}" ]; then
    if _ss_py_ok python3; then SMART_SCREENSHOT_PY=python3
    elif _ss_py_ok python; then SMART_SCREENSHOT_PY=python
    elif _ss_py_ok py -3; then SMART_SCREENSHOT_PY=py
    else SMART_SCREENSHOT_PY=none
    fi
  fi
  [ "$SMART_SCREENSHOT_PY" != none ]
}
# PYTHONUTF8=1: Windows Python would otherwise read and write in the console code page
# (cp1252), which cannot hold every accessibility label. PYTHONDONTWRITEBYTECODE=1: no
# __pycache__ next to the scripts.
ss_py() {
  ss_py_resolve || { echo "smart-screenshot: no Python 3 found (tried python3, python, py -3)" >&2; return 127; }
  case "$SMART_SCREENSHOT_PY" in
    py) PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 py -3 "$@" ;;
    *)  PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 "$SMART_SCREENSHOT_PY" "$@" ;;
  esac
}

# ---------- project root + config -----------------------------------------
#
# The package is installed at <root>/.claude/smart-screenshot/ and this file is its bin/config.sh,
# so the root is a fixed number of levels up — independent of the current directory, which is
# what makes `bash .claude/skills/smartScreenshot/scripts/smartScreenshot.sh` work from anywhere.

SS_PKG_DIR="$(cd "$(dirname "$(ss_slashes "${BASH_SOURCE[0]}")")/.." && pwd)"
ss_root() { (cd "$SS_PKG_DIR/../.." && pwd); }
ss_config_file() { printf '%s' "${SMART_SCREENSHOT_CONFIG:-$SS_PKG_DIR/config.json}"; }

_config_has_jq() { command -v jq >/dev/null 2>&1; }
_config_has_py() { ss_py_resolve; }

# Python fallback: walks a jq-style path of the form .a.b.c (no arrays, no filters).
# Every reader ends in `tr -d '\r'`: on Windows both jq and Python put a CR before each
# newline they write to a pipe.
_config_py() {
  # $1 = mode (get|list), $2 = file, $3 = path
  ss_py - "$1" "$2" "$3" <<'PY' 2>/dev/null | tr -d '\r'
import json, sys
mode, path, jqpath = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
cur = data
for part in [p for p in jqpath.split(".") if p]:
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(1)
if mode == "get":
    if cur is None or isinstance(cur, (dict, list)):
        sys.exit(1)
    print(cur if not isinstance(cur, bool) else str(cur).lower())
else:
    if not isinstance(cur, list):
        sys.exit(1)
    for x in cur:
        print(x)
PY
}

# config_get <jq path> [default]: the scalar at that path, or the default when the file, the key
# or the value is missing (an empty string in the config counts as missing).
config_get() {
  local path="$1" default="${2:-}" file out=""
  file="$(ss_config_file)"
  if [ -f "$file" ]; then
    if _config_has_jq; then
      out="$(jq -r "$path // empty" "$file" 2>/dev/null | tr -d '\r' || true)"
    elif _config_has_py; then
      out="$(_config_py get "$file" "$path" || true)"
    fi
  fi
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$default"; fi
}

# config_list <jq path>: one element per line; nothing when missing.
config_list() {
  local path="$1" file
  file="$(ss_config_file)"
  [ -f "$file" ] || return 0
  if _config_has_jq; then
    jq -r "($path // []) | .[]" "$file" 2>/dev/null | tr -d '\r' || true
  elif _config_has_py; then
    _config_py list "$file" "$path" || true
  fi
}

# ---------- output directory ----------------------------------------------
#
# SMART_SCREENSHOT_DIR wins, then config `outputDir` (relative to the project root unless
# absolute), then <root>/smartScreenShot. Always absolute, so the paths printed on stdout are
# usable from any working directory.

ss_output_dir() {
  if [ -n "${SMART_SCREENSHOT_DIR:-}" ]; then
    ss_slashes "$SMART_SCREENSHOT_DIR"; return
  fi
  local d; d="$(config_get '.outputDir' 'smartScreenShot')"
  case "$d" in
    /*|[A-Za-z]:/*) printf '%s' "${d%/}" ;;
    *) printf '%s/%s' "$(ss_root)" "${d%/}" ;;
  esac
}

# ---------- commit slug ---------------------------------------------------
#
# The last commit subject, minus a leading ticket reference (`ABC-123`, `#123`), slugified and
# capped at config `slugMaxLength` (default 10) characters. Empty when there is no git or no
# commit yet. Prints nothing on stderr.

ss_commit_slug() {
  local dir="${1:-$(ss_root)}" max subject stripped slug
  max="$(config_get '.slugMaxLength' 10)"
  case "$max" in ''|*[!0-9]*) max=10 ;; esac
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  subject="$(git -C "$dir" log -1 --pretty=%s 2>/dev/null || true)"
  [ -n "$subject" ] || return 0
  stripped="$(printf '%s' "$subject" \
    | sed -E -e 's/^\[?[A-Z][A-Z0-9_]*-[0-9]+\]?[[:space:]:.,-]*//' -e 's/^#[0-9]+[[:space:]:.,-]*//')"
  slug="$(printf '%s' "$stripped" | sed -e 's/[^A-Za-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"
  if [ "${#slug}" -gt "$max" ]; then
    slug="${slug:0:$max}"
    slug="${slug%-}"
  fi
  printf '%s' "$slug"
}

# ---------- version fallback ----------------------------------------------
#
# When the app is not installed on the device, config `version.file` + `version.regex` (one
# capture group) name where the build number lives in the repo — `gradle.properties` and
# `^app\.versionCode=(.*)`, say. Prints the first match, or nothing.

ss_version_fallback() {
  local file regex
  file="$(config_get '.version.file' '')"
  regex="$(config_get '.version.regex' '')"
  [ -n "$file" ] && [ -n "$regex" ] || return 0
  case "$file" in /*|[A-Za-z]:/*) ;; *) file="$(ss_root)/$file" ;; esac
  [ -f "$file" ] || { log_warn "version fallback file not found: $file"; return 0; }
  ss_py - "$file" "$regex" <<'PY' 2>/dev/null | tr -d '\r'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(sys.argv[2], text, re.MULTILINE)
if m:
    print((m.group(1) if m.groups() else m.group(0)).strip())
PY
}

# ---------- stem + collision-safe suffix ----------------------------------
#
# ss_pick_stem <out_dir> <prefix> <version> <slug>  -> sets SS_STEM.
# The suffix `_2`/`_3`/… is checked against every artifact a capture can produce, so variants
# never split (no `<stem>_2.png` next to a `<stem>.bounds.png`).

SS_STEM=""
ss_pick_stem() {
  local out_dir="$1" prefix="$2" version="$3" slug="$4" base suffix="" n=2
  base="${prefix}_$(date +%Y-%m-%d)_$(date +%H%M%S)_v${version}"
  [ -n "$slug" ] && base="${base}_${slug}"
  while [ -e "$out_dir/${base}${suffix}.png" ] || [ -e "$out_dir/${base}${suffix}.xml" ] \
     || [ -e "$out_dir/${base}${suffix}.bounds.png" ] || [ -e "$out_dir/${base}${suffix}.taps.png" ]; do
    suffix="_${n}"
    n=$((n + 1))
  done
  # shellcheck disable=SC2034  # read by the capture scripts
  SS_STEM="${base}${suffix}"
}

# ---------- artifact checks -----------------------------------------------

# 0 when the file is a non-empty PNG (signature bytes checked; od rather than xxd, which Git
# Bash may lack).
ss_png_ok() {
  [ -s "$1" ] || return 1
  local magic
  magic="$(head -c 8 "$1" | od -An -tx1 2>/dev/null | tr -d ' \n\r')"
  [ "$magic" = "89504e470d0a1a0a" ]
}

# 0 when the file is non-empty, well-formed when xmllint exists, and has a <hierarchy> root.
ss_xml_ok() {
  [ -s "$1" ] || return 1
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$1" 2>/dev/null || return 1
  fi
  grep -q '<hierarchy' "$1"
}

# ---------- browser -------------------------------------------------------
#
# macOS `open`, Linux `xdg-open`, and Python's webbrowser module elsewhere (on Windows that is
# os.startfile, which keeps the query string intact — `start` and `explorer` do not always).

ss_open_url() {
  local url="$1"
  if is_macos && command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 && return 0
  elif ! is_windows && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 && return 0
  fi
  ss_py -c 'import sys, webbrowser; sys.exit(0 if webbrowser.open(sys.argv[1]) else 1)' "$url" >/dev/null 2>&1
}
