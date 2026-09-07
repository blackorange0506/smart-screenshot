#!/usr/bin/env bash
# annotate_server.py: serves the page and the captures, saves a sidecar with LF, blocks
# traversal and bad paths. Talks to it with Python's urllib (curl is not a given everywhere).
. "$(dirname "${BASH_SOURCE[0]//\\//}")/lib.sh"
P="$(new_project server)"
SK="$P/.claude/skills/smartScreenshot"
D="$P/shots"; mkdir -p "$D"
printf '\x89PNG\r\n\x1a\nrest' > "$D/cap.png"
printf '<hierarchy rotation="0"><node bounds="[0,0][10,10]" class="x"/></hierarchy>' > "$D/cap.xml"

PORTF="$P/port.txt"
ss_py "$SK/scripts/annotate_server.py" --shots-dir "$D" --skill-dir "$SK" --port 0 > "$PORTF" 2>"$P/server.log" &
SPID=$!
trap 'kill $SPID 2>/dev/null' EXIT
port=""
for _ in $(seq 1 300); do
  if [ -s "$PORTF" ]; then port="$(head -n1 "$PORTF" | tr -d '[:space:]')"; break; fi
  sleep 0.1
done
[ -n "$port" ] || { fail "server reported a port"; report server; exit 1; }
pass "server reported port $port"

req() { # method path [body] -> "status|body-head"
  ss_py - "http://127.0.0.1:$port$2" "$1" "${3:-}" <<'PY'
import sys, urllib.request, urllib.error
url, method, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(url, data=body.encode() if body else None, method=method)
if body: req.add_header("Content-Type", "application/json")
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        print("%d|%s" % (r.status, r.read(200).decode("utf-8", "replace").replace("\n", " ")))
except urllib.error.HTTPError as e:
    print("%d|%s" % (e.code, e.reason))
PY
}
assert_contains "GET / is the annotator" "$(req GET /)" "200|<!doctype html>"
assert_contains "GET /annotator.html" "$(req GET /annotator.html)" "smartScreenshot annotator"
assert_contains "GET a capture" "$(req GET /cap.xml)" '200|<hierarchy'
assert_contains "GET a png" "$(req GET /cap.png)" "200|"
assert_contains "GET missing -> 404" "$(req GET /nope.xml)" "404|"
assert_contains "traversal blocked" "$(req GET '/%2e%2e/port.txt')" "403|"
assert_contains "POST elsewhere -> 404" "$(req POST /other '{}')" "404|"
assert_contains "POST bad suffix -> 400" "$(req POST '/save?path=cap.json' '{"marks":[]}')" "400|"
assert_contains "POST bad json -> 400" "$(req POST '/save?path=cap.marks.json' '{nope')" "400|"
assert_contains "POST traversal -> 400" "$(req POST '/save?path=../x.marks.json' '{}')" "400|"
assert_contains "POST save ok" "$(req POST '/save?path=cap.marks.json' '{"image":"cap.png","marks":[{"id":1}]}')" '200|{"ok": true'
assert_file "sidecar written" "$D/cap.marks.json"
assert_eq "sidecar is pretty JSON with LF only" "0" "$(cr_count "$D/cap.marks.json")"
assert_contains "sidecar content" "$(cat "$D/cap.marks.json")" '"id": 1'
assert_contains "save logged" "$(cat "$P/server.log")" "saved"

kill $SPID 2>/dev/null; wait $SPID 2>/dev/null || true
trap - EXIT
report server
