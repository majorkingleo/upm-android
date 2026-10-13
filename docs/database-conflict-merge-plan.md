# Database conflict merge — implementation plan

Goal: when the local (device) database and the remote (server) database have
both changed since the last sync, **merge** the two instead of silently
discarding one side.

Status: plan only, nothing implemented yet.

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

### `DatabaseOptions`

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

| Concern | File |
|---|---|
| Merge logic (new, pure function) | `src/com/u17od/upm/database/DatabaseMerger.java` |
| Expose `setRevision` on the db | `src/com/u17od/upm/database/PasswordDatabase.java` |
| Decide upload/download/merge | `src/com/u17od/upm/SyncDatabaseActivity.java` |
| Base-file path + copy helper | `src/com/u17od/upm/Utilities.java` |
| After-sync base bookkeeping | `src/com/u17od/upm/SyncDatabaseActivity.java` |
| Conflict fallback backup | `src/com/u17od/upm/SyncDatabaseActivity.java` |
| Strings (4 locales) | `res/values*/strings.xml` |

### 4.1 `DatabaseMerger.java` (new)

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

### 4.2 `PasswordDatabase.java` — expose `setRevision`

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

### 4.3 `SyncDatabaseActivity.syncDb(...)` — new decision flow

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

### 4.4 `Utilities.java` — base-file helpers

```java
public static File getSyncBaseFile(Activity activity) {
    return new File(activity.getFilesDir(), DEFAULT_DATABASE_FILE + ".sync-base");
}
public static void saveSyncBase(Activity activity, File dbFile) { ... }  // copy bytes
public static File getConflictBackupFile(Activity activity) { ... }      // timestamped
```

### 4.5 No-base / fallback path

When `B` is missing or undecryptable: keep the current last-writer-wins
comparison, but before overwriting the loser, copy it to
`getConflictBackupFile()` (encrypted, no data loss). Log a `Log.w`.

### 4.6 Password change

`Prefs`/`EnterMasterPassword` change the master password. On change: delete the
base file (or re-encrypt it). Simplest: delete it → next sync falls back to
last-writer-wins once, then re-establishes the base.

### 4.7 Strings

Add (values, values-de, values-fr, values-ru):

```xml
<string name="sync_merged">Databases merged</string>
<string name="sync_conflicts_kept">%1$d conflicting account(s) kept as copies</string>
<string name="merge_remote_suffix"> (remote)</string>
```

## 5. Phased implementation

**Phase 1 — safe auto-merge (no dialog)**
1. `PasswordDatabase.setRevision`.
2. `DatabaseMerger` + unit-style checks (see test matrix).
3. `Utilities` base-file helpers.
4. `syncDb` rewrite with base loading, merge, and fallback backup.
5. Base-file bookkeeping after sync + delete on password change.
6. Strings.
7. Build, then verify with the emulator matrix below.

**Phase 2 — interactive conflict resolution (optional)**
- Replace the automatic `" (remote)"` duplicate with a dialog listing conflicts
  (keep local / keep remote / keep both). Needs a new `DialogFragment` and
  wiring the result back into `syncDb` (currently synchronous).

## 6. Test matrix (emulator + `scripts/webdav-test.py`)

Seed states with `scripts/webdav-test.py push/pull/delete` and drive the app with
`scripts/upm-ui.py`. Check the resulting account list + remote md5.

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
  already the case; verify `UPMBackupAgent` behaviour).
- Never decrypt or write the base file during a partial sync: only update it
  after a fully successful, converged sync.
