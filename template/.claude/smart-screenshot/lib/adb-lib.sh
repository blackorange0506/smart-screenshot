#!/usr/bin/env bash
# shellcheck shell=bash
# Android helpers for the smartScreenshot scripts: device selection, package selection, the
# installed versionCode. Source it from a skill script:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")" && pwd)"
#   . "$SCRIPT_DIR/../../../smart-screenshot/lib/adb-lib.sh"
#
# Conventions (from bin/config.sh, which this sources):
#   - log_*  -> stderr, so callers can capture clean stdout from final lines
#   - die    -> stderr + exit 1
#   - every adb call goes through adb_run so the chosen device serial is applied transparently
#
# Works wherever adb does: macOS, Linux, Windows (Git Bash). adb on Windows may end its lines
# with CR LF, so every text read from it goes through `tr -d '\r'`.

set -u

_ADB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")" && pwd)"
# shellcheck source=../bin/config.sh
. "$_ADB_LIB_DIR/../bin/config.sh"

# ---------- adb prerequisite ---------------------------------------------

require_adb() {
  command -v adb >/dev/null 2>&1 || die "adb not found on PATH. Install Android platform-tools or add them to PATH."
}

# ---------- device selection ---------------------------------------------
#
# Sets a global ADB_SERIAL. Use adb_run / adb_shell after.
#   - SMART_SCREENSHOT_DEVICE_SERIAL, ANDROID_SERIAL or config android.deviceSerial -> that device
#   - 1 device  -> use it
#   - 0 devices -> recovery: start-server, `adb connect` to android.deviceHost /
#                  SMART_SCREENSHOT_DEVICE_HOST when set, `reconnect offline`; then fail loudly
#   - 2+        -> numbered chooser on a TTY; otherwise fail and say which serials exist

ADB_SERIAL=""

_list_devices() {
  # "<serial>\t<model>" per ready device, one per line.
  adb devices -l 2>/dev/null | tr -d '\r' \
    | awk 'NR>1 && $2=="device" {
        model="";
        for (i=3;i<=NF;i++) if ($i ~ /^model:/) { sub(/^model:/, "", $i); model=$i }
        printf "%s\t%s\n", $1, (model==""?"unknown":model)
      }'
}

_recover_adb() {
  local host
  host="${SMART_SCREENSHOT_DEVICE_HOST:-$(config_get '.android.deviceHost' '')}"
  log_warn "No devices visible. Attempting recovery..."
  adb start-server >/dev/null 2>&1 || true
  if [ -n "$host" ]; then
    log_info "Trying adb connect $host"
    adb connect "$host" >/dev/null 2>&1 || true
  fi
  adb reconnect offline >/dev/null 2>&1 || true
}

select_device() {
  require_adb

  local devices wanted
  devices="$(_list_devices)"
  if [ -z "$devices" ]; then
    _recover_adb
    devices="$(_list_devices)"
  fi
  [ -n "$devices" ] || die "No connected Android device. Plug one in with USB debugging enabled, or set android.deviceHost in config.json (or SMART_SCREENSHOT_DEVICE_HOST) for wireless adb."

  wanted="${SMART_SCREENSHOT_DEVICE_SERIAL:-${ANDROID_SERIAL:-$(config_get '.android.deviceSerial' '')}}"
  if [ -n "$wanted" ]; then
    if printf '%s\n' "$devices" | awk -F'\t' '{print $1}' | grep -qx -- "$wanted"; then
      ADB_SERIAL="$wanted"
      log_info "Using device: $ADB_SERIAL (pinned)"
      return 0
    fi
    die "Device $wanted (from SMART_SCREENSHOT_DEVICE_SERIAL / ANDROID_SERIAL / config) is not connected."
  fi

  local count
  count="$(printf '%s\n' "$devices" | wc -l | tr -d ' ')"
  if [ "$count" -eq 1 ]; then
    ADB_SERIAL="$(printf '%s' "$devices" | awk -F'\t' '{print $1}')"
    log_info "Using device: $ADB_SERIAL"
    return 0
  fi

  if [ ! -t 0 ]; then
    log_error "Multiple devices connected and no TTY for an interactive picker:"
    printf '%s\n' "$devices" | awk -F'\t' '{ printf "  - %s (%s)\n", $1, $2 }' >&2
    die "Set SMART_SCREENSHOT_DEVICE_SERIAL=<serial> (or android.deviceSerial in config.json) and re-run."
  fi

  log_info "Multiple devices connected. Pick one:"
  local i=1 s m
  declare -a serials=()
  while IFS=$'\t' read -r s m; do
    printf '  %d) %s (%s)\n' "$i" "$s" "$m" >&2
    serials+=("$s")
    i=$((i+1))
  done <<< "$devices"

  local choice
  while :; do
    printf 'Choice [1-%d]: ' "${#serials[@]}" >&2
    read -r choice || die "No selection received."
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#serials[@]} )) && break
    log_warn "Invalid choice: $choice"
  done
  ADB_SERIAL="${serials[$((choice-1))]}"
  log_info "Using device: $ADB_SERIAL"
}

