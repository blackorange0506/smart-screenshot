#!/usr/bin/env bash
# /smartScreenshot --ios — capture the current iOS simulator screen as a paired
# PNG + uiautomator-shaped XML hierarchy, filed alongside the Android captures
# with the same date+time+version+commit-slug stem. macOS only.
#
# A separate script rather than a branch inside smartScreenshot.sh because none
# of this is adb, and because the Android script's cleanup trap (setprop,
# settings put) has no business running here. smartScreenshot.sh exec's this file.
#
# Two things a reader will want to know up front:
#
#   * The hierarchy comes from Maestro, not from a first-party tool, because
#     there is none: xcrun simctl has no accessibility or hierarchy command
#     (`io` offers only enumerate, poll, recordVideo and screenshot). Maestro
#     drives the simulator through a bundled XCTest driver.
#   * Maestro reports every frame in points while the screenshot is in pixels
#     (iPhone 15: 393x852 vs 1179x2556). maestro_to_uiautomator.py rescales, and
#     records the scale it used in the XML root.
#
# Stdout (machine-readable, in capture order):
#   <abs-path-to-png>           (always)
#   <abs-path-to-xml>           <- final line; primary artifact for tooling.
# All log/info goes to stderr, so `| tail -1` is the XML on both platforms.
#
# Settings: .claude/smart-screenshot/config.json (ios.bundleId, ios.simulators,
# ios.maestroBin, ios.hierarchyTimeout, outputDir, version.*, annotator.port).
# Environment overrides, all optional:
#   SMART_SCREENSHOT_IOS_SIM        Pre-select a simulator by name or udid.
#   SMART_SCREENSHOT_IOS_BUNDLE_ID  The app's bundle id (default: config, else the
#                                   one third-party app the simulator is running).
#   MAESTRO_BIN                     Path to the maestro CLI (default: config, then
#                                   ~/.maestro/bin/maestro, then PATH).
#   SMART_SCREENSHOT_DIR            Output directory.
#   SMART_SCREENSHOT_PREFIX         Filename stem prefix (default: smartScreenShot_ios).
#   SMART_SCREENSHOT_PORT           Preferred annotator port (default: random free).
#   SMART_SCREENSHOT_IOS_TIMEOUT    Seconds to allow the first hierarchy dump (default: 90).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")" && pwd)"
# shellcheck source=../../../smart-screenshot/lib/ios-lib.sh
. "$SCRIPT_DIR/../../../smart-screenshot/lib/ios-lib.sh"
# shellcheck source=launch_annotator.sh
. "$SCRIPT_DIR/launch_annotator.sh"

print_help() {
  cat <<'HELP'
Usage: ios_smartScreenshot.sh [-h | --help] [--no-annotate]

Capture the current iOS simulator screen as a PNG + a uiautomator-shaped XML
hierarchy under the output directory. Both files share one stem. Normally
reached as `smartScreenshot.sh --ios`. macOS only.

The hierarchy is produced by `maestro hierarchy` and converted, because simctl
has no accessibility/hierarchy command of any kind. resource-id carries the
element's accessibility identifier — for a Compose Multiplatform app that is
its Modifier.testTag, exactly as on Android.

By default the annotator launches automatically on the captured PNG. Pass
--no-annotate to suppress it for non-interactive pipelines.

Options:
  -h, --help        Show this help and exit.
  --no-annotate     Skip the annotator (just save the files and exit).

Not available on iOS (each is a hard error, not a silent skip):
  --with-bounds     There is no Show Layout Bounds on iOS.
  --with-taps       There is no Show Taps on iOS.
  --annotate        Means "annotate the bounds variant", which cannot exist here.

Settings: .claude/smart-screenshot/config.json (ios.bundleId, ios.simulators,
ios.maestroBin, ios.hierarchyTimeout). Environment overrides (all optional):
  SMART_SCREENSHOT_IOS_SIM        Pre-select a simulator by name or udid.
  SMART_SCREENSHOT_IOS_BUNDLE_ID  The app's bundle id.
  MAESTRO_BIN                     Path to the maestro CLI.
  SMART_SCREENSHOT_DIR            Output directory.
  SMART_SCREENSHOT_PREFIX         Filename stem prefix.
  SMART_SCREENSHOT_PORT           Preferred annotator port.
  SMART_SCREENSHOT_IOS_TIMEOUT    Seconds allowed for the first hierarchy dump.

Output filename pattern:
  smartScreenShot_ios_<YYYY-MM-DD>_<HHMMSS>_v<CFBundleVersion>_<commit-slug>.{png,xml}

The _ios infix matters: both platforms file into one folder and the capture
selector orders purely by mtime, so without it "the latest capture" would be a
coin flip between platforms.
HELP
}

