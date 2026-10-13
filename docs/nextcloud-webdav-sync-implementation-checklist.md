# WebDAV sync — step-by-step implementation checklist

Self-contained instruction list for a low-cost coding agent. Each step names the
exact file, the exact anchor text to find, and the exact replacement. Apply the
steps in order; verify with the build command at the end.

## Prerequisites (do not skip)

- Build with `JAVA_HOME=/usr/lib/jvm/java-21-openjdk ./gradlew assembleDebug`.
  AGP 9.0 / Gradle 9.3 reject JDK 25.
- `./gradlew` must keep its executable bit.
- All paths are relative to the repo root `/home/martin/programs/upm-android`.
- Package root: `src/com/u17od/upm/`.
- Design reference: `docs/nextcloud-webdav-sync-plan.md`.

## File map

| Concern | File |
|---|---|
| Sync method constants + prefs UI | `src/com/u17od/upm/Prefs.java` |
| Sync-method resolution | `src/com/u17od/upm/Utilities.java` |
| HTTP/WebDAV transport | `src/com/u17od/upm/transport/HTTPTransport.java` |
| HTTP sync activity (base for WebDAV) | `src/com/u17od/upm/SyncDatabaseViaHttpActivity.java` |
| New WebDAV sync activity (create) | `src/com/u17od/upm/SyncDatabaseViaWebdavActivity.java` |
| Sync menu routing | `src/com/u17od/upm/FullAccountList.java` |
| Activity registration | `AndroidManifest.xml` |
| Sync method labels | `res/values/strings.xml`, `res/values-de/strings.xml`, `res/values-fr/strings.xml`, `res/values-ru/strings.xml` |
| Sync method list | `res/values/arrays.xml` |

---

## Step 1 — Add the `webdav` constant in `Prefs.java` — ✅ DONE (2026-10-13)

Find:

```java
    public static interface SyncMethod {
        public static final String DISABLED = "disabled";
        public static final String DROPBOX = "dropbox";
        public static final String HTTP = "http";
    }
```

Replace with:

```java
    public static interface SyncMethod {
        public static final String DISABLED = "disabled";
        public static final String DROPBOX = "dropbox";
        public static final String HTTP = "http";
        public static final String WEBDAV = "webdav";
    }
```

## Step 2 — Add `WEBDAV` to `syncMethodValues` in `Prefs.java` — ✅ DONE (2026-10-13)

Find:

```java
    private String[] syncMethodValues = {
            SyncMethod.DISABLED, SyncMethod.DROPBOX, SyncMethod.HTTP
    };
```

Replace with:

```java
    private String[] syncMethodValues = {
            SyncMethod.DISABLED, SyncMethod.DROPBOX, SyncMethod.HTTP, SyncMethod.WEBDAV
    };
```

## Step 3 — Enable the settings category for WebDAV in `Prefs.java` — ✅ DONE (2026-10-13)

Find:

```java
        // Only enable the HTTP Server Settings category if the user
        // selected HTTP as their method of syncing
        if (syncMethod.equals(SyncMethod.HTTP)) {
            httpServerSettingsCategory.setEnabled(true);
        } else {
            httpServerSettingsCategory.setEnabled(false);
        }
```

Replace with:

```java
        // Only enable the HTTP Server Settings category if the user
        // selected HTTP or WebDAV as their method of syncing
        if (syncMethod.equals(SyncMethod.HTTP) || syncMethod.equals(SyncMethod.WEBDAV)) {
            httpServerSettingsCategory.setEnabled(true);
        } else {
            httpServerSettingsCategory.setEnabled(false);
        }
```

## Step 4 — Mark the change as save-required when switching to/from WebDAV in `Prefs.java` — ✅ DONE (2026-10-13)

Without this, switching `disabled → webdav` is never persisted.

Find:

```java
                if (!newValue.equals(originalSyncMethod) &&
                        (newValue.equals(SyncMethod.HTTP) || originalSyncMethod.equals(SyncMethod.HTTP))) {
                    saveRequired = true;
                }
```

Replace with:

```java
                if (!newValue.equals(originalSyncMethod) &&
                        (newValue.equals(SyncMethod.HTTP) || originalSyncMethod.equals(SyncMethod.HTTP) ||
                         newValue.equals(SyncMethod.WEBDAV) || originalSyncMethod.equals(SyncMethod.WEBDAV))) {
                    saveRequired = true;
                }
```