# ---------- adb wrappers --------------------------------------------------

adb_run()   { adb -s "$ADB_SERIAL" "$@"; }
adb_shell() { adb_run shell "$@"; }

# ---------- package selection --------------------------------------------
#
# Sets a global ADB_PACKAGE — the app whose versionCode names the capture. Priority:
#   1. SMART_SCREENSHOT_PACKAGE
#   2. config android.package
#   3. the first entry of config android.packages that is installed (list them debug-first)
#   4. whatever app is in the foreground right now
# Empty when none of that yields anything; the capture still runs, the version is then the
# fallback from config `version` or 0.

ADB_PACKAGE=""

_pkg_installed() {
  # Avoid `... | grep -q` here: under pipefail, grep -q exits early once it matches, and the
  # SIGPIPE upstream surfaces as a non-zero pipeline exit. Capture once, then a pure-bash check.
  local pkg="$1" out
  out="$(adb_shell pm list packages 2>/dev/null | tr -d '\r')" || return 1
  [[ $'\n'${out}$'\n' == *$'\n'"package:$pkg"$'\n'* ]]
}

# The package of the window that has focus (dumpsys window), falling back to the resumed
# activity (dumpsys activity). Prints nothing when neither is readable.
foreground_package() {
  local line pkg
  line="$(adb_shell dumpsys window 2>/dev/null | tr -d '\r' | grep -E 'mCurrentFocus|mFocusedApp' | head -1 || true)"
  pkg="$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.]*' | head -1 | cut -d/ -f1 || true)"
  if [ -z "$pkg" ]; then
    line="$(adb_shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep -E 'topResumedActivity|mResumedActivity|ResumedActivity' | head -1 || true)"
    pkg="$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.]*' | head -1 | cut -d/ -f1 || true)"
  fi
  printf '%s' "$pkg"
}

select_package() {
  local pinned
  pinned="${SMART_SCREENSHOT_PACKAGE:-$(config_get '.android.package' '')}"
  if [ -n "$pinned" ]; then
    ADB_PACKAGE="$pinned"
    if _pkg_installed "$ADB_PACKAGE"; then
      log_info "Using package: $ADB_PACKAGE (pinned)"
    else
      log_warn "Pinned package $ADB_PACKAGE is not installed on $ADB_SERIAL; the version will come from the fallback."
    fi
    return 0
  fi

  local candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if _pkg_installed "$candidate"; then
      ADB_PACKAGE="$candidate"
      log_info "Using package: $ADB_PACKAGE (first installed entry of android.packages)"
      return 0
    fi
  done <<< "$(config_list '.android.packages')"

  ADB_PACKAGE="$(foreground_package)"
  if [ -n "$ADB_PACKAGE" ]; then
    log_info "Using package: $ADB_PACKAGE (foreground app)"
  else
    log_warn "Could not tell which app is in the foreground; set android.package in config.json. The version will come from the fallback."
  fi
}

# ---------- version -------------------------------------------------------
#
# Prints the installed versionCode of ADB_PACKAGE, else the config fallback, else 0.

android_version_code() {
  local out="" dump
  if [ -n "$ADB_PACKAGE" ]; then
    dump="$(adb_shell dumpsys package "$ADB_PACKAGE" 2>/dev/null | tr -d '\r' || true)"
    out="$(printf '%s\n' "$dump" | grep -E 'versionCode=' | head -1 | sed -E 's/.*versionCode=([0-9]+).*/\1/' || true)"
  fi
  if [ -z "$out" ]; then
    out="$(ss_version_fallback)"
    [ -n "$out" ] && log_info "Version $out from the config fallback (app not installed or not identified)"
  fi
  printf '%s' "${out:-0}"
}

# ---------- one-shot bootstrap ---------------------------------------------

bootstrap_device_and_pkg() { select_device; select_package; }
