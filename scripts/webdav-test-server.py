#!/usr/bin/env python3
"""Local WebDAV-ish test server for offline UPM sync tests.

Speaks just enough WebDAV for the UPM transport: GET, PUT, DELETE (plus
PROPFIND for a folder existence check), optionally requiring HTTP Basic auth.
Every request is logged, so a sync run from the app can be verified without a
real Nextcloud.

Examples
--------
  # seed a folder with a database, then serve it without auth
  mkdir -p /tmp/webdav-root/upm
  cp scripts/test.db /tmp/webdav-root/upm/upm.db
  scripts/webdav-test-server.py --root /tmp/webdav-root --port 8080

  # require Basic auth (tests the "HTTP Authentication Account" path)
  scripts/webdav-test-server.py --user testuser --password testpass

Point the app at http://10.0.2.2:<port>/upm/ (10.0.2.2 is the host from inside
the emulator). Note that Android blocks cleartext HTTP by default on
targetSdk >= 28, so this server is only usable over http from a build that
allows cleartext - otherwise use scripts/webdav-test.py against a real
Nextcloud (https) instead.
"""
from __future__ import annotations

import argparse
import base64
import os
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = "/tmp/webdav-root"
EXPECT_USER = ""
EXPECT_PASS = ""


def log(line):
    print(f"{datetime.now().strftime('%H:%M:%S')} {line}", flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _target(self):
        rel = self.path.split("?", 1)[0].lstrip("/")
        target = os.path.normpath(os.path.join(ROOT, rel))
        return target if target.startswith(ROOT) else None

    def _auth_ok(self):
        if not EXPECT_USER:
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            log(f"    auth: MISSING ({header!r})")
            return False
        user, _, pwd = base64.b64decode(header[6:]).decode("utf-8", "replace").partition(":")
        ok = user == EXPECT_USER and pwd == EXPECT_PASS
        log(f"    auth: user={user!r} pass_len={len(pwd)} -> {'OK' if ok else 'REJECTED'}")
        return ok

    def _require_auth(self):
        if self._auth_ok():
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="test"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def _reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_PROPFIND(self):
        log(f"PROPFIND {self.path}")
        if not self._require_auth():
            return
        target = self._target()
        if target and os.path.isdir(target):
            self._reply(207)
        else:
            log("    -> 404")
            self._reply(404)

    def do_GET(self):
        log(f"GET    {self.path}")
        if not self._require_auth():
            return
        target = self._target()
        if target and os.path.isfile(target):
            with open(target, "rb") as fh:
                body = fh.read()
            log(f"    -> 200 ({len(body)} bytes)")
            self._reply(200, body)
        else:
            log("    -> 404")
            self._reply(404)

    def do_PUT(self):
        log(f"PUT    {self.path}")
        if not self._require_auth():
            return
        target = self._target()
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        if target is None:
            log("    -> 400")
            self._reply(400)
            return
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as fh:
            fh.write(body)
        log(f"    -> 201 ({len(body)} bytes -> {target})")
        self._reply(201)

    def do_DELETE(self):
        log(f"DELETE {self.path}")
        if not self._require_auth():
            return
        target = self._target()
        if target and os.path.isfile(target):
            os.remove(target)
            log("    -> 204 (deleted)")
            self._reply(204)
        else:
            log("    -> 404 (nothing to delete)")
            self._reply(404)

    def log_message(self, fmt, *args):  # keep the console clean; we log ourselves
        pass


def main():
    global ROOT, EXPECT_USER, EXPECT_PASS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=ROOT, help=f"directory to serve (default {ROOT})")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--bind", default="0.0.0.0", help="bind address (default 0.0.0.0 so the emulator can reach it)")
    ap.add_argument("--user", default="", help="require this Basic auth user (default: no auth)")
    ap.add_argument("--password", default="", help="password for --user")
    args = ap.parse_args()

    ROOT = os.path.abspath(args.root)
    EXPECT_USER, EXPECT_PASS = args.user, args.password
    os.makedirs(ROOT, exist_ok=True)
    log(f"serving {ROOT} on {args.bind}:{args.port} auth={'on' if EXPECT_USER else 'off'}")
    ThreadingHTTPServer((args.bind, args.port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
