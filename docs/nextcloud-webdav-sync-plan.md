# Plan: Nextcloud / WebDAV sync support

**Status:** draft — not implemented yet
**Scope:** `upm-android` (Universal Password Manager)

## 1. Goal

Let UPM **sync** a password database against a **Nextcloud (WebDAV)** server, not
just download it. Today only a one-way *download* works against Nextcloud; a full
sync (uploading the local DB back) fails.

## 2. Why it fails today

UPM's HTTP sync (`SyncDatabaseViaHttpActivity`) talks to UPM's own HTTP "server
protocol", not to WebDAV:

| Operation | What the code does | Where |
|---|---|---|
| Download | plain `GET <dir>/<file>` with Basic auth | `HTTPTransport.getRemoteFile()` → `get()` |
| Upload | `POST <dir>/upload.php` (multipart), expects body `OK` | `HTTPTransport.put()` |
| Delete | `POST <dir>/deletefile.php`, expects `OK`/`FILE_DOESNT_EXIST` | `HTTPTransport.delete()` |

Nextcloud has no `upload.php`/`deletefile.php`, so:

- **Download works** (it's a plain GET) — this is why the *"Download Remote
  Database"* screen succeeds.
- **Upload/delete fail** with 404 → sync always errors out.

The remote URL lives **inside the encrypted DB** (`DatabaseOptions.remoteLocation`,
see `res/xml/settings.xml` → "Shared URL" preference, saved in `Prefs.onKeyDown`).

## 3. Approach

Add a new, explicit sync method **"WebDAV"** (alongside `disabled`, `dropbox`,
`http`). This mirrors how Dropbox is a separate method with its own activity, and
leaves the existing `upload.php`/`deletefile.php` HTTP path untouched for current
users.

Rejected alternatives:

- **Auto-detect per request** (try WebDAV, fall back to `upload.php`): slow,
  error-prone, and produces confusing failures on misconfigured servers.
- **Replace HTTP with WebDAV**: breaks compatibility with UPM's HTTP server
  deployments.

## 4. Changes

### 4.1 Strings

`res/values/strings.xml` (+ `values-de`, `values-fr`, `values-ru`): add

```xml
<string name="sync_method_webdav">WebDAV (Nextcloud)</string>
```

`res/values/arrays.xml`: add one entry to `sync_methods_human`

```xml
<string-array name="sync_methods_human">
    <item>@string/sync_method_disabled</item>
    <item>@string/sync_method_dropbox</item>
    <item>@string/sync_method_http</item>
    <item>@string/sync_method_webdav</item>   <!-- new -->
</string-array>
```

### 4.2 `Prefs.java`

- Add `public static final String WEBDAV = "webdav";` to `Prefs.SyncMethod`.
- Add `SyncMethod.WEBDAV` to `syncMethodValues`.
- `initialiseFields()`: enable the shared-database settings category for both
  `HTTP` **and** `WEBDAV`.
- `onKeyDown()` (BACK): save `remoteLocation`/`authDBEntry` for `WEBDAV` too
  (currently only `HTTP` saves them):

  ```java
  if (syncMethod.equals(SyncMethod.HTTP) || syncMethod.equals(SyncMethod.WEBDAV)) {
      db.getDbOptions().setRemoteLocation(sharedURLPref.getText());
      db.getDbOptions().setAuthDBEntry(sharedURLAuthPref.getValue());
  } else {
      db.getDbOptions().setRemoteLocation(null);
      db.getDbOptions().setAuthDBEntry(null);
  }
  ```

### 4.3 `Utilities.java` — fix the empty-string bug

`getSyncMethod(settings, remoteHTTPLocation)` treats `""` as "HTTP configured"
because it only checks `!= null`:

```java
if (remoteHTTPLocation != null) {          // "" is non-null → HTTP
    syncMethod = Prefs.SyncMethod.HTTP;
}
```

Change to also require a non-blank value:

```java
if (remoteHTTPLocation != null && !remoteHTTPLocation.trim().isEmpty()) {
    syncMethod = Prefs.SyncMethod.HTTP;
}
```

`Utilities.getSyncMethod(Activity)` passes `getRemoteLocation()` (never null) and
should normalise `""` → `null` first, as `Prefs.onCreate` already does. This also
fixes the **"This database has not been configured with a remote URL"** toast
being reachable: the Sync menu item will be disabled when nothing is configured.

### 4.4 `transport/HTTPTransport.java` — WebDAV verbs

Add two methods (reuse `getConnection()`, `createAuthenticationString()`,
`addTrailingSlash()`):

```java
/** WebDAV PUT of a file's raw bytes. Accepts 200/201/204. */
public void putWebdav(String targetLocation, File file,
                      String username, String password) throws TransportException {
    HttpURLConnection conn = null;
    try {
        URL url = new URL(targetLocation);
        conn = getConnection(url);
        if (username != null && !username.trim().isEmpty()) {
            conn.setRequestProperty("Authorization", createAuthenticationString(username, password));
        }
        conn.setDoOutput(true);
        conn.setRequestMethod("PUT");
        conn.setRequestProperty("Content-Type", "application/octet-stream");
        conn.setFixedLengthStreamingMode((int) file.length());
        OutputStream os = conn.getOutputStream();
        os.write(Util.getBytesFromFile(file));   // same helper the legacy put() uses
        os.close();
        int code = conn.getResponseCode();
        if (code != 200 && code != 201 && code != 204) {
            throw new TransportException(String.format("Received response code %d from %s", code, url));
        }
    } catch (Exception e) {
        throw new TransportException(e);
    } finally {
        if (conn != null) conn.disconnect();
    }
}

/** WebDAV DELETE. 404 counts as success (nothing to delete). */
public void deleteWebdav(String targetLocation,
                         String username, String password) throws TransportException {
    HttpURLConnection conn = null;
    try {
        URL url = new URL(targetLocation);
        conn = getConnection(url);
        if (username != null && !username.trim().isEmpty()) {
            conn.setRequestProperty("Authorization", createAuthenticationString(username, password));
        }
        conn.setRequestMethod("DELETE");
        int code = conn.getResponseCode();
        if (code != 200 && code != 204 && code != 404) {
            throw new TransportException(String.format("Received response code %d from %s", code, url));
        }
    } catch (Exception e) {
        throw new TransportException(e);
    } finally {
        if (conn != null) conn.disconnect();
    }
}
```

Note: `addTrailingSlash` is currently `private`. Either make it package-visible or
add a convenience overload `putWebdavToDirectory(directory, file, u, p)` that
appends `file.getName()` (mirroring `getRemoteFile(remoteLocation, fileName, …)`).

### 4.5 New `SyncDatabaseViaWebdavActivity`

`SyncDatabaseViaWebdavActivity extends SyncDatabaseViaHttpActivity` and only
replaces the **upload** path (download via GET is already correct):

```java
public class SyncDatabaseViaWebdavActivity extends SyncDatabaseViaHttpActivity {

    @Override
    protected void uploadDatabase() {
        new UploadDatabaseWebdav().execute();
    }

    private class UploadDatabaseWebdav extends AsyncTask<Void, Void, Integer> {
        // remoteURL  = getPasswordDatabase().getDbOptions().getRemoteLocation();
        // fileName   = getPasswordDatabase().getDatabaseFile().getName();
        // username/password from the "Shared URL auth" account (same lookup as UploadDatabase)
        // transport.putWebdav(addTrailingSlash(remoteURL) + fileName,
        //                      getPasswordDatabase().getDatabaseFile(), user, pass);
        // -> toast on TransportException, finish() like UploadDatabase
    }
}
```

The download flow (`RetrieveRemoteDatabaseFromHTTP`) stays as-is: `getRemoteFile()`
already does `GET <dir>/<fileName>` with Basic auth — valid for Nextcloud.

Register the activity in `AndroidManifest.xml` (theme `@style/Theme.Transparent`,
like the other two sync activities).

### 4.6 `FullAccountList.java` — routing

In `onOptionsItemSelected`, after the `DROPBOX` branch:

```java
} else if (Utilities.getSyncMethod(this).equals(Prefs.SyncMethod.WEBDAV)) {
    Intent i = new Intent(FullAccountList.this, SyncDatabaseViaWebdavActivity.class);
    startActivityForResult(i, SyncDatabaseActivity.SYNC_DB_REQUEST_CODE);
}
```

## 5. What the user will configure

In UPM **Settings**:

- **Sync method** → `WebDAV (Nextcloud)`
- **Shared URL** → the **directory** URL with a trailing slash, e.g.
  `https://nextcloud.borger.co.at/remote.php/dav/files/kingleo/UPM/`
  (UPM appends the local filename `upm.db` itself.)
- **Shared URL auth** → the account whose username/password to use. For Nextcloud
  store an **app password** here (Settings → Security → Devices & sessions),
  especially if 2FA is enabled.
- **Trusted hostname** (optional) — for self-signed certs.

## 6. Nextcloud specifics to handle

- Success codes: PUT → `201`/`204`, DELETE → `204`/`200`, GET → `200`.
  (Covered in 4.4.)
- Nextcloud rejects the **account** password for WebDAV when 2FA is on → app
  password required. Document in the README.
- Paths are **case-sensitive** (`UPM/upm.db` vs `upm/upm.db`).
- First sync against an empty folder: GET → 404 → `getRemoteFile()` returns null →
  `syncDb()` uploads the local DB (PUT), creating the remote file. Works with no
  delete step.
- The sync "revision" is stored inside the DB file itself, so no server-side
  metadata is needed; the existing `syncDb()` comparison keeps working.

## 7. Testing

1. **Transport level** (curl, no app): `curl -u kingleo -T file 'https://…/UPM/upm.db'`
   (PUT) and `curl -u kingleo -X DELETE 'https://…/UPM/upm.db'` return 2xx.
2. **In app on emulator/device:**
   - Download a DB, set Sync method = WebDAV + Shared URL.
   - Add an account, change data, save → local revision increments.
   - Sync → confirm PUT succeeds and a second device sees the update.
   - Delete the remote file → sync re-uploads (first-sync case).
   - Regression: existing `HTTP` sync still POSTs to `upload.php` and works.

## 8. Related fixes (bundle with this work)

- `Utilities.getSyncMethod` empty-string bug (4.3) — removes the misleading
  "not configured with a remote URL" toast and correctly disables the Sync menu.
- Optionally, after a *Download Remote Database* completes, pre-fill the DB's
  `remoteLocation` from the download URL (directory part) so a subsequent sync
  "just works". Nice-to-have, not required.

## 9. Open questions / risks

- `Util.getBytesFromFile` reads the whole DB into memory (existing behaviour in
  `put()`). Fine for typical UPM DB sizes; keep consistent.
- Translations for `WebDAV (Nextcloud)` needed in de/fr/ru.
- Do we keep the legacy HTTP method forever, or later deprecate it in favour of
  WebDAV? (Out of scope here.)
