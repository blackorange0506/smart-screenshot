#!/usr/bin/env bash
# shellcheck shell=bash
# The annotator half of /smartScreenshot, shared by the Android and iOS capture
# scripts.
#
# Source it, don't run it:
#   . "$SCRIPT_DIR/launch_annotator.sh"
#   launch_annotator "$PNG" "$XML" "$OUT_DIR" "$SKILL_DIR"
#
# Sourced rather than exec'd for one specific reason: it starts a background
# server and must leave SERVER_PID and TMP_PORT_FILE in the *caller's* scope, so
# the caller's own cleanup trap keeps killing the server and removing the port
# file. Both platform scripts declare those two variables before arming their
# trap; this function only fills them in.
#
# It blocks on `wait` until the user Ctrl+Cs the server, which is why every
# non-interactive caller passes --no-annotate instead.
#
# Needs the helpers from bin/config.sh (ss_py, ss_open_url, config_get, log_*),
# which both capture scripts have already sourced through their platform lib.

# launch_annotator <png> <xml> <shots-dir> <skill-dir>
launch_annotator() {
  local annotate_png="$1" xml_out="$2" out_dir="$3" skill_dir="$4"

  ss_py_resolve || die "Python 3 not found (tried python3, python, py -3); cannot launch the annotator."

  local shots_abs png_base xml_base port_pref
  shots_abs="$(cd "$out_dir" && pwd)"
  png_base="$(basename "$annotate_png")"
  xml_base="$(basename "$xml_out")"
  port_pref="${SMART_SCREENSHOT_PORT:-$(config_get '.annotator.port' 0)}"
  case "$port_pref" in ''|*[!0-9]*) port_pref=0 ;; esac

  log_info "Launching annotator (Ctrl+C to stop server when done)…"
  TMP_PORT_FILE="$(mktemp)"
  ss_py "$skill_dir/scripts/annotate_server.py" \
      --shots-dir "$shots_abs" \
      --skill-dir "$skill_dir" \
      --port "$port_pref" > "$TMP_PORT_FILE" &
  SERVER_PID=$!

  # Wait for the server to print its port — up to 30 s, since a cold Python start on a slow
  # machine can take several seconds; it returns as soon as the port is there.
  local port="" i=0
  while [[ $i -lt 150 ]]; do
    i=$((i + 1))
    if [[ -s "$TMP_PORT_FILE" ]]; then
      port="$(head -n1 "$TMP_PORT_FILE" | tr -d '[:space:]')"
      [[ "$port" =~ ^[0-9]+$ ]] && break
      port=""
    fi
    sleep 0.2
  done
  [[ -n "$port" ]] || die "annotator server didn't report a port in time"

  local url
  url="http://127.0.0.1:${port}/annotator.html?image=$(printf %s "$png_base" | sed 's/ /%20/g')&xml=$(printf %s "$xml_base" | sed 's/ /%20/g')"
  log_info "Annotator URL: $url"
  log_info "Sidecar will be saved to: $out_dir/${png_base%.png}.marks.json"
  ss_open_url "$url" || log_warn "Could not open a browser; open the URL above manually."
  log_info "Press Ctrl+C in this terminal when finished annotating."
  wait "$SERVER_PID" || true
}
