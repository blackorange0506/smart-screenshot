#!/usr/bin/env python3
"""Tiny annotation server for the /smartScreenshot annotator.

Serves a directory (the capture folder + the skill's annotator.html)
and accepts POST /save?path=<basename>.marks.json with a JSON body that gets
written into the capture folder. Logs every save and every fatal
error to stderr; runs until SIGINT / SIGTERM.

Usage:
  annotate_server.py --shots-dir SHOTS --skill-dir SKILL [--port 0]

The server exposes:
  GET  /annotator.html                -> served from --skill-dir
  GET  /<anything-else>                -> served from --shots-dir
  POST /save?path=<basename>           -> writes the JSON body into shots-dir/<basename>
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import socket
import sys
import urllib.parse
from pathlib import Path


def log(msg: str) -> None:
    sys.stderr.write(f"[annotate-server] {msg}\n")
    sys.stderr.flush()


class Handler(http.server.SimpleHTTPRequestHandler):
    # Set in main(); read via class attributes.
    shots_dir: Path
    skill_dir: Path

    def log_message(self, fmt: str, *args) -> None:
        # Quiet the default per-request access log; we log saves explicitly.
        return

    # ----- routing helpers -----

    def _serve_file(self, path: Path) -> None:
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            self.send_error(404, f"not found: {path.name}")
            return
        ext = path.suffix.lower()
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".png": "image/png",
            ".xml": "application/xml; charset=utf-8",
            ".json": "application/json; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
        }.get(ext, "application/octet-stream")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _safe_resolve(self, base: Path, name: str) -> Path | None:
        """Resolve `name` under `base`, refusing path traversal."""
        # Strip query/leading slash; `name` is already URL-decoded.
        candidate = (base / name).resolve()
        try:
            candidate.relative_to(base.resolve())
        except ValueError:
            return None
        return candidate

    # ----- HTTP methods -----

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        # Decode percent-encoded path so files like
        # smartScreenShot_2026-05-07_192033_v187_Add-format.png work whether
        # the browser leaves the name plain or URL-encodes it.
        name = urllib.parse.unquote(parsed.path.lstrip("/"))
        if name == "" or name == "annotator.html":
            self._serve_file(self.skill_dir / "annotator.html")
            return
        target = self._safe_resolve(self.shots_dir, name)
        if target is None:
            self.send_error(403, "path traversal blocked")
            return
        self._serve_file(target)

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/save":
            self.send_error(404, "unknown endpoint")
            return
        qs = urllib.parse.parse_qs(parsed.query)
        path_param = (qs.get("path") or [""])[0]
        if not path_param or "/" in path_param or path_param.startswith("."):
            self.send_error(400, "missing or unsafe ?path=")
            return
        if not path_param.endswith(".marks.json"):
            self.send_error(400, "?path= must end with .marks.json")
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 5_000_000:
            self.send_error(400, "empty or oversized body")
            return
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as e:
            self.send_error(400, f"invalid JSON: {e}")
            return

        target = self._safe_resolve(self.shots_dir, path_param)
        if target is None:
            self.send_error(403, "path traversal blocked")
            return

        target.parent.mkdir(parents=True, exist_ok=True)
        # Pretty-print so the file is readable / greppable.
        # newline="\n": Windows Python would otherwise write CR LF.
        with open(target, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
        n_marks = len(payload.get("marks", []) if isinstance(payload, dict) else [])
        log(f"saved {target} ({n_marks} marks, {target.stat().st_size} bytes)")

        resp = json.dumps({"ok": True, "path": str(target), "marks": n_marks}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)


def pick_free_port(preferred: int) -> int:
    """Return `preferred` if it binds, else a random free port."""
    if preferred:
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", preferred))
            s.close()
            return preferred
        except OSError:
            s.close()
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots-dir", required=True)
    ap.add_argument("--skill-dir", required=True)
    ap.add_argument("--port", type=int, default=0)
    args = ap.parse_args()

    shots_dir = Path(args.shots_dir).resolve()
    skill_dir = Path(args.skill_dir).resolve()
    if not (skill_dir / "annotator.html").exists():
        log(f"FATAL: annotator.html not found in {skill_dir}")
        return 2
    shots_dir.mkdir(parents=True, exist_ok=True)

    Handler.shots_dir = shots_dir
    Handler.skill_dir = skill_dir

    port = pick_free_port(args.port)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    log(f"serving shots from {shots_dir}")
    log(f"serving skill assets from {skill_dir}")
    log(f"listening on http://127.0.0.1:{port}/")
    # Print ONLY the port to stdout so the wrapper script can capture it.
    print(port, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("shutting down (SIGINT)")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
