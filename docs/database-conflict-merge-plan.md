# Database conflict merge — implementation plan

Goal: when the local (device) database and the remote (server) database have
both changed since the last sync, **merge** the two instead of silently
discarding one side.

Status: Phase 1 implemented (revision setter, `DatabaseMerger` + unit tests,
base-file helpers, `syncDb` merge/fallback flow, base bookkeeping, strings).
Build + unit tests pass. Emulator matrix rows 1-9 verified end-to-end (row 10
half-verified) with `scripts/merge-test.sh` — see §8 for details.

Legend: ✅ done · ⬜ pending · 🟡 partial

---

## 1. Problem

The database is a single encrypted file. Sync compares the two whole-file
revision counters and picks a winner:

```java
// SyncDatabaseActivity.syncDb(...)
if (dbDownloadedOnSync == null || dbDownloadedOnSync.getRevision() < local.getRevision()) {
    uploadDatabase();                                   // local wins
} else if (dbDownloadedOnSync.getRevision() > local.getRevision()) {
    copy downloaded over local;                         // remote wins
} else {
    // equal -> "up to date"
}
```

`Revision` is a monotonically increasing integer incremented on **every** save
(`PasswordDatabase.save()` → `revision.increment()`). It is per-file, so two
diverged copies have unrelated counters:

- Device A: 3 edits → revision 5
- Device B: 2 edits → revision 4 (started from the same rev 2)

`5 > 4` → device A uploads and **overwrites** device B's two edits. There is no
conflict detection and no merge; last writer wins, and the loser's changes are
lost silently.

The mergeable data is small and structured: a set of accounts keyed by name
(`AccountInformation` = accountName, userId, password, url, notes) plus
`DatabaseOptions` (remoteLocation, authDBEntry). See the
`upm-database-format` skill for the on-disk layout.

## 2. Design decision: three-way merge

A two-way merge cannot tell these apart:

- account X present locally, absent remotely → *added locally* or *deleted remotely*?
- both changed the same account → *who wins*?

So we need a **base**: the last state both sides agreed on. The merge is then
base (`B`), local (`L`), remote (`R`).

We already decrypt both `L` and `R` during sync (`PasswordDatabase` for the
local db and the downloaded temp file). We only need to keep a copy of `B`.

### Base persistence

Store an encrypted copy of the last-synchronised database file next to the main
one:

```
files/upm.db           # live database
files/upm.db.sync-base # last-synced state (same format, same master password)
```