## Step 5 — Persist `remoteLocation` / `authDBEntry` for WebDAV in `Prefs.java` — ✅ DONE (2026-10-13)

Find:

```java
            if (saveRequired) {
                if (syncMethodPreference.getValue().equals(SyncMethod.HTTP)) {
                    db.getDbOptions().setRemoteLocation(sharedURLPref.getText());
                    db.getDbOptions().setAuthDBEntry(sharedURLAuthPref.getValue());
                } else {
                    db.getDbOptions().setRemoteLocation(null);
                    db.getDbOptions().setAuthDBEntry(null);
                }
```

Replace with:

```java
            if (saveRequired) {
                if (syncMethodPreference.getValue().equals(SyncMethod.HTTP) ||
                        syncMethodPreference.getValue().equals(SyncMethod.WEBDAV)) {
                    db.getDbOptions().setRemoteLocation(sharedURLPref.getText());
                    db.getDbOptions().setAuthDBEntry(sharedURLAuthPref.getValue());
                } else {
                    db.getDbOptions().setRemoteLocation(null);
                    db.getDbOptions().setAuthDBEntry(null);
                }
```

## Step 6 — Fix the empty-string sync-method bug in `Utilities.java` — ✅ DONE (2026-10-13)

Find:

```java
        if (syncMethod == null) {
            if (remoteHTTPLocation != null) {
                syncMethod = Prefs.SyncMethod.HTTP;
            } else {
                syncMethod = Prefs.SyncMethod.DISABLED;
            }
        }
```

Replace with:

```java
        if (syncMethod == null) {
            if (remoteHTTPLocation != null && !remoteHTTPLocation.trim().isEmpty()) {
                syncMethod = Prefs.SyncMethod.HTTP;
            } else {
                syncMethod = Prefs.SyncMethod.DISABLED;
            }
        }
```

## Step 7 — Normalise `""` to `null` in `Utilities.getSyncMethod(Activity)` — ✅ DONE (2026-10-13)

Find:

```java
    public static String getSyncMethod(Activity activity) {
        UPMApplication app = (UPMApplication) activity.getApplication();
        String remoteHTTPLocation = app.getPasswordDatabase().getDbOptions().getRemoteLocation();
        SharedPreferences settings = activity.getSharedPreferences(Prefs.PREFS_NAME, Activity.MODE_PRIVATE);
        return getSyncMethod(settings, remoteHTTPLocation);
    }
```

Replace with:

```java
    public static String getSyncMethod(Activity activity) {
        UPMApplication app = (UPMApplication) activity.getApplication();
        String remoteHTTPLocation = app.getPasswordDatabase().getDbOptions().getRemoteLocation();
        if (remoteHTTPLocation != null && remoteHTTPLocation.trim().isEmpty()) {
            remoteHTTPLocation = null;
        }
        SharedPreferences settings = activity.getSharedPreferences(Prefs.PREFS_NAME, Activity.MODE_PRIVATE);
        return getSyncMethod(settings, remoteHTTPLocation);
    }
```

## Step 8 — Add `import java.io.OutputStream;` to `HTTPTransport.java` — ✅ DONE (2026-10-13)

Find:

```java
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStreamWriter;
```

Replace with:

```java
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
```

## Step 9 — Add the two WebDAV methods and make `addTrailingSlash` public in `HTTPTransport.java` — ✅ DONE (2026-10-13)

Find:

```java
    public void delete(String targetLocation, String fileToDelete) throws TransportException {
        delete(targetLocation, fileToDelete, null, null);
    }


    private String addTrailingSlash(String url) {
```

Replace with:

```java
    public void delete(String targetLocation, String fileToDelete) throws TransportException {
        delete(targetLocation, fileToDelete, null, null);
    }


    /**
     * WebDAV PUT of a file's raw bytes. Accepts 200/201/204.
     */
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
            os.write(Util.getBytesFromFile(file));
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


    /**
     * WebDAV DELETE. 404 counts as success (nothing to delete).
     */
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


    public String addTrailingSlash(String url) {
```

