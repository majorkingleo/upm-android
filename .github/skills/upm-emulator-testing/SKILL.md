---
name: upm-emulator-testing
description: 'Run and verify the UPM Android app on the emulator using the helper scripts in scripts/ (upm-ui.py, webdav-test.py, webdav-test-server.py). USE FOR: testing sync on a device or emulator; seeding/inspecting a WebDAV or Nextcloud remote database; driving the app UI from the command line (tapping, typing, reading the screen, checking which activity is focused); reproducing sync bugs such as HTTP 401, "sync required", cleartext-HTTP blocked, or a wrong db revision; checking whether a local change still builds and installs. DO NOT USE FOR: pure unit tests of Java classes (use gradle), web/Playwright testing, or VS Code extension work. INVOKES: terminal commands (adb, gradle, python3 helpers in scripts/).'
---

# UPM emulator testing

Drive the UPM Android app and its sync backends from the command line, so
sync behaviour is verified against real bytes instead of eyeballed screenshots.

## When to Use

- Verifying a sync change (WebDAV, HTTP server, Dropbox) end to end.
- Reproducing UI flows: open Preferences, change the sync method, add/edit an
  account, trigger a sync.
- Seeding or inspecting the remote database ("what revision is up there?").
- Diagnosing sync failures: 401, "sync required", 403/404, wrong revision,
  `TransportException`, cleartext blocked.

## Prerequisites

- Build/run with JDK 21: `JAVA_HOME=/usr/lib/jvm/java-21-openjdk`. AGP 9 /
  Gradle 9.3 reject JDK 25.
- `adb` on PATH, an AVD (default `upm-api36`), toolchain installed via
  `scripts/install-android-toolchain.sh`.
- Tasks in `.vscode/tasks.json`: *Android: build debug APK*,
  *Android: run on emulator*, *Android: stop emulator*,
  *Android: install on device*.

## Helpers (all python3, stdlib only, in `scripts/`)

| Script | What it does |
|---|---|
| `scripts/upm-ui.py` | Drives the app: `dump`, `tap "Text"`, `tapxy X,Y`, `wait`, `type`, `clear`, `key`, `focus`, `shot`. Uses `--serial` (default `emulator-5554`) or `ADB_SERIAL`. |
| `scripts/webdav-test.py` | Drives the remote side: `check`, `status`, `push`, `pull`, `delete`, `reset`. Reads the remote password from `password.txt` and the db master password from `<db>.password`; never prints either. |
| `scripts/webdav-test-server.py` | Local WebDAV-ish server (GET/PUT/DELETE/PROPFIND + optional Basic auth, request log) for offline tests. |

Run `python3 scripts/<script>.py --help` for the full flag list.

## Procedure: verify a sync end to end

1. **Build and boot**
   ```
   ./gradlew assembleDebug            # or the "build debug APK" task
   ./scripts/emulator-run.sh          # boots, installs, launches
   ```
2. **Keep the display awake** - otherwise taps silently do nothing once the
   screen times out:
   ```
   adb -s emulator-5554 shell svc power stayon true
   ```
3. **Check the remote environment** before touching the app:
   ```
   python3 scripts/webdav-test.py check     # auth + PUT/GET/DELETE probe
   python3 scripts/webdav-test.py status    # remote vs local db
   ```
   `push`/`reset` seed it from `scripts/upm.db` (or `scripts/test.db`).

   To exercise the **first-ever upload** (empty Nextcloud + fresh local db):
   ```
   python3 scripts/webdav-test.py delete       # remote db must be absent (404)
   python3 scripts/webdav-test.py status
   ```
   then install a fresh local db (step 4) and sync. Expected: GET 404 -> the app
   falls through to upload -> DELETE 404 ("nothing to delete", treated as success)
   + PUT 201, and afterwards the remote md5 must equal the app's `files/upm.db` md5.
   Note the auth account of `scripts/test.db` does not hold the remote password, so
   fix it in the app *before* setting the Shared URL - account edits are allowed
   while no Shared URL is configured (`Utilities.isSyncRequired`).
