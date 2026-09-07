#!/usr/bin/env bash
#
# select_smartScreenshot.sh — pick a smartScreenshot capture from the output
# directory by offset and print its existing artifact paths.
#
# Invoked by the processSmartScreenshot skill. 0 = newest, -1 = previous, -2 =
# two back, etc. (Positive numbers work the same as their negatives.)
#
# Stdout (one labelled line per existing artifact):
#   STEM=smartScreenShot_<...>
#   XML=<dir>/<stem>.xml
#   PNG=<dir>/<stem>.png
#   BOUNDS_PNG=<dir>/<stem>.bounds.png          (if --with-bounds was used)
#   TAPS_PNG=<dir>/<stem>.taps.png              (if --with-taps was used)
#   MARKS=<dir>/<stem>.marks.json               (if the standard PNG was annotated)
#   BOUNDS_MARKS=<dir>/<stem>.bounds.marks.json (if the bounds PNG was annotated)
#
# Lines for missing artifacts are omitted. The XML line is always present —
# the script keys off the existence of the .xml to define a "capture".
#
# Stderr: errors / context.
# Exit codes: 0 ok, 1 no captures / out of range, 2 bad argument.
# bash 3.2 is enough; runs on macOS, Linux and Windows (Git Bash).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]//\\//}")" && pwd)"
# shellcheck disable=SC2034  # read by config.sh's log functions
SS_LOG_TAG="processSmartScreenshot"
# shellcheck source=../../../smart-screenshot/bin/config.sh
. "$SCRIPT_DIR/../../../smart-screenshot/bin/config.sh"

print_help() {
  cat <<'HELP'
Usage: select_smartScreenshot.sh [<offset>] [-h | --help]

Pick a smartScreenshot capture from the output directory (sorted by the .xml
mtime, newest first) and print labelled paths for every existing artifact
(PNG, XML, optional bounds/taps PNGs, optional marks sidecars).

Arguments:
  <offset>          Relative position in capture history. Default: 0
                      0   (or omitted)  newest capture
                      -1                previous capture
                      -2                two captures back
                      -N                N captures back
                    Positive numbers work the same way (1 == -1).

Options:
  -h, --help        Show this help and exit.

Environment variables:
  SMART_SCREENSHOT_DIR  Directory to look in. Default: config outputDir,
                        else <project>/smartScreenShot

Exit codes:
  0  success — labelled paths printed on stdout
  1  no captures / no folder / offset out of range
  2  bad argument

Examples:
  select_smartScreenshot.sh                # latest capture
  select_smartScreenshot.sh -1             # previous
  select_smartScreenshot.sh -3             # three captures back
HELP
}

case "${1:-}" in
  -h|--help) print_help; exit 0 ;;
esac

ARG="${1:-0}"
DIR="$(ss_output_dir)"

# Normalize: strip a leading '-' or '+' so "-1" and "1" are the same offset.
OFFSET="${ARG#-}"
OFFSET="${OFFSET#+}"

if ! [[ "$OFFSET" =~ ^[0-9]+$ ]]; then
  log_error "offset must be an integer (e.g. 0, -1, -2). Got: $ARG"
  exit 2
fi

if [[ ! -d "$DIR" ]]; then
  log_error "$DIR not found. Run /smartScreenshot first to capture one."
  exit 1
fi

# A "capture" is keyed by its .xml — there's exactly one XML per capture even
# when --with-bounds / --with-taps add extra PNG variants.
shopt -s nullglob
xmls=("$DIR"/*.xml)
shopt -u nullglob

if [[ ${#xmls[@]} -eq 0 ]]; then
  log_error "No .xml captures in $DIR. Run /smartScreenshot first."
  exit 1
fi

# Sort by mtime, newest first (ls -t works on BSD, GNU and Git Bash). A while-read
# loop rather than mapfile, which macOS's /bin/bash 3.2 lacks.
XMLS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && XMLS+=("$line")
done < <(ls -1t -- "${xmls[@]}")

if (( OFFSET >= ${#XMLS[@]} )); then
  log_error "Offset $ARG is too far back. Only ${#XMLS[@]} capture(s) available:"
  for ((i=0; i<${#XMLS[@]}; i++)); do
    label=$(( i == 0 ? 0 : -i ))
    printf '  %3d  %s\n' "$label" "$(basename "${XMLS[$i]}")" >&2
  done
  exit 1
fi

XML="${XMLS[$OFFSET]}"
STEM_BASE="$(basename "$XML" .xml)"
STEM_DIR="$(dirname "$XML")"

log_info "Selected capture (offset $ARG): $STEM_BASE"

# Print STEM + every existing artifact, one per line, label=path.
printf 'STEM=%s\n' "$STEM_BASE"
printf 'XML=%s\n' "$XML"
[[ -f "$STEM_DIR/$STEM_BASE.png"               ]] && printf 'PNG=%s\n'          "$STEM_DIR/$STEM_BASE.png"
[[ -f "$STEM_DIR/$STEM_BASE.bounds.png"        ]] && printf 'BOUNDS_PNG=%s\n'   "$STEM_DIR/$STEM_BASE.bounds.png"
[[ -f "$STEM_DIR/$STEM_BASE.taps.png"          ]] && printf 'TAPS_PNG=%s\n'     "$STEM_DIR/$STEM_BASE.taps.png"
[[ -f "$STEM_DIR/$STEM_BASE.marks.json"        ]] && printf 'MARKS=%s\n'        "$STEM_DIR/$STEM_BASE.marks.json"
[[ -f "$STEM_DIR/$STEM_BASE.bounds.marks.json" ]] && printf 'BOUNDS_MARKS=%s\n' "$STEM_DIR/$STEM_BASE.bounds.marks.json"
exit 0