> Note: originally specified as package-private `String addTrailingSlash(String url)`,
> but `HTTPTransport` lives in `com.u17od.upm.transport` while
> `SyncDatabaseViaWebdavActivity` lives in `com.u17od.upm`, so package-private
> access does not cross the package boundary. Made `public` so Step 10 compiles.

## Step 10 — Create `SyncDatabaseViaWebdavActivity.java` — ✅ DONE (2026-10-13)

Create the file `src/com/u17od/upm/SyncDatabaseViaWebdavActivity.java` with the
full content below. It inherits download (plain GET) from
`SyncDatabaseViaHttpActivity` and only overrides the upload path.

```java
/*
 * Universal Password Manager
 * Copyright (c) 2010-2011 Adrian Smith
 *
 * This file is part of Universal Password Manager.
 *
 * Universal Password Manager is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * Universal Password Manager is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Universal Password Manager; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */
package com.u17od.upm;

import android.app.ProgressDialog;
import android.content.SharedPreferences;
import android.os.AsyncTask;
import android.util.Log;

import com.u17od.upm.database.AccountInformation;
import com.u17od.upm.transport.HTTPTransport;
import com.u17od.upm.transport.TransportException;

/**
 * Sync activity for a WebDAV (Nextcloud) server. Download reuses the inherited
 * plain GET path; only the upload path is WebDAV-specific (DELETE + PUT).
 */
public class SyncDatabaseViaWebdavActivity extends SyncDatabaseViaHttpActivity {

    @Override
    protected void uploadDatabase() {
        new UploadDatabaseWebdav().execute();
    }

    private class UploadDatabaseWebdav extends AsyncTask<Void, Void, Integer> {

        private static final int UPLOAD_OK = 0;
        private static final int UPLOAD_ERROR = 1;

        private ProgressDialog progressDialog;

        @Override
        protected void onPreExecute() {
            progressDialog = ProgressDialog.show(SyncDatabaseViaWebdavActivity.this, "", getString(R.string.uploading_database));
        }

        @Override
        protected Integer doInBackground(Void... params) {
            int result = UPLOAD_OK;

            String remoteURL = getPasswordDatabase().getDbOptions().getRemoteLocation();
            String remoteURLUsername = null, remoteURLPassword = null;
            String accountWithAuthDetails = getPasswordDatabase().getDbOptions().getAuthDBEntry();
            if (accountWithAuthDetails != null && accountWithAuthDetails.length() > 0) {
                AccountInformation account = getPasswordDatabase().getAccount(accountWithAuthDetails);
                remoteURLUsername = new String(account.getUserId());
                remoteURLPassword = new String(account.getPassword());
            }

            SharedPreferences settings = getSharedPreferences(Prefs.PREFS_NAME, 0);
            String trustedHostname = settings.getString(Prefs.PREF_TRUSTED_HOSTNAME, "");

            HTTPTransport transport = new HTTPTransport(getFileStreamPath(
                    FullAccountList.CERT_FILE_NAME), trustedHostname,
                    getApplicationContext().getFilesDir());
            String fileName = getPasswordDatabase().getDatabaseFile().getName();
            String targetURL = transport.addTrailingSlash(remoteURL) + fileName;
            try {
                transport.deleteWebdav(targetURL, remoteURLUsername, remoteURLPassword);
                transport.putWebdav(targetURL, getPasswordDatabase().getDatabaseFile(), remoteURLUsername, remoteURLPassword);
            } catch (TransportException e) {
                Log.e("FullAccountList", e.getMessage(), e);
                result = UPLOAD_ERROR;
            }

            return result;
        }

        @Override
        protected void onPostExecute(Integer result) {
            progressDialog.dismiss();
            if (result == UPLOAD_OK) {
                UIUtilities.showToast(SyncDatabaseViaWebdavActivity.this, R.string.db_sync_complete);
            } else {
                UIUtilities.showToast(SyncDatabaseViaWebdavActivity.this, R.string.problem_uploading);
            }
            finish();
        }

    }

}
```

## Step 11 — Register the activity in `AndroidManifest.xml` — ✅ DONE (2026-10-13)

Find:

```xml
        <activity android:name=".SyncDatabaseViaDropboxActivity"
                  android:theme="@style/Theme.Transparent">
        </activity>
```