4. **Put a known database in place** (only if the app's vault is unknown):
   ```
   adb -s emulator-5554 shell am force-stop com.u17od.upm
   adb -s emulator-5554 shell "run-as com.u17od.upm sh -c 'cat > files/upm.db'" < scripts/test.db
   ```
   The master password lives in the sibling `scripts/test.db.password`.
5. **Drive the app** - always confirm the activity focus between steps:
   ```
   python3 scripts/upm-ui.py focus
   python3 scripts/upm-ui.py tap "More options"
   python3 scripts/upm-ui.py tap "Preferences"
   python3 scripts/upm-ui.py tap "Sync Method"
   python3 scripts/upm-ui.py tap "WebDAV (Nextcloud)"
   ```
   The URL field starts empty, so tap it by coordinates and type the folder URL
   (no trailing file name - the app appends the db file name itself):
   ```
   python3 scripts/upm-ui.py tapxy 540,818
   python3 scripts/upm-ui.py type 'https://cloud.example.com/remote.php/dav/files/USER/upm/'
   python3 scripts/upm-ui.py tap "OK"
   python3 scripts/upm-ui.py tap "HTTP Authentication Account"
   python3 scripts/upm-ui.py tap "ACCOUNT_NAME"
   python3 scripts/upm-ui.py key BACK          # leaving Preferences persists the db
   ```
6. **Sync and verify the bytes**
   ```
   adb -s emulator-5554 logcat -c
   python3 scripts/upm-ui.py tap "More options"
   python3 scripts/upm-ui.py tap "Sync"
   adb -s emulator-5554 logcat -d | grep -iE 'TransportException|Problem'
   python3 scripts/webdav-test.py status
   adb -s emulator-5554 exec-out run-as com.u17od.upm cat files/upm.db | md5sum
   ```
   Success criterion: after an upload the remote db md5 equals the app's
   `files/upm.db` md5. A no-op sync leaves the remote untouched and logs no
   `TransportException`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Problem Uploading Database` with `response code 404 ... /upm.db/upm.db` | The Shared URL points at the **file** instead of the folder. The app appends the db file name itself, so it becomes `.../upm.db/upm.db`. Set the Shared URL to the folder (`.../remote.php/dav/files/USER/UPM/`). |
| `Received the response code 401` | The "HTTP Authentication Account" password is not the **remote** password. Nextcloud with 2FA needs an app password (Settings → Security → Devices & sessions). Probe it with `webdav-test.py check --password-file FILE`. |
| Taps do nothing, `screencap` is black | Screen asleep → `adb shell svc power stayon true`. With `EMULATOR_GPU=swiftshader_indirect` the framebuffer may stay black while the app works: trust `upm-ui.py dump`/`focus`, not screenshots. |
| Menu item tap has no effect | The overflow popup reports window-relative bounds; tap by text (`upm-ui.py tap`) rather than hand-computed coordinates. |
| `sync_required` toast blocks Add/Edit/Delete | `Utilities.isSyncRequired()`: with a Shared URL set, edits are refused until a sync ran within 5 minutes. Set Sync Method = Disabled to break the deadlock, fix the credential, re-enable. |
| `Cleartext HTTP traffic to … not permitted` | Android blocks plain http on targetSdk ≥ 28. Test against an https endpoint; the local `webdav-test-server.py` only works from a build that allows cleartext. |
| `am start … not exported from uid` | The transparent sync activities are internal; launch them through the app's overflow menu. |
| A fresh install shows an old database | The AVD userdata persists across cold boots; replace `files/upm.db` explicitly (step 4). |
| Nothing syncs, remote looks identical | The local db revision must be **greater** than the remote one; any account edit or preference save bumps it. |

## Notes

- Only edit accounts through the UI; there is no CLI writer for the encrypted
  UPM database format.
- Don't print or commit secrets: `password.txt` (remote) and
  `scripts/*.password` (db master) are read from files; both are gitignored or
  test-only.
- `scripts/upm-ui.py` and `webdav-test.py` are the source of truth for the
  exact subcommands - prefer `--help` over guessing flags.