# ---- Step 0: arguments ---------------------------------------------------
#
# All validation happens before any device work, so a rejected flag can never
# leave a simulator booted behind it.

ANNOTATE=1
for arg in "$@"; do
  case "$arg" in
    -h|--help)     print_help; exit 0 ;;
    --no-annotate) ANNOTATE=0 ;;
    --with-bounds)
      die "--with-bounds has no iOS equivalent (there is no Show Layout Bounds on iOS). Drop the flag, or use --android." ;;
    --with-taps)
      die "--with-taps has no iOS equivalent (there is no Show Taps on iOS). Drop the flag, or use --android." ;;
    --annotate)
      die "--annotate means 'annotate the bounds variant', which iOS cannot produce. Omit it — the annotator runs on the standard PNG by default." ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# ---- Step 0b: preflight --------------------------------------------------

is_macos || die "iOS captures need macOS (xcrun simctl). On this machine only --android is available."

MAESTRO_BIN="${MAESTRO_BIN:-$(config_get '.ios.maestroBin' '')}"
[[ -n "$MAESTRO_BIN" ]] || MAESTRO_BIN="$HOME/.maestro/bin/maestro"
if [[ ! -x "$MAESTRO_BIN" ]]; then
  MAESTRO_BIN="$(command -v maestro 2>/dev/null || true)"
fi
[[ -n "$MAESTRO_BIN" && -x "$MAESTRO_BIN" ]] || die \
  "maestro not found. It is the only way to read an iOS view hierarchy (simctl has no such command). Install it with: curl -Ls https://get.maestro.mobile.dev | bash — or set ios.maestroBin in config.json / MAESTRO_BIN."

# maestro is a Gradle start script, so a missing JVM fails inside it with a
# message about java rather than about maestro.
command -v java >/dev/null 2>&1 || [[ -n "${JAVA_HOME:-}" ]] || die \
  "java not found on PATH and JAVA_HOME is unset; the maestro CLI needs a JVM."

ss_py_resolve || die "Python 3 not found (tried python3, python, py -3); it converts Maestro's JSON and runs the annotator."

CONVERTER="$SCRIPT_DIR/maestro_to_uiautomator.py"
[[ -f "$CONVERTER" ]] || die "Cannot find maestro_to_uiautomator.py at $CONVERTER"

# ---- Step 0c: output dir + cleanup ---------------------------------------

OUT_DIR="$(ss_output_dir)"

# Unlike the Android script there is nothing on the device to restore, so this
# only reaps the annotator and the temp files.
SERVER_PID=""
TMP_PORT_FILE=""
TMP_JSON=""
TMP_ERR=""

cleanup() {
  local rc=$?
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$TMP_PORT_FILE" "$TMP_JSON" "$TMP_ERR" 2>/dev/null || true
  return "$rc"
}
trap cleanup EXIT INT TERM

# ---- Step 1: pick the simulator + the app --------------------------------

require_xcode
select_simulator
resolve_sim_screen
log_info "Simulator: ${IOS_SIM_NAME:-unknown} ($IOS_SIM_UDID)${IOS_SIM_SCALE:+, screen scale $IOS_SIM_SCALE}"
select_bundle_id

# ---- Step 2: version, slug, stem -----------------------------------------

VERSION_CODE="$(ios_bundle_version)"
log_info "Version: $VERSION_CODE"
SLUG="$(ss_commit_slug)"

mkdir -p "$OUT_DIR"
ss_pick_stem "$OUT_DIR" "${SMART_SCREENSHOT_PREFIX:-smartScreenShot_ios}" "$VERSION_CODE" "$SLUG"
PNG_OUT="$OUT_DIR/$SS_STEM.png"
XML_OUT="$OUT_DIR/$SS_STEM.xml"

# ---- Step 3: bounded command runner --------------------------------------
#
# macOS has no timeout(1), and a hung XCTest driver otherwise hangs the capture
# with no output at all. The backgrounded job is a shell function, so $pid is a
# subshell whose child is the JVM; the children go first, then the wrapper.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  local waited=0 limit=$(( secs * 10 ))
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# ---- Step 4: hierarchy ---------------------------------------------------
#
# Order matters: the hierarchy is taken first, the PNG second, the conversion
# last — the converter needs the PNG's pixel dimensions to work out the
# point->pixel scale. It also means the screenshot happens after any driver
# activity has settled, so a cold run can't catch a flash of the XCTest runner.