Replace with:

```xml
        <activity android:name=".SyncDatabaseViaDropboxActivity"
                  android:theme="@style/Theme.Transparent">
        </activity>

        <activity android:name=".SyncDatabaseViaWebdavActivity"
                  android:theme="@style/Theme.Transparent">
        </activity>
```

## Step 12 — Route the Sync menu to the WebDAV activity in `FullAccountList.java` — ✅ DONE (2026-10-13)

Find:

```java
            } else if (Utilities.getSyncMethod(this).equals(Prefs.SyncMethod.DROPBOX)) {
                Intent i = new Intent(FullAccountList.this, SyncDatabaseViaDropboxActivity.class);
                startActivityForResult(i, SyncDatabaseActivity.SYNC_DB_REQUEST_CODE);
            }
```

Replace with:

```java
            } else if (Utilities.getSyncMethod(this).equals(Prefs.SyncMethod.DROPBOX)) {
                Intent i = new Intent(FullAccountList.this, SyncDatabaseViaDropboxActivity.class);
                startActivityForResult(i, SyncDatabaseActivity.SYNC_DB_REQUEST_CODE);
            } else if (Utilities.getSyncMethod(this).equals(Prefs.SyncMethod.WEBDAV)) {
                Intent i = new Intent(FullAccountList.this, SyncDatabaseViaWebdavActivity.class);
                startActivityForResult(i, SyncDatabaseActivity.SYNC_DB_REQUEST_CODE);
            }
```

## Step 13 — Add the string in `res/values/strings.xml` — ✅ DONE (2026-10-13)

Find:

```xml
    <string name="sync_method">Sync Method</string>
    <string name="sync_method_disabled">Disabled</string>
    <string name="sync_method_dropbox">Dropbox</string>
    <string name="sync_method_http">HTTP Server</string>
```

Replace with:

```xml
    <string name="sync_method">Sync Method</string>
    <string name="sync_method_disabled">Disabled</string>
    <string name="sync_method_dropbox">Dropbox</string>
    <string name="sync_method_http">HTTP Server</string>
    <string name="sync_method_webdav">WebDAV (Nextcloud)</string>
```

## Step 14 — Add the string in `res/values-de/strings.xml` — ✅ DONE (2026-10-13)

Find:

```xml
    <string name="sync_method">Sync Method</string>
    <string name="sync_method_disabled">Disabled</string>
    <string name="sync_method_dropbox">Dropbox</string>
    <string name="sync_method_http">HTTP Server</string>
```

Replace with:

```xml
    <string name="sync_method">Sync Method</string>
    <string name="sync_method_disabled">Disabled</string>
    <string name="sync_method_dropbox">Dropbox</string>
    <string name="sync_method_http">HTTP Server</string>
    <string name="sync_method_webdav">WebDAV (Nextcloud)</string>
```

## Step 15 — Add the string in `res/values-fr/strings.xml` — ✅ DONE (2026-10-13)

Find:

```xml
    <string name="sync_method">Méthode de synchronisation</string>
    <string name="sync_method_disabled">Désactivée</string>
    <string name="sync_method_dropbox">Dropbox</string>
    <string name="sync_method_http">Serveur HTTP</string>
```

Replace with:

```xml
    <string name="sync_method">Méthode de synchronisation</string>
    <string name="sync_method_disabled">Désactivée</string>
    <string name="sync_method_dropbox">Dropbox</string>
    <string name="sync_method_http">Serveur HTTP</string>
    <string name="sync_method_webdav">WebDAV (Nextcloud)</string>
```

## Step 16 — Add the string in `res/values-ru/strings.xml` — ✅ DONE (2026-10-13)

Find:

```xml
    <string name="sync_method">Sync Method</string>
    <string name="sync_method_disabled">Disabled</string>
    <string name="sync_method_dropbox">Dropbox</string>
    <string name="sync_method_http">HTTP Server</string>
```

Replace with:

```xml
    <string name="sync_method">Sync Method</string>
    <string name="sync_method_disabled">Disabled</string>
    <string name="sync_method_dropbox">Dropbox</string>
    <string name="sync_method_http">HTTP Server</string>
    <string name="sync_method_webdav">WebDAV (Nextcloud)</string>
```