After every sync that ends in a converged state (upload, download, or "up to
date"), copy the winning bytes to `upm.db.sync-base`. The base file is encrypted
with the same password, so it adds no new secrets. It must live on disk (the
current `UPMApplication.timeOfLastSync` is in-memory only and is not usable for
this).

### Fallbacks

- No base file (first sync after install / after a password change): keep the
  current last-writer-wins behaviour, but first write the losing side to
  `files/upm.db.conflict-<timestamp>` (encrypted) so nothing is silently lost.
- Legacy/old base that fails to decrypt with the current password: same fallback.

## 3. Merge algorithm (accounts)

Keyed by account name. For each name in `union(B, L, R)`:

| in B | in L | in R | same? | Result |
|---|---|---|---|---|
| no | yes | no | — | added locally → keep `L` |
| no | no | yes | — | added remotely → keep `R` |
| no | yes | yes | L==R | both added identically → keep it |
| no | yes | yes | L!=R | both added differently → **conflict** |
| yes | yes | yes | L==R | unchanged → keep it |
| yes | yes | yes | L==B, R!=B | only remote edited → keep `R` |
| yes | yes | yes | R==B, L!=B | only local edited → keep `L` |
| yes | yes | yes | L!=B, R!=B, L!=R | both edited → **conflict** |
| yes | yes | no | L==B | deleted remotely → delete |
| yes | yes | no | L!=B | delete vs edit → **keep `L`** (see policy) |
| yes | no | yes | R==B | deleted locally → delete |
| yes | no | yes | R!=B | delete vs edit → **keep `R`** |
| yes | no | no | — | deleted on both → drop |

The "same?" column compares the whole `AccountInformation` (all five fields).

### Conflict policy (default, no dialog)

- **Both edited** / **both added differently**: keep the local account under its
  original name; keep the remote account as a new account named
  `name + " (remote)"` (append a number if that name is taken). No data is lost;
  the user reviews and deletes one later.
- **Delete vs edit**: keep the edited side (an edit is more recent intent than a
  deletion). Deletions are only honoured when the other side left the account
  untouched. This never silently drops edited data.

Phase 2 (optional, later): a resolution dialog per conflict instead of the
automatic duplicate.

### `DatabaseOptions`### Option A — Nextcloud app, 

`remoteLocation`/`authDBEntry` describe *how this device reaches the server*;
they are not user data. Always keep the **local** values (the device that is
currently syncing). Never let the remote copy clobber the local sync settings.

### Revision after merge

`newRevision = max(L.rev, R.rev) + 1`. The merged result must be strictly
greater than both inputs, otherwise a stale device still holding `L` or `R` could
later overwrite the merge. After upload, all devices converge on the merged file
and the counter is in sync again.

## 4. File-by-file changes

All paths relative to repo root. Package root `src/com/u17od/upm/`.

| Concern | File | Status |
|---|---|---|
| Merge logic (new, pure function) | `src/com/u17od/upm/database/DatabaseMerger.java` | ✅ done |
| Expose `setRevision` on the db | `src/com/u17od/upm/database/PasswordDatabase.java` | ✅ done |
| In-memory db constructor (merge result) | `src/com/u17od/upm/database/PasswordDatabase.java` | ✅ done (extra) |
| Account equality for merge | `src/com/u17od/upm/database/AccountInformation.java` | ✅ done (extra) |
| Unit tests for the merge algorithm | `tests/java/com/u17od/upm/database/DatabaseM### Option A — Nextcloud app, ergerTest.java` | ✅ done |
| Test dependencies (JUnit, BouncyCastle) | `build.gradle` | ✅ done |
| Decide upload/download/merge | `src/com/u17od/upm/SyncDatabaseActivity.java` | ✅ done |
| Base-file path + copy helper | `src/com/u17od/upm/Utilities.java` | ✅ done |
| After-sync base bookkeeping | `src/com/u17od/upm/SyncDatabaseActivity.java` (+ upload tasks) | ✅ done |
| Conflict fallback backup | `src/com/u17od/upm/SyncDatabaseActivity.java` | ✅ done |
| Delete base on password change | `src/com/u17od/upm/ChangeMasterPassword.java` | ✅ done |
| Strings (4 locales) | `res/values*/strings.xml` | ✅ done |

### 4.1 `DatabaseMerger.java` (new) — ✅ done

A static helper operating on decrypted objects (both sides are already
decrypted by `SyncDatabaseActivity`):

```java
public final class DatabaseMerger {
    public static MergeResult merge(PasswordDatabase base,
                                    PasswordDatabase local,
                                    PasswordDatabase remote)
}
```

`MergeResult` = merged `PasswordDatabase` + counts (accounts merged, conflicts
created) + a flag whether an upload is required. The algorithm is the table in
section 3; it uses `getAccounts()/addAccount()/deleteAccount()/getAccountNames()`
and sets the revision via the new `PasswordDatabase.setRevision()`.

### 4.2 `PasswordDatabase.java` — expose `setRevision` — ✅ done

Find:

```java
    public int getRevision() {
        return revision.getRevision();
    }
```

Add:

```java
    public void setRevision(int revision) {
        this.revision.setRevision(revision);
    }
```

(`Revision.setRevision(int)` already exists.)

Extra (not in the original plan, needed to make the merge testable): a
package-private in-memory constructor
`PasswordDatabase(EncryptionService, DatabaseOptions)` builds a file-less
database for the merge result. Also added
`AccountInformation.equals/hashCode` (all five fields) so the merge can compare
whole accounts. Both are marked with the project's AI-modification comments.

### 4.3 `SyncDatabaseActivity.syncDb(...)` — new decision flow — ✅ done

Replace the three-branch `if/else` (lines ~86-105) with:

1. `R = dbDownloadedOnSync` (may be null).
2. If `R == null` → `uploadDatabase()` (unchanged; remote missing).
3. Load base `B`:
   - `Utilities.getSyncBaseFile(this)` → `new PasswordDatabase(baseFile, secretKey)`.
   - On any failure → **no-base fallback** (4.5).
4. `merge = DatabaseMerger.merge(B, local, R)`.
5. Apply:
   - `merge.requiresUpload` → replace local with merge, `save()`, `uploadDatabase()`.
   - only remote changed (local == B) → current "keep remote" path (copy + reload).
   - local == remote → "up to date".
6. Set `app.setTimeOfLastSync(new Date())` and write the new base file (4.4).

### 4.4 `Utilities.java` — base-file helpers — ✅ done

```java
public static File getSyncBaseFile(Activity activity) {
    return new File(activity.getFilesDir(), DEFAULT_DATABASE_FILE + ".sync-base");
}
public static void saveSyncBase(Activity activity, File dbFile) { ... }  // copy bytes
public static File getConflictBackupFile(Activity activity) { ... }      // timestamped
```

Implementation note: the base file is derived from the *actual* database file
name (`<db>.sync-base`), so it still tracks a custom db name. It is written
either directly on the converged keep-remote / up-to-date paths, or — after an
upload — by the new `SyncDatabaseActivity.onUploadSucceeded()` hook which the
HTTP, WebDAV and Dropbox upload tasks call once the upload has succeeded. It is
never written after a failed upload.

### 4.5 No-base / fallback path — ✅ done

When `B` is missing or undecryptable: keep the current last-writer-wins
comparison, but before overwriting the loser, copy it to
`getConflictBackupFile()` (encrypted, no data loss). Log a `Log.w`.

### 4.6 Password change — ✅ done

`Prefs`/`EnterMasterPassword` change the master password. On change: delete the
base file (or re-encrypt it). Simplest: delete it → next sync falls back to
last-writer-wins once, then re-establishes the base.

### 4.7 Strings — ✅ done

Add (values, values-de, values-fr, values-ru):

```xml
<string name="sync_merged">Databases merged</string>
<string name="sync_conflicts_kept">%1$d conflicting account(s) kept as copies</string>
<string name="merge_remote_suffix"> (remote)</string>
```

## 5. Phased implementation

**Phase 1 — safe auto-merge (no dialog)**
1. ✅ `PasswordDatabase.setRevision`.
2. ✅ `DatabaseMerger` + unit-style checks (see test matrix) — `DatabaseMergerTest`, 20 tests green.
3. ✅ `Utilities` base-file helpers.
4. ✅ `syncDb` rewrite with base loading, merge, and fallback backup.
5. ✅ Base-file bookkeeping after sync + delete on password change.
6. ✅ Strings.
7. ✅ Build passes; emulator matrix rows 1-9 verified (row 10 partial) via
   `scripts/merge-test.sh` — see §8.

**Phase 2 — interactive conflict resolution (optional)** — ⬜ not started
- Replace the automatic `" (remote)"` duplicate with a dialog listing conflicts
  (keep local / keep remote / keep both). Needs a new `DialogFragment` and
  wiring the result back into `syncDb` (currently synchronous).

## 6. Test matrix (emulator + `scripts/webdav-test.py`)

Seed states with `scripts/webdav-test.py push/pull/delete` and drive the app with
`scripts/upm-ui.py`. Check the resulting account list + remote md5.

Status: ✅ rows 1-9 verified on the emulator, plus row 10 "base dropped"; only
the second half of row 10 (LWW cycle + base rebuild) is not automated. Rows are
scripted in `scripts/merge-test.sh` (`all` runs them). See §8.

| # | Base | Local | Remote | Expected |
|---|---|---|---|---|
| 1 | A | A | A+acc | remote changed only → download, no conflict |
| 2 | A | A+acc | A | local changed only → upload |
| 3 | A | A+acc1 | A+acc2 | merge → both accounts present |
| 4 | A | A+edit(acc) | A | upload the edit |
| 5 | A | A+edit(acc) | A+edit2(acc) | conflict → acc + acc (remote) |
| 6 | A | A-del(acc) | A | deletion uploads |
| 7 | A | A+edit(acc) | A-del(acc) | delete-vs-edit → keep edited acc |
| 8 | (no base) | A+acc1 | A+acc2 | fallback LWW + conflict backup file exists |
| 9 | A | A | A | up to date, no transfer |
| 10 | A | A+pwChange | A | base dropped, one LWW cycle, base rebuilt |

## 7. Risks / notes

- The revision counter is the only ordering signal; the merge cannot resolve
  ordering *within* a single account field (e.g. two different password edits to
  the same account) beyond the conflict policy.
- Keeping `"(remote)"` duplicates can accumulate if conflicts recur; the dialog
  (Phase 2) is the long-term answer.
- The base file must be excluded from Android Backup / not mistaken for a real
  database (`Utilities.getDatabaseFile()` only returns `upm.db`, so this is
  already the case; ✅ verified — `UPMBackupAgent` backs up only the live db
  file by name, so the base is not included).
- Never decrypt or write the base file during a partial sync: only update it
  after a fully successful, converged sync.

## 8. Emulator verification — results (2026-10-13/14)

Outcome of the emulator test run. Phase 1 is implemented and builds; the
algorithm is unit-tested; the emulator matrix rows 1-9 pass and row 10 is
half-verified. Reproduce with `scripts/merge-test.sh all`.

### 8.1 Verified on the emulator ✅

- **Build + unit tests**: `./gradlew assembleDebug` and
  `./gradlew testDebugUnitTest` both pass (`DatabaseMergerTest`, 20/20).
- **Empty remote → upload + base creation** (the `remote == null` branch, §4.3
  step 2): with an empty remote folder, tapping *Sync* uploaded the local db and
  the new `onUploadSucceeded()` hook wrote the base file. Observed:
  - remote `upm/upm.db`, app `files/upm.db` and `files/upm.db.sync-base` all
    existed and were byte-identical (md5 `6ab838db7624b5b81098125f7e656cb1`);
  - no `TransportException`/`Problem` in logcat.
  This confirms: empty remote → upload, the upload-success base hook, and
  `base == local == remote` after a converged sync.

### 8.2 Emulator matrix — ✅ verified

All rows below pass on the emulator; the assertions live in
`scripts/merge-test.sh` (run `scripts/merge-test.sh all`). Full-suite result:
**20 assertions passed, 0 failed** (rows 1, 2, 4, 8, 9, 3, 5, 6, 7, 10).

| Row | Scenario | Result |
|---|---|---|
| 1 | remote changed only → download | ✅ local == remote, account present |
| 2 | local changed only → upload | ✅ converged, local change preserved |
| 3 | both added different → union merge | ✅ both accounts present, converged |
| 4 | local edit → upload | ✅ converged |
| 5 | both edited same account → conflict | ✅ `test` + `test (remote)` |
| 6 | deletion → upload | ✅ converged, account gone |
| 7 | delete-vs-edit → keep edit | ✅ edited account kept |
| 8 | no base → LWW + conflict backup | ✅ `upm.db.conflict-*` written, converged |
| 9 | up to date → no transfer | ✅ remote untouched |
| 10 | password change → base dropped | 🟡 base deleted ✅; follow-on LWW cycle + rebuild ⬜ |

The only un-automated piece is the second half of row 10: after a password
change the next sync prompts for the remote's *old* password (the remote is
still encrypted with it), and that prompt is not driven by the script yet.