TMP_JSON="$(mktemp)"
TMP_ERR="$(mktemp)"
IOS_TIMEOUT="${SMART_SCREENSHOT_IOS_TIMEOUT:-$(config_get '.ios.hierarchyTimeout' 90)}"
case "$IOS_TIMEOUT" in ''|*[!0-9]*) IOS_TIMEOUT=90 ;; esac

maestro_hierarchy() {
  # Global options must precede the subcommand (picocli): --platform and --udid
  # live on the CLI, only --reinstall-driver lives on `hierarchy`. --udid pins
  # the simulator ios-lib chose. --no-reinstall-driver is the difference between
  # ~5s and ~40s: the flag defaults to *true*, so without it every capture
  # reinstalls the XCTest driver. Maestro still installs it when absent.
  MAESTRO_CLI_NO_ANALYTICS=1 "$MAESTRO_BIN" \
      --no-ansi --platform ios --udid "$IOS_SIM_UDID" \
      hierarchy "$@"
}

log_info "Dumping UI hierarchy via maestro → $XML_OUT"
log_info "  (a cold run installs Maestro's XCTest driver on the simulator — that can take a minute)"

XML_OK=1
if ! run_with_timeout "$IOS_TIMEOUT" maestro_hierarchy --no-reinstall-driver \
        > "$TMP_JSON" 2> "$TMP_ERR"; then
  # A stale or half-installed driver is exactly what this looks like, and a
  # forced reinstall is exactly its cure — so pay the cost once, on failure.
  log_warn "maestro hierarchy failed or timed out; retrying with a driver reinstall…"
  if ! run_with_timeout $(( IOS_TIMEOUT * 2 )) maestro_hierarchy \
          > "$TMP_JSON" 2> "$TMP_ERR"; then
    XML_OK=0
    log_error "maestro hierarchy failed. Last output:"
    tail -5 "$TMP_ERR" >&2 || true
  fi
fi

# ---- Step 5: PNG ---------------------------------------------------------

capture_png() {
  local out="$1"
  log_info "Capturing screenshot → $out"
  if ! sim_run io screenshot "$out" >/dev/null 2>&1; then
    log_error "screenshot failed on $IOS_SIM_UDID."
    rm -f "$out"; echo 0; return
  fi
  if ! ss_png_ok "$out"; then
    log_error "screenshot is empty or not a PNG."
    rm -f "$out"; echo 0; return
  fi
  log_info "PNG saved ($(du -h "$out" | cut -f1))"
  echo 1
}

PNG_OK="$(capture_png "$PNG_OUT")"

# ---- Step 6: convert + validate ------------------------------------------

if (( XML_OK )); then
  CONVERT_ARGS=(--json "$TMP_JSON" --out "$XML_OUT"
                --package "$IOS_BUNDLE_ID"
                --device-name "${IOS_SIM_NAME:-}" --device-udid "$IOS_SIM_UDID")
  (( PNG_OK )) && CONVERT_ARGS+=(--png "$PNG_OUT")
  [[ -n "${IOS_SIM_SCALE:-}" ]] && CONVERT_ARGS+=(--fallback-scale "$IOS_SIM_SCALE")

  if ! ss_py "$CONVERTER" "${CONVERT_ARGS[@]}"; then
    XML_OK=0
    log_error "Converting Maestro's hierarchy to XML failed."
  fi
fi

if (( XML_OK )) && ! ss_xml_ok "$XML_OUT"; then
  XML_OK=0
  log_error "XML dump is empty, malformed or has no <hierarchy> root."
fi

# A bad XML is deleted rather than left to be read as a capture — same rule the
# Android path applies to a failed uiautomator dump.
(( XML_OK )) || rm -f "$XML_OUT"

# ---- Step 7: report ------------------------------------------------------

CAPTURE_OK=0
if (( PNG_OK )) && (( XML_OK )); then
  CAPTURE_OK=1
fi

(( PNG_OK )) && printf '%s\n' "$PNG_OUT"
(( XML_OK )) && printf '%s\n' "$XML_OUT"

log_info "Captured artifacts:"
(( PNG_OK )) && log_info "  PNG: $PNG_OUT"
(( XML_OK )) && log_info "  XML: $XML_OUT"

if ! (( CAPTURE_OK )); then
  if (( PNG_OK )); then log_warn "PNG saved but XML failed."
  elif (( XML_OK )); then log_warn "XML saved but PNG failed."
  else log_error "Both PNG and XML failed."
  fi
fi

# ---- Step 8 (optional): launch annotator ---------------------------------

if (( ANNOTATE )) && (( CAPTURE_OK )); then
  SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  launch_annotator "$PNG_OUT" "$XML_OUT" "$OUT_DIR" "$SKILL_DIR"
  exit 0
fi

(( CAPTURE_OK )) || exit 1
exit 0
