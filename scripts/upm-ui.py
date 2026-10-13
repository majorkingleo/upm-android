#!/usr/bin/env python3
"""Drive the UPM app on the emulator from the command line.

Small uiautomator/adb wrapper used for manual end-to-end verification of the
WebDAV sync, so taps and text entry do not have to be eyeballed.

Examples
--------
  scripts/upm-ui.py dump                     # every element: class | text | bounds
  scripts/upm-ui.py list                     # text + bounds only
  scripts/upm-ui.py tap "Preferences"        # tap the element with this exact text
  scripts/upm-ui.py tap --contains 'WebDAV'
  scripts/upm-ui.py wait "WebDAV (Nextcloud)" --timeout 10
  scripts/upm-ui.py type "https://…"         # type into the focused field
  scripts/upm-ui.py clear                    # clear the focused field
  scripts/upm-ui.py key BACK                 # keyevent by name (BACK, ENTER, MENU…)
  scripts/upm-ui.py focus                    # focused window/activity
  scripts/upm-ui.py shot /tmp/screen.png     # screencap (-p already applied)

Notes
-----
  * Uses the first emulator unless ADB_SERIAL is set (or --serial).
  * The screen must be awake: "adb shell svc power stayon true" once per boot,
    otherwise taps silently do nothing after the display times out.
  * With EMULATOR_GPU=swiftshader_indirect the framebuffer may stay black while
    the app works fine - uiautomator dumps and input still work.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time

DEFAULT_SERIAL = os.environ.get("ADB_SERIAL", "emulator-5554")


def run(args, serial):
    cmd = ["adb", "-s", serial, *args]
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def ui_nodes(serial):
    run(["shell", "uiautomator", "dump", "/sdcard/ui.xml"], serial)
    xml = run(["shell", "cat", "/sdcard/ui.xml"], serial)
    for m in re.finditer(r"<node([^>]*?)/?>", xml):
        yield dict(re.findall(r'([\w-]+)="([^"]*)"', m.group(1)))


def label(node):
    return (node.get("text") or node.get("content-desc") or "").strip()


def center(bounds):
    x1, y1, x2, y2 = (int(n) for n in re.findall(r"-?\d+", bounds))
    return (x1 + x2) // 2, (y1 + y2) // 2


def find(nodes, needle, contains):
    return [n for n in nodes if label(n) and (needle in label(n) if contains else label(n) == needle)]


def cmd_dump(args, serial, verbose):
    for n in ui_nodes(serial):
        text = label(n)
        cls = n.get("class", "").replace("android.widget.", "")
        if not text and not cls.endswith(("EditText", "Button")):
            continue
        if verbose:
            print(f"{cls:14} | {text} | {n.get('bounds')} | click={n.get('clickable')} enabled={n.get('enabled')}")
        elif text:
            print(f"{text}  {n.get('bounds')}")
    return 0


def cmd_tap(args, serial, verbose):
    matches = find(ui_nodes(serial), args.text, args.contains)
    if not matches:
        print(f"no element matching {args.text!r}", file=sys.stderr)
        return 1
    if args.index >= len(matches):
        print(f"only {len(matches)} match(es) for {args.text!r}", file=sys.stderr)
        return 1
    node = matches[args.index]
    x, y = center(node["bounds"])
    print(f"tapping {label(node)!r} at ({x},{y})")
    run(["shell", "input", "tap", str(x), str(y)], serial)
    time.sleep(args.delay)
    return 0


def cmd_tapxy(args, serial, verbose):
    x, y = (int(v) for v in args.point.split(","))
    print(f"tapping ({x},{y})")
    run(["shell", "input", "tap", str(x), str(y)], serial)
    time.sleep(args.delay)
    return 0


def cmd_wait(args, serial, verbose):
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        if find(ui_nodes(serial), args.text, args.contains):
            print(f"found {args.text!r}")
            return 0
        time.sleep(1)
    print(f"timeout waiting for {args.text!r}", file=sys.stderr)
    return 1


def cmd_type(args, serial, verbose):
    # input text cannot send spaces; %s is the documented trick
    payload = args.text.replace(" ", "%s")
    run(["shell", "input", "text", payload], serial)
    time.sleep(args.delay)
    return 0


def cmd_clear(args, serial, verbose):
    run(["shell", "input", "keyevent", "KEYCODE_MOVE_END"], serial)
    for _ in range(args.count):
        run(["shell", "input", "keyevent", "KEYCODE_DEL"], serial)
    time.sleep(args.delay)
    return 0


def cmd_key(args, serial, verbose):
    name = args.name.upper()
    if not name.startswith("KEYCODE_"):
        name = "KEYCODE_" + name
    run(["shell", "input", "keyevent", name], serial)
    time.sleep(args.delay)
    return 0


def cmd_focus(args, serial, verbose):
    out = run(["shell", "dumpsys", "window"], serial)
    for line in out.splitlines():
        if "mCurrentFocus" in line or "mFocusedApp" in line:
            print(line.strip())
    return 0


def cmd_shot(args, serial, verbose):
    with open(args.path, "wb") as fh:
        proc = subprocess.run(["adb", "-s", serial, "exec-out", "screencap", "-p"], stdout=fh)
    print(f"wrote {args.path}" if proc.returncode == 0 else "screencap failed", file=sys.stderr if proc.returncode else sys.stdout)
    return proc.returncode


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serial", default=DEFAULT_SERIAL, help=f"adb device serial (default {DEFAULT_SERIAL})")
    sub = ap.add_subparsers(dest="command", required=True)

    def add(name, fn, help_text):
        p = sub.add_parser(name, help=help_text)
        p.set_defaults(func=fn)
        p.add_argument("--delay", type=float, default=1.5, help="seconds to wait after the action")
        return p

    add("dump", cmd_dump, "print visible elements").add_argument("--full", action="store_true", help="include class/click/enabled")
    tap = add("tap", cmd_tap, "tap an element by text")
    tap.add_argument("text")
    tap.add_argument("--contains", action="store_true", help="substring match instead of equality")
    tap.add_argument("--index", type=int, default=0, help="which match to tap (default first)")
    tapxy = add("tapxy", cmd_tapxy, "tap raw screen coordinates, e.g. 540,818")
    tapxy.add_argument("point", help="X,Y")
    wait = add("wait", cmd_wait, "wait until an element appears")
    wait.add_argument("text")
    wait.add_argument("--contains", action="store_true")
    wait.add_argument("--timeout", type=float, default=15.0)
    add("type", cmd_type, "type into the focused field").add_argument("text")
    clr = add("clear", cmd_clear, "clear the focused field")
    clr.add_argument("--count", type=int, default=40)
    add("key", cmd_key, "send a keyevent").add_argument("name")
    add("focus", cmd_focus, "print the focused window")
    add("shot", cmd_shot, "save a screenshot").add_argument("path")

    args = ap.parse_args()
    return args.func(args, args.serial, getattr(args, "full", False))


if __name__ == "__main__":
    sys.exit(main())
