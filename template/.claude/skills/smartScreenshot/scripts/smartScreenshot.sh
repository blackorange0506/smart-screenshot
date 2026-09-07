#!/usr/bin/env bash
# /smartScreenshot — capture the current app screen as a paired PNG screenshot +
# uiautomator XML hierarchy dump. Both files share one stem under the output
# directory (default <project>/smartScreenShot/), named date+time+version+commit-slug.
#
# Android by default; --ios exec's ios_smartScreenshot.sh, which produces the
# same two artifacts (via maestro + maestro_to_uiautomator.py) under an
# _ios-infixed stem. The stdout contract below is identical on both platforms,
# minus the two overlay variants, which are Android-only.
#
# Optional --with-bounds / --with-taps flags add an extra PNG variant per
# overlay; the standard PNG is always captured first.
#
# Stdout (machine-readable, in capture order):
#   <abs-path-to-png>           (always)
#   <abs-path-to-bounds-png>    (only with --with-bounds)
#   <abs-path-to-taps-png>      (only with --with-taps)
#   <abs-path-to-xml>           <- final line; primary artifact for tooling.
# All log/info goes to stderr.
#
# Project settings live in .claude/smart-screenshot/config.json (android.package,
# android.packages, android.deviceSerial, android.deviceHost, outputDir, version.*,
# annotator.port). Environment overrides, all optional:
#   SMART_SCREENSHOT_PACKAGE        The app whose versionCode names the capture.
#   SMART_SCREENSHOT_DEVICE_SERIAL  Pre-select an adb device (ANDROID_SERIAL works too).
#   SMART_SCREENSHOT_DEVICE_HOST    <ip>:<port> for wireless adb recovery.
#   SMART_SCREENSHOT_DIR            Output directory.
#   SMART_SCREENSHOT_PREFIX         Filename stem prefix (default: smartScreenShot).
#   SMART_SCREENSHOT_PORT           Preferred annotator port (default: random free).
#
# Runs on macOS, Linux and Windows (Git Bash) — anywhere adb runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")" && pwd)"
# shellcheck source=../../../smart-screenshot/lib/adb-lib.sh
. "$SCRIPT_DIR/../../../smart-screenshot/lib/adb-lib.sh"
# shellcheck source=launch_annotator.sh
. "$SCRIPT_DIR/launch_annotator.sh"

