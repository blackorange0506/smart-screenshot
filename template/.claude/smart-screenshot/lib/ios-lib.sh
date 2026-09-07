#!/usr/bin/env bash
# shellcheck shell=bash
# iOS simulator helpers for ios_smartScreenshot.sh: simulator selection, the app's bundle id,
# the installed CFBundleVersion, the screen scale. macOS only — everything here is xcrun simctl.
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")" && pwd)"
#   . "$SCRIPT_DIR/../../../smart-screenshot/lib/ios-lib.sh"
#
# Conventions match lib/adb-lib.sh: log_* to stderr, die exits 1, every simctl call goes
# through sim_run so the chosen simulator is applied transparently.

set -u

_IOS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")" && pwd)"
# shellcheck source=../bin/config.sh
. "$_IOS_LIB_DIR/../bin/config.sh"

# ---------- prerequisites -------------------------------------------------

require_xcode() {
  is_macos || die "iOS captures need macOS: the screenshot and the simulator come from xcrun simctl."
  command -v xcrun >/dev/null 2>&1 || die "xcrun not found. Install Xcode and its command line tools."
  xcrun simctl help >/dev/null 2>&1 || die "simctl unavailable. Run: sudo xcode-select -s /Applications/Xcode.app"
}

# ---------- simulator selection -------------------------------------------
#
# Sets a global IOS_SIM_UDID:
#   - SMART_SCREENSHOT_IOS_SIM set -> match by udid or by name, boot it if shut down
#   - config ios.simulators        -> the first one that exists wins, booted or not, even when
#                                     some other simulator is already running
#   - exactly one booted           -> use it
#   - none booted                  -> boot the newest available iPhone
#   - several booted + TTY         -> numbered chooser; no TTY -> die

IOS_SIM_UDID=""

_booted_sims() {
  # "<udid>\t<name>" per booted simulator.
  xcrun simctl list devices booted 2>/dev/null \
    | sed -n 's/^ *\(.*\) (\([0-9A-F-]\{36\}\)) (Booted).*/\2	\1/p'
}

_available_iphones() {
  # "<udid>\t<name>", newest runtime last (simctl lists runtimes in ascending order).
  xcrun simctl list devices available 2>/dev/null \
    | sed -n 's/^ *\(iPhone.*\) (\([0-9A-F-]\{36\}\)) (Shutdown).*/\2	\1/p'
}

# First name from config ios.simulators present in the "<udid>\t<name>" lines on stdin; prints
# that whole line. Nothing printed when none match.
_pick_preferred() {
  local list name hit
  list="$(cat)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    hit="$(printf '%s\n' "$list" | awk -F'\t' -v q="$name" '$2==q {print; exit}')"
    [ -n "$hit" ] && { printf '%s\n' "$hit"; return 0; }
  done <<< "$(config_list '.ios.simulators')"
  return 1
}

_boot_and_wait() {
  local udid="$1"
  log_info "Booting simulator $udid"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  open -a Simulator >/dev/null 2>&1 || true
}

select_simulator() {
  require_xcode

  if [ -n "${SMART_SCREENSHOT_IOS_SIM:-}" ]; then
    local match
    match="$(xcrun simctl list devices available 2>/dev/null \
      | sed -n 's/^ *\(.*\) (\([0-9A-F-]\{36\}\)).*/\2	\1/p' \
      | awk -F'\t' -v q="$SMART_SCREENSHOT_IOS_SIM" '$1==q || $2==q {print $1; exit}')"
    [ -n "$match" ] || die "SMART_SCREENSHOT_IOS_SIM=$SMART_SCREENSHOT_IOS_SIM matches no available simulator."
    IOS_SIM_UDID="$match"
    _booted_sims | grep -q "^$IOS_SIM_UDID" || _boot_and_wait "$IOS_SIM_UDID"
    log_info "Using simulator: $IOS_SIM_UDID (from SMART_SCREENSHOT_IOS_SIM)"
    return 0
  fi

  local booted count
  booted="$(_booted_sims)"
  count="$([ -n "$booted" ] && printf '%s\n' "$booted" | wc -l | tr -d ' ' || echo 0)"

  # The configured default outranks whatever happens to be running: a simulator left booted
  # from last week should not silently become the device under test.
  local preferred
  preferred="$({ printf '%s\n' "$booted"; _available_iphones; } | _pick_preferred || true)"
  if [ -n "$preferred" ]; then
    IOS_SIM_UDID="$(printf '%s' "$preferred" | awk -F'\t' '{print $1}')"
    log_info "Using configured simulator: $(printf '%s' "$preferred" | awk -F'\t' '{print $2}') ($IOS_SIM_UDID)"
    printf '%s\n' "$booted" | grep -q "^$IOS_SIM_UDID" || _boot_and_wait "$IOS_SIM_UDID"
    return 0
  fi

  if [ "$count" -eq 1 ]; then
    IOS_SIM_UDID="$(printf '%s' "$booted" | awk -F'\t' '{print $1}')"
    log_info "Using booted simulator: $(printf '%s' "$booted" | awk -F'\t' '{print $2}') ($IOS_SIM_UDID)"
    return 0
  fi

  if [ "$count" -eq 0 ]; then
    local candidate
    candidate="$(_available_iphones | tail -1)"
    [ -n "$candidate" ] || die "No iPhone simulators available. Create one in Xcode > Settings > Platforms."
    log_warn "No configured simulator found; falling back to $(printf '%s' "$candidate" | awk -F'\t' '{print $2}')"
    IOS_SIM_UDID="$(printf '%s' "$candidate" | awk -F'\t' '{print $1}')"
    _boot_and_wait "$IOS_SIM_UDID"
    return 0
  fi

  if [ ! -t 0 ]; then
    log_error "Multiple simulators booted and no TTY for the picker:"
    printf '%s\n' "$booted" | awk -F'\t' '{ printf "  - %s (%s)\n", $2, $1 }' >&2
    die "Set SMART_SCREENSHOT_IOS_SIM=<name|udid> (or ios.simulators in config.json) and re-run."
  fi

  log_info "Multiple simulators booted. Pick one:"
  local i=1 u n
  declare -a udids=()
  while IFS=$'\t' read -r u n; do
    printf '  %d) %s (%s)\n' "$i" "$n" "$u" >&2
    udids+=("$u")
    i=$((i+1))
  done <<< "$booted"

  local choice
  while :; do
    printf 'Choice [1-%d]: ' "${#udids[@]}" >&2
    read -r choice || die "No selection received."
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#udids[@]} )) && break
    log_warn "Invalid choice: $choice"
  done
  IOS_SIM_UDID="${udids[$((choice-1))]}"
}