### 8.3 Environment / setup to recreate

- **No remote credentials**: `password.txt` does not exist, so the real
  Nextcloud cannot be used. Tests run against the offline server:
  `python3 scripts/webdav-test-server.py --root /tmp/webdav-root --port 8080`
  (auth off) serving `/tmp/webdav-root/upm/`.
- **Cleartext**: targetSdk 36 blocks plain http, so a **debug-only** manifest
  overlay was added — `build-types/debug/AndroidManifest.xml` with
  `android:usesCleartextTraffic="true"`. Debug-only; review before shipping.
- **Emulator GPU**: the default `angle_indirect` crashed mid-run on a gfxstream
  fault. Boot with `EMULATOR_GPU=swiftshader_indirect ./scripts/emulator-run.sh`
  (stable; the framebuffer may stay black — trust `upm-ui.py dump`/`focus`,
  not screenshots).
- **URLs**: app → `http://10.0.2.2:8080/upm/`; host helper →
  `http://127.0.0.1:8080/upm/`.
- **The remote helper needs a password file even with auth off**: a dummy
  `/tmp/remote.pw` was used. Example:
  ```
  python3 scripts/webdav-test.py status \
    --url http://127.0.0.1:8080/upm/ --user test \
    --password-file /tmp/remote.pw \
    --db <file> --db-password-file scripts/test.db.password
  ```