print_help() {
  cat <<'HELP'
Usage: smartScreenshot.sh [-h | --help]
       smartScreenshot.sh [--android] [--no-annotate] [--with-bounds] [--with-taps]
       smartScreenshot.sh --android --annotate [--with-taps]
       smartScreenshot.sh --ios [--no-annotate]

Capture the current app screen as PNG(s) + an XML hierarchy dump under the
output directory (default <project>/smartScreenShot/). All files share one stem.

By default the annotator launches automatically on the standard PNG (regardless
of whether stdout is a terminal). Pass --no-annotate to suppress it for
non-interactive pipelines.

Platform (--android is the default; the last platform flag wins):
  --android                Capture from a connected Android device via adb +
                           uiautomator. Everything below applies.
  --ios                    Capture from an iOS simulator instead (macOS only),
                           via simctl + `maestro hierarchy` converted to the
                           same XML shape. Needs maestro installed.
                           --with-bounds, --with-taps and --annotate are hard
                           errors there: iOS has no Show Layout Bounds and no
                           Show Taps. `smartScreenshot.sh --ios --help` has
                           the rest.

Options:
  -h, --help               Show this help and exit.
  --no-annotate            Skip the annotator (just save the files and exit).
                           Useful when piping output to another tool.
  --annotate               Annotate the BOUNDS variant instead of the standard
                           PNG. Implies --with-bounds. Marks save to
                           <stem>.bounds.marks.json so they can coexist with
                           any existing <stem>.marks.json.
  --with-bounds            Also capture <stem>.bounds.png with Show Layout
                           Bounds enabled. Prior device state restored on exit.
  --with-taps              Also capture <stem>.taps.png with Show Taps enabled.
                           Tap circles only render while a finger is on the
                           screen — touch during the "Capturing taps…" log
                           line to see them.

Settings: .claude/smart-screenshot/config.json (android.package, android.packages,
android.deviceSerial, android.deviceHost, outputDir, version.file + version.regex,
annotator.port). Environment overrides (all optional):
  SMART_SCREENSHOT_PACKAGE        The app whose versionCode names the capture.
                                  Default: config, else the foreground app.
  SMART_SCREENSHOT_DEVICE_SERIAL  Pre-select an adb device (or ANDROID_SERIAL).
  SMART_SCREENSHOT_DEVICE_HOST    <ip>:<port> for wireless adb recovery.
  SMART_SCREENSHOT_DIR            Output directory.
  SMART_SCREENSHOT_PREFIX         Filename stem prefix (default: smartScreenShot,
                                  or smartScreenShot_ios under --ios).
  SMART_SCREENSHOT_PORT           Preferred annotator port (default: random free).

Output filename pattern (variants only when their flag is passed):
  smartScreenShot_<YYYY-MM-DD>_<HHMMSS>_v<versionCode>_<commit-slug>.png
  smartScreenShot_<YYYY-MM-DD>_<HHMMSS>_v<versionCode>_<commit-slug>.bounds.png
  smartScreenShot_<YYYY-MM-DD>_<HHMMSS>_v<versionCode>_<commit-slug>.taps.png
  smartScreenShot_<YYYY-MM-DD>_<HHMMSS>_v<versionCode>_<commit-slug>.xml

Under --ios, with an _ios infix so the two platforms stay apart in one folder:
  smartScreenShot_ios_<YYYY-MM-DD>_<HHMMSS>_v<CFBundleVersion>_<commit-slug>.png
  smartScreenShot_ios_<YYYY-MM-DD>_<HHMMSS>_v<CFBundleVersion>_<commit-slug>.xml
HELP
}

# Default: annotator on. Pass --no-annotate to skip. Last-conflicting-flag wins.
ANNOTATE=1
ANNOTATE_TARGET="standard"   # "standard" | "bounds"
WITH_BOUNDS=0
WITH_TAPS=0
PLATFORM="android"           # --android is the default; last platform flag wins
WANT_HELP=0
PASSTHROUGH=()
for arg in "$@"; do
  case "$arg" in
    # Deferred rather than acted on here, so `--ios --help` prints the iOS help
    # instead of whichever help the loop happened to reach first.
    -h|--help)         WANT_HELP=1 ;;
    --ios)             PLATFORM="ios" ;;
    --android)         PLATFORM="android" ;;
    --no-annotate)     ANNOTATE=0; PASSTHROUGH+=("$arg") ;;
    --annotate)        ANNOTATE=1; ANNOTATE_TARGET="bounds"; WITH_BOUNDS=1; PASSTHROUGH+=("$arg") ;;
    --with-bounds)     WITH_BOUNDS=1; PASSTHROUGH+=("$arg") ;;
    --with-taps)       WITH_TAPS=1; PASSTHROUGH+=("$arg") ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# The iOS capture is a separate script because none of it is adb. exec'ing rather
# than sourcing hands over before the Android-only cleanup trap is armed and
# before bootstrap_device_and_pkg would demand an adb device.
if [[ "$PLATFORM" == "ios" ]]; then
  IOS_SCRIPT="$SCRIPT_DIR/ios_smartScreenshot.sh"
  [[ -f "$IOS_SCRIPT" ]] || die "Cannot find ios_smartScreenshot.sh at $IOS_SCRIPT"
  if (( WANT_HELP )); then exec bash "$IOS_SCRIPT" --help; fi
  exec bash "$IOS_SCRIPT" "${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}"
fi

if (( WANT_HELP )); then print_help; exit 0; fi

OUT_DIR="$(ss_output_dir)"

# State carried into cleanup(). Initialized before the trap is armed so an
# early failure can't reference unset vars under `set -u`.
PRIOR_BOUNDS=""
PRIOR_TAPS=""
SERVER_PID=""
TMP_PORT_FILE=""