sim_run() { xcrun simctl "$1" "$IOS_SIM_UDID" "${@:2}"; }

# ---------- the app: bundle id, version ------------------------------------
#
# Sets IOS_BUNDLE_ID: SMART_SCREENSHOT_IOS_BUNDLE_ID, then config ios.bundleId, then the one
# non-Apple app the simulator is running (launchctl lists every UIKit app process). Empty when
# nothing is conclusive — the capture still runs; the version is then the config fallback or 0.

IOS_BUNDLE_ID=""

select_bundle_id() {
  IOS_BUNDLE_ID="${SMART_SCREENSHOT_IOS_BUNDLE_ID:-$(config_get '.ios.bundleId' '')}"
  if [ -n "$IOS_BUNDLE_ID" ]; then
    log_info "Using bundle id: $IOS_BUNDLE_ID (pinned)"
    return 0
  fi
  local running count
  running="$(sim_run spawn launchctl list 2>/dev/null \
    | grep -oE 'UIKitApplication:[A-Za-z0-9_.-]+' | sed 's/^UIKitApplication://' \
    | grep -v '^com\.apple\.' | sort -u || true)"
  count="$([ -n "$running" ] && printf '%s\n' "$running" | wc -l | tr -d ' ' || echo 0)"
  if [ "$count" -eq 1 ]; then
    IOS_BUNDLE_ID="$running"
    log_info "Using bundle id: $IOS_BUNDLE_ID (the only third-party app running)"
  elif [ "$count" -gt 1 ]; then
    log_warn "Several apps are running ($(printf '%s' "$running" | tr '\n' ' ')); set ios.bundleId in config.json to name yours. The version will come from the fallback."
  else
    log_warn "No third-party app is running on the simulator; set ios.bundleId in config.json. The version will come from the fallback."
  fi
}

# The app's "app" (bundle) or "data" container path, or nothing when the app is not installed.
sim_app_container() {
  [ -n "$IOS_BUNDLE_ID" ] || return 0
  sim_run get_app_container "$IOS_BUNDLE_ID" "$1" 2>/dev/null || true
}

# CFBundleVersion of the *installed* bundle — what the capture was actually taken against —
# else the config fallback, else 0.
ios_bundle_version() {
  local c version=""
  c="$(sim_app_container app)"
  if [ -n "$c" ] && [ -f "$c/Info.plist" ]; then
    version="$(plutil -extract CFBundleVersion raw "$c/Info.plist" 2>/dev/null || true)"
  fi
  if [ -z "$version" ]; then
    version="$(ss_version_fallback)"
    [ -n "$version" ] && log_info "Version $version from the config fallback (app not installed or not identified)"
  fi
  printf '%s\n' "${version:-0}"
}

# ---------- simulator screen ----------------------------------------------
#
# Sets IOS_SIM_NAME and IOS_SIM_SCALE (points -> pixels, e.g. 3 on an iPhone 15). The scale
# lives in the *device type's* profile.plist, not the device's own record, so it takes two
# lookups: device -> deviceTypeIdentifier -> bundlePath -> profile. Never fatal: both globals
# stay empty when anything is missing, and the converter treats the value as a cross-check.

IOS_SIM_NAME=""
IOS_SIM_SCALE=""

resolve_sim_screen() {
  IOS_SIM_NAME=""
  IOS_SIM_SCALE=""
  ss_py_resolve || return 0

  local pair
  pair="$(xcrun simctl list devices -j 2>/dev/null | ss_py -c '
import json, sys
udid = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for runtime in data.get("devices", {}).values():
    for d in runtime:
        if d.get("udid") == udid:
            print(d.get("name", ""))
            print(d.get("deviceTypeIdentifier", ""))
            break
' "$IOS_SIM_UDID" 2>/dev/null || true)"

  # shellcheck disable=SC2034  # both read by ios_smartScreenshot.sh
  IOS_SIM_NAME="$(printf '%s\n' "$pair" | sed -n '1p')"
  local type_id; type_id="$(printf '%s\n' "$pair" | sed -n '2p')"
  [ -n "$type_id" ] || return 0

  local bundle
  bundle="$(xcrun simctl list devicetypes -j 2>/dev/null | ss_py -c '
import json, sys
want = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for t in data.get("devicetypes", []):
    if t.get("identifier") == want:
        print(t.get("bundlePath", ""))
        break
' "$type_id" 2>/dev/null || true)"

  local profile="$bundle/Contents/Resources/profile.plist"
  [ -n "$bundle" ] && [ -f "$profile" ] || return 0
  # shellcheck disable=SC2034
  IOS_SIM_SCALE="$(plutil -extract mainScreenScale raw "$profile" 2>/dev/null || true)"
  return 0
}