- **Seeding app state** (stop the app first; `files/upm.db.sync-base` is the
  base):
  ```
  adb -s emulator-5554 shell am force-stop com.u17od.upm
  adb -s emulator-5554 shell "run-as com.u17od.upm sh -c 'cat > files/upm.db'" < <db>
  adb -s emulator-5554 shell "run-as com.u17od.upm sh -c 'cat > files/upm.db.sync-base'" < <base>
  ```
  Master password: `scripts/test.db.password` (read it, never print it).
- **Host artifacts from this session** (under `/tmp`): `B0.db` (+ `.password`) —
  the post-upload base including the WebDAV settings (md5 `6ab838db…`);
  `L1.db` (+ `.password`) — base + an extra account `localacc`;
  `remote.pw`; `webdav-root/upm/upm.db`. A `webdav-test-server.py` is running in
  a background terminal on port 8080.

### 8.4 Blockers hit

- **fish shell**: inline heredocs (`python3 - <<EOF`) and long `&&` chains with
  redirection fail with syntax errors in this terminal. Put these sequences in a
  **bash script** under `scripts/` and run that, rather than pasting multi-line
  shell into fish.
- **Overflow-menu taps (RESOLVED)**: the real cause was not bad coordinates but
  the 5-minute `isSyncRequired` edit guard — tapping *Add* while it is active
  silently shows a "sync required" toast instead of opening the form. With a
  recent sync the taps land correctly, and the menu opens reliably with the MENU
  key (`adb shell input keyevent 82`), which `scripts/merge-test.sh` now uses.