cleanup() {
  local rc=$?
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  [[ -n "$TMP_PORT_FILE" ]] && rm -f "$TMP_PORT_FILE"
  if (( WITH_BOUNDS )) && [[ -n "${ADB_SERIAL:-}" ]]; then
    case "$PRIOR_BOUNDS" in
      true) adb_shell setprop debug.layout true  >/dev/null 2>&1 || true ;;
      *)    adb_shell setprop debug.layout false >/dev/null 2>&1 || true ;;
    esac
    adb_shell service call activity 1599295570 >/dev/null 2>&1 || true
  fi
  if (( WITH_TAPS )) && [[ -n "${ADB_SERIAL:-}" ]]; then
    case "$PRIOR_TAPS" in
      1) adb_shell settings put system show_touches 1 >/dev/null 2>&1 || true ;;
      *) adb_shell settings put system show_touches 0 >/dev/null 2>&1 || true ;;
    esac
  fi
  return "$rc"
}
trap cleanup EXIT INT TERM

# ---- Step 1: pick device + package ---------------------------------------

bootstrap_device_and_pkg

# ---- Step 1b: read prior overlay state ------------------------------------

if (( WITH_BOUNDS )); then
  PRIOR_BOUNDS="$(adb_shell getprop debug.layout 2>/dev/null | tr -d '\r')"
  log_info "Show Layout Bounds prior state: ${PRIOR_BOUNDS:-unset}"
fi
if (( WITH_TAPS )); then
  PRIOR_TAPS="$(adb_shell settings get system show_touches 2>/dev/null | tr -d '\r')"
  log_info "Show Taps prior state: ${PRIOR_TAPS:-unset}"
fi

# ---- Step 2: version, slug, stem -----------------------------------------

VERSION_CODE="$(android_version_code)"
log_info "Version: $VERSION_CODE"
SLUG="$(ss_commit_slug)"

mkdir -p "$OUT_DIR"
ss_pick_stem "$OUT_DIR" "${SMART_SCREENSHOT_PREFIX:-smartScreenShot}" "$VERSION_CODE" "$SLUG"
PNG_OUT="$OUT_DIR/$SS_STEM.png"
XML_OUT="$OUT_DIR/$SS_STEM.xml"
BOUNDS_PNG_OUT="$OUT_DIR/$SS_STEM.bounds.png"
TAPS_PNG_OUT="$OUT_DIR/$SS_STEM.taps.png"

# ---- Step 3: PNG capture function ---------------------------------------

# capture_png <out_path> <label>  -> echoes "1" on success, "0" on failure.
# Validates non-empty + PNG signature; deletes the file on failure.
capture_png() {
  local out="$1" label="$2"
  log_info "Capturing $label → $out"
  if ! adb_run exec-out screencap -p > "$out"; then
    log_error "$label: screencap failed (adb exec-out returned non-zero)."
    rm -f "$out"; echo 0; return
  fi
  if ! ss_png_ok "$out"; then
    log_error "$label: the pulled file is empty or not a PNG — capture is corrupt: $out"
    rm -f "$out"; echo 0; return
  fi
  log_info "$label PNG saved ($(du -h "$out" | cut -f1))"
  echo 1
}

# 3a. Standard PNG (always; clean baseline taken before any overlay change).
PNG_OK="$(capture_png "$PNG_OUT" "standard")"

# 3b. Bounds variant.
BOUNDS_OK=0
if (( WITH_BOUNDS )); then
  log_info "Enabling Show Layout Bounds for bounds capture"
  adb_shell setprop debug.layout true >/dev/null 2>&1 || log_warn "Failed to set debug.layout"
  adb_shell service call activity 1599295570 >/dev/null 2>&1 || true
  sleep 0.4
  BOUNDS_OK="$(capture_png "$BOUNDS_PNG_OUT" "bounds")"
fi