## Step 17 — Add the entry to `res/values/arrays.xml` — ✅ DONE (2026-10-13)

The array order must match `syncMethodValues` in `Prefs.java`.

Find:

```xml
    <string-array name="sync_methods_human">
        <item >@string/sync_method_disabled</item>
        <item >@string/sync_method_dropbox</item>
        <item >@string/sync_method_http</item>
    </string-array>
```

Replace with:

```xml
    <string-array name="sync_methods_human">
        <item >@string/sync_method_disabled</item>
        <item >@string/sync_method_dropbox</item>
        <item >@string/sync_method_http</item>
        <item >@string/sync_method_webdav</item>
    </string-array>
```

## Step 18 — (Optional) Document WebDAV + app passwords in `README` — ✅ DONE (2026-10-13)

Added a "Database Sync" section (WebDAV/Nextcloud notes incl. the app-password
requirement for 2FA) plus a "Vibecoded" attribution section.

Add a short section stating that, for Nextcloud with 2FA enabled, the "Shared
URL auth" account must store an **app password** (Settings → Security → Devices
& sessions), and that the account password is rejected for WebDAV when 2FA is on.

## Step 19 — Build and verify — ✅ DONE (2026-10-13)

### Build
`env JAVA_HOME=/usr/lib/jvm/java-21-openjdk ./gradlew assembleDebug` →
**BUILD SUCCESSFUL** (only pre-existing deprecation notes; no new errors).
`SyncDatabaseViaWebdavActivity.class` + `SyncDatabaseViaWebdavActivity$UploadDatabaseWebdav.class`
were emitted. `sync_methods_human` has 4 items matching the 4 `syncMethodValues`.

### Runtime verification on the emulator (real Nextcloud)
Verified against `https://nextcloud.borger.co.at/remote.php/dav/files/test/upm/`
with `scripts/webdav-test.py` + `scripts/upm-ui.py`:

| Check | Result |
|---|---|
| Sync Method picker lists `WebDAV (Nextcloud)` | ✅ 4 entries |
| Selecting WebDAV keeps HTTP Server Settings editable | ✅ URL dialog opens |
| Switching to WebDAV persists (URL + auth account survive leaving Preferences) | ✅ |
| Sync menu routes to `SyncDatabaseViaWebdavActivity` | ✅ (logcat: START …SyncDatabaseViaWebdavActivity from uid of com.u17od.upm) |
| Download (GET, Basic auth from the auth account) | ✅ rev comparison reached upload |
| Upload when remote file is absent → DELETE→404 + PUT | ✅ remote db written |
| Upload when remote file exists → DELETE→204 + PUT | ✅ remote db replaced |
| Uploaded bytes | ✅ remote md5 == app `files/upm.db` md5 (`45ebc20e…`, 140 bytes) |
| No-op sync (same revision) | ✅ remote unchanged, 0 TransportExceptions |
| **First-ever upload** (remote db deleted → 404, fresh local db) | ✅ re-verified 2026-10-13: app uploaded on its own, remote md5 == app md5 (`7883ad45…`, 140 bytes), DELETE→404 tolerated |

Gotchas found while verifying (documented in `README_DEV.txt`):

* The auth account must hold the **remote** password. An account password that
  is not the Nextcloud password yields `Received the response code 401`.
* With a Shared URL configured, account edits are refused until a sync ran
  within 5 minutes (`Utilities.isSyncRequired`) — set Sync Method = Disabled to
  break the deadlock and fix credentials.
* The local WebDAV test server over plain http is unusable from the app:
  Android blocks cleartext (`java.io.IOException: Cleartext HTTP traffic to
  10.0.2.2 not permitted`), so the https Nextcloud instance was used instead.

Run:

```fish
env JAVA_HOME=/usr/lib/jvm/java-21-openjdk ./gradlew assembleDebug
```

It must succeed with no new errors. `get_errors` on the touched files should be
empty. Quick self-checks:

- `Prefs.SyncMethod.WEBDAV` resolves.
- `HTTPTransport.putWebdav` / `deleteWebdav` / `public addTrailingSlash` resolve from `SyncDatabaseViaWebdavActivity`.
- `R.string.sync_method_webdav` resolves and `sync_methods_human` still has the same length as `syncMethodValues`.