### 8.5 Next steps

1. ✅ `scripts/merge-test.sh` written (§8.6) — removes both blockers: everything
   runs from bash, and the menu is opened with the MENU key.
2. ✅ Variant artifacts created (§8.6).
3. ✅ Rows 1-9 pass; row 10 "base dropped" passes.
4. ⬜ Optional: script the second half of row 10 (the LWW cycle + base rebuild
   after a password change) — needs the remote's old password typed at the
   `EnterMasterPassword` prompt.
5. ⬜ Decide whether to commit `scripts/merge-test.sh` and keep
   `build-types/debug/AndroidManifest.xml` (debug-only cleartext).

### 8.6 `scripts/merge-test.sh`

Bash harness that drives the app and asserts the database bytes for each row.
It seeds `files/upm.db` / `files/upm.db.sync-base` from artifacts, unlocks the
app, triggers Sync (MENU key, reliable), and compares md5s via
`webdav-test.py`/`run-as`. It also builds UI variants (there is no CLI writer for
the encrypted format).

```
scripts/merge-test.sh up                       # WebDAV server + emulator
scripts/merge-test.sh addaccount OUT NAME [BASE]
scripts/merge-test.sh edit      OUT BASE ACCOUNT FIELD_INDEX VALUE   # 2=password 1=user
scripts/merge-test.sh deleteaccount OUT BASE ACCOUNT
scripts/merge-test.sh row 1..10                # run one row
scripts/merge-test.sh all                      # run every row whose artifacts exist
```

Artifacts (default `ART_DIR=/tmp`, recreate with the `addaccount`/`edit`/
`deleteaccount` commands from `B0.db`):

| File | Meaning |
|---|---|
| `B0.db` | base = `{test}` (includes the WebDAV settings) |
| `L1.db` | `B0` + account `localacc` (local-only change) |
| `R2.db` | `B0` + account `remoteacc` (remote-only change) |
| `Lc.db` | `B0` with `test` password edited (local conflict side) |
| `Rc.db` | `B0` with `test` user-id edited (remote conflict side) |
| `DEL.db` | `B0` with `test` deleted |

Note: `B0.db` was captured after earlier manual edits, so its `test` account is
not the pristine upstream value — only the *differences* between artifacts
matter. Each artifact carries a sibling `*.password` file (the master password,
mask `newmaster1`), passed to `webdav-test.py` and used by `cmd_unlock` via
`DB_PASSWORD_FILE`.