# 3c. Taps variant.
TAPS_OK=0
if (( WITH_TAPS )); then
  log_info "Enabling Show Taps for taps capture (touch the screen NOW to see circles)"
  adb_shell settings put system show_touches 1 >/dev/null 2>&1 || log_warn "Failed to set show_touches"
  sleep 0.4
  TAPS_OK="$(capture_png "$TAPS_PNG_OUT" "taps")"
fi

# ---- Step 4: capture uiautomator XML -------------------------------------
# Overlays don't affect uiautomator dump (it reads the view tree, not pixels).

log_info "Dumping UI hierarchy → $XML_OUT"
DEVICE_DUMP="/sdcard/window_dump.xml"
XML_OK=1

if ! adb_shell uiautomator dump "$DEVICE_DUMP" >/dev/null 2>&1; then
  XML_OK=0
  log_error "uiautomator dump failed on device. Some surfaces (Android Auto, secure windows) block this."
fi
if (( XML_OK )); then
  if ! adb_run exec-out cat "$DEVICE_DUMP" > "$XML_OUT"; then
    XML_OK=0
    log_error "Failed to pull $DEVICE_DUMP from device."
  fi
fi
adb_shell rm -f "$DEVICE_DUMP" >/dev/null 2>&1 || true

if (( XML_OK )) && ! ss_xml_ok "$XML_OUT"; then
  XML_OK=0
  log_error "Pulled XML is empty, malformed or has no <hierarchy> root: $XML_OUT"
fi
if (( XML_OK )); then
  log_info "XML saved ($(du -h "$XML_OUT" | cut -f1))"
else
  rm -f "$XML_OUT"
fi

# ---- Step 5: report ------------------------------------------------------

CAPTURE_OK=0
if (( PNG_OK )) && (( XML_OK )); then
  CAPTURE_OK=1
fi

# Capture-order stdout: standard, bounds, taps, xml (xml always last).
(( PNG_OK ))    && printf '%s\n' "$PNG_OUT"
(( BOUNDS_OK )) && printf '%s\n' "$BOUNDS_PNG_OUT"
(( TAPS_OK ))   && printf '%s\n' "$TAPS_PNG_OUT"
(( XML_OK ))    && printf '%s\n' "$XML_OUT"

log_info "Captured artifacts:"
(( PNG_OK ))    && log_info "  PNG: $PNG_OUT"
(( BOUNDS_OK )) && log_info "  bounds PNG: $BOUNDS_PNG_OUT"
(( TAPS_OK ))   && log_info "  taps PNG: $TAPS_PNG_OUT"
(( XML_OK ))    && log_info "  XML: $XML_OUT"

if ! (( CAPTURE_OK )); then
  if (( PNG_OK )); then log_warn "Standard PNG saved but XML failed."
  elif (( XML_OK )); then log_warn "XML saved but standard PNG failed."
  else log_error "Both standard PNG and XML failed."
  fi
fi
if (( WITH_BOUNDS )) && ! (( BOUNDS_OK )); then log_warn "Bounds variant requested but capture failed."; fi
if (( WITH_TAPS ))   && ! (( TAPS_OK ));   then log_warn "Taps variant requested but capture failed."; fi

# ---- Step 6 (optional): launch annotator --------------------------------

if (( ANNOTATE )) && (( CAPTURE_OK )); then
  SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
  # Choose target PNG based on --annotate; fall back if bounds missing.
  if [[ "$ANNOTATE_TARGET" == "bounds" ]] && (( BOUNDS_OK )); then
    ANNOTATE_PNG="$BOUNDS_PNG_OUT"
    log_info "Annotating bounds variant"
  else
    if [[ "$ANNOTATE_TARGET" == "bounds" ]]; then
      log_warn "Bounds capture missing — falling back to standard PNG for annotation"
    fi
    ANNOTATE_PNG="$PNG_OUT"
  fi

  launch_annotator "$ANNOTATE_PNG" "$XML_OUT" "$OUT_DIR" "$SKILL_DIR"
  exit 0
fi

(( CAPTURE_OK )) || exit 1
exit 0
