#!/usr/bin/env python3
"""WebDAV test environment helper for UPM.

Sets up / inspects / resets the remote UPM database used for WebDAV sync
testing, so the Android app can be verified against a known remote state.

Credentials are read from files (never printed, never passed on the command
line):

  --password-file   remote (Nextcloud) password. Default: ./password.txt
  --db-password-file  UPM database master password. Default: a sibling
                    ``<db>.password`` file next to --db.

Examples
--------
  python3 scripts/webdav-test.py check          # reachability + auth
  python3 scripts/webdav-test.py status         # remote vs local db
  python3 scripts/webdav-test.py push           # local db  -> remote
  python3 scripts/webdav-test.py pull           # remote db -> local
  python3 scripts/webdav-test.py reset          # delete + push (clean slate)

Only the Python standard library is used, so this runs anywhere python3 does.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
import ssl
import sys
import urllib.error
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_URL = "https://nextcloud.borger.co.at/remote.php/dav/files/test/upm/"
DEFAULT_REMOTE_FILE = "upm.db"
DEFAULT_USER = "test"
DEFAULT_PASSWORD_FILE = "password.txt"


# ---------------------------------------------------------------- helpers
def ok(msg):
    print(f"  [ok]   {msg}")


def fail(msg):
    print(f"  [FAIL] {msg}")


def info(msg):
    print(f"  ....   {msg}")


def read_secret(path, what):
    """Read a password from a file, tolerating a trailing newline."""
    with open(path, "r", encoding="utf-8") as fh:
        value = fh.read().strip()
    if not value:
        sys.exit(f"[error] {what} file is empty: {path}")
    return value


def md5_of(data):
    return hashlib.md5(data).hexdigest()


def md5_of_file(path):
    with open(path, "rb") as fh:
        return md5_of(fh.read())


def split_url(url, remote_file):
    """Return (folder_url_with_trailing_slash, file_name)."""
    if url.endswith("/"):
        return url, remote_file
    tail = url.rsplit("/", 1)[-1]
    if "." in tail:  # points straight at the file
        return url[: -len(tail)], tail
    return url + "/", remote_file


def guess_db_path(explicit):
    if explicit:
        return explicit
    for candidate in ("scripts/upm.db", "scripts/test.db"):
        path = os.path.join(REPO_ROOT, candidate)
        if os.path.isfile(path):
            return path
    sys.exit("[error] no database found; pass --db (looked for scripts/upm.db, scripts/test.db)")


def guess_db_password_file(db_path, explicit):
    if explicit:
        return explicit
    for candidate in (db_path + ".password", os.path.splitext(db_path)[0] + ".password"):
        if os.path.isfile(candidate):
            return candidate
    sys.exit(f"[error] no master password file found next to {db_path}; pass --db-password-file")


# ---------------------------------------------------------------- transport
class Webdav:
    def __init__(self, url, remote_file, user, password, insecure=False):
        self.folder, self.file = split_url(url, remote_file)
        self.url = self.folder + self.file
        self.user = user
        self.password = password
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.auth_header = "Basic " + token
        if insecure:
            self.context = ssl._create_unverified_context()
        else:
            self.context = ssl.create_default_context()

    def _request(self, method, url, data=None):
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", self.auth_header)
        if data is not None:
            req.add_header("Content-Type", "application/octet-stream")
            req.add_header("Content-Length", str(len(data)))
        try:
            with urllib.request.urlopen(req, context=self.context, timeout=30) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()
        except urllib.error.URLError as exc:
            sys.exit(f"[error] cannot reach {url}: {exc.reason}")

    def put(self, data):
        return self._request("PUT", self.url, data)

    def get(self):
        return self._request("GET", self.url)

    def delete(self):
        return self._request("DELETE", self.url)

    def propfind(self):
        return self._request("PROPFIND", self.folder, b"")


# ---------------------------------------------------------------- commands
def cmd_check(dav, args):
    print(f"WebDAV endpoint : {dav.url}")
    print(f"Auth user       : {dav.user}")
    print("Remote password : <from file, not shown>")
    try:
        db_path = guess_db_path(args.db)
        print(f"Local db        : {db_path} ({os.path.getsize(db_path)} bytes)")
        print(f"Master pw file  : {guess_db_password_file(db_path, args.db_password_file)} (contents not shown)")
    except SystemExit:
        print("Local db        : <none found>")
    print()

    print("1. PROPFIND on the target folder (does it exist / is auth accepted?)")
    code, _ = dav.propfind()
    if code in (207, 200, 405):
        # 207 Multi-Status is the WebDAV answer; 405 means PROPFIND unsupported
        # but the server is reachable and auth was accepted.
        ok(f"folder reachable (HTTP {code})")
    elif code == 401:
        fail("authentication rejected (HTTP 401) - check the remote password file")
        return 1
    elif code == 404:
        info("folder not found (HTTP 404) - it will be created by the next PUT")
    else:
        info(f"PROPFIND returned HTTP {code} (continuing)")

    print("2. PUT a probe file")
    payload = b"upm-webdav-probe"
    probe_url_backup = dav.url
    dav.url = dav.folder + "upm-probe.txt"
    code, _ = dav.put(payload)
    if code in (200, 201, 204):
        ok(f"PUT accepted (HTTP {code})")
    elif code == 401:
        fail("authentication rejected on PUT (HTTP 401)")
        dav.url = probe_url_backup
        return 1
    else:
        fail(f"PUT failed (HTTP {code})")
        dav.url = probe_url_backup
        return 1

    print("3. GET the probe file back and compare")
    code, body = dav.get()
    if code == 200 and body == payload:
        ok("GET returned the exact bytes that were PUT")
    else:
        fail(f"GET returned HTTP {code}, {len(body)} bytes")
        dav.url = probe_url_backup
        return 1

    print("4. DELETE the probe file (404 also counts as success)")
    code, _ = dav.delete()
    if code in (200, 204, 404):
        ok(f"DELETE accepted (HTTP {code})")
    else:
        fail(f"DELETE failed (HTTP {code})")
    dav.url = probe_url_backup
    return 0


def cmd_status(dav, args):
    db_path = guess_db_path(args.db)
    print(f"Local db  : {db_path}")
    if os.path.isfile(db_path):
        info(f"{os.path.getsize(db_path)} bytes, md5 {md5_of_file(db_path)}")
    else:
        fail("local db missing")
    print(f"Remote db : {dav.url}")

    code, body = dav.get()
    if code == 404:
        fail("remote db does not exist (HTTP 404)")
        return 1
    if code == 401:
        fail("authentication rejected (HTTP 401)")
        return 1
    if code != 200:
        fail(f"GET returned HTTP {code}")
        return 1
    ok(f"remote db present: {len(body)} bytes, md5 {md5_of(body)}")
    if os.path.isfile(db_path) and md5_of_file(db_path) == md5_of(body):
        ok("remote and local db are byte-identical")
    else:
        info("remote and local db differ (expected after a sync from the app)")
    return 0


def cmd_push(dav, args):
    db_path = guess_db_path(args.db)
    with open(db_path, "rb") as fh:
        data = fh.read()
    print(f"PUT {db_path} ({len(data)} bytes, md5 {md5_of(data)})")
    code, _ = dav.put(data)
    if code in (200, 201, 204):
        ok(f"uploaded (HTTP {code})")
        return 0
    fail(f"PUT failed (HTTP {code})")
    return 1


def cmd_pull(dav, args):
    db_path = guess_db_path(args.db)
    print(f"GET {dav.url}")
    code, body = dav.get()
    if code != 200:
        fail(f"GET returned HTTP {code}")
        return 1
    if os.path.isfile(db_path):
        if md5_of_file(db_path) == md5_of(body):
            info("local db already identical; nothing written")
            return 0
        if not args.force:
            fail("refusing to overwrite a different local db without --force")
            return 1
    with open(db_path, "wb") as fh:
        fh.write(body)
    ok(f"wrote {db_path} ({len(body)} bytes, md5 {md5_of(body)})")
    return 0


def cmd_delete(dav, args):
    code, _ = dav.delete()
    if code in (200, 204, 404):
        ok(f"remote db deleted (HTTP {code})")
        return 0
    if code == 401:
        fail("authentication rejected (HTTP 401)")
        return 1
    fail(f"DELETE failed (HTTP {code})")
    return 1


def cmd_reset(dav, args):
    print("reset: delete the remote db, then push the local one")
    if cmd_delete(dav, args) != 0:
        return 1
    return cmd_push(dav, args)


COMMANDS = {
    "check": cmd_check,
    "status": cmd_status,
    "push": cmd_push,
    "pull": cmd_pull,
    "delete": cmd_delete,
    "reset": cmd_reset,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=sorted(COMMANDS))
    ap.add_argument("--url", default=DEFAULT_URL, help="WebDAV folder URL, or the full file URL")
    ap.add_argument("--remote-file", default=DEFAULT_REMOTE_FILE)
    ap.add_argument("--user", default=DEFAULT_USER)
    ap.add_argument("--password-file", default=os.path.join(REPO_ROOT, DEFAULT_PASSWORD_FILE))
    ap.add_argument("--db", default=None, help="local database used by push/pull/status")
    ap.add_argument("--db-password-file", default=None)
    ap.add_argument("--insecure", action="store_true", help="skip TLS certificate verification")
    ap.add_argument("--force", action="store_true", help="allow pull to overwrite a differing local db")
    args = ap.parse_args()

    if not os.path.isfile(args.password_file):
        sys.exit(f"[error] remote password file not found: {args.password_file}")
    remote_password = read_secret(args.password_file, "remote password")

    dav = Webdav(args.url, args.remote_file, args.user, remote_password, args.insecure)
    return COMMANDS[args.command](dav, args)


if __name__ == "__main__":
    sys.exit(main())
