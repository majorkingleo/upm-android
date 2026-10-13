== Release Instructions ==
1. Update README with the release notes
2. Update the versionCode and versionName in AndroidManifest.xml
3. Build the App Bundle
    - Build -> Generate Signed App Bundle or APK
    - Android App Bundle
    - Enter keystore details
4. Release the application on https://play.google.com/console/
5. Create a source tarball and upload to SourceForge (git archive master | gzip > upm-android-1.x-src.tar.gz)
6. Upload the APK to SourceForge
7. git tag -a v1.x -m 1.x
8. git push
9. git push --tags


== WebDAV (Nextcloud) sync testing ==
The scripts/ directory contains helpers used to verify the WebDAV sync path
end to end. All of them are python3 with no third-party dependencies.

  scripts/webdav-test.py        drive the REMOTE side over WebDAV
      check                     reachability + Basic auth + PUT/GET/DELETE probe
      status                    compare the remote db with the local one
      push | pull | delete      move the db file explicitly
      reset                     delete the remote db, then push the local one

      Credentials come from files, never from the command line:
        --password-file     remote password          (default: ./password.txt)
        --db                local db for push/pull   (default: scripts/upm.db, else scripts/test.db)
        --db-password-file  the db master password   (default: <db>.password)
      Defaults target https://nextcloud.borger.co.at/remote.php/dav/files/test/upm/,
      override with --url / --user / --remote-file.

  scripts/webdav-test-server.py  local WebDAV-ish server for offline tests
      Serves a directory with GET/PUT/DELETE/PROPFIND and optional Basic auth,
      logging every request. Point the app at http://10.0.2.2:PORT/upm/ - but
      note Android blocks cleartext http on targetSdk >= 28, so this only works
      from a build that permits cleartext; for real runs use a https Nextcloud.

  scripts/upm-ui.py              drive the app on the emulator
      dump                      show what is on screen (text + bounds; --full adds class/enabled)
      tap "Text"                tap an element by its text (--contains, --index)
      tapxy X,Y                 tap raw coordinates (e.g. an empty text field)
      wait "Text"              wait until an element appears (--timeout)
      type "..." | clear | key BACK | focus | shot FILE

Manual test recipe (emulator):
  1. scripts/emulator-run.sh            (VSCode task: Android: run on emulator)
  2. adb shell svc power stayon true    (otherwise taps silently stop working
                                         after the display times out)
  3. Put a known db in place: force-stop the app and
       adb shell "run-as com.u17od.upm sh -c 'cat > files/upm.db'" < scripts/test.db
     Its master password is in scripts/test.db.password.
  4. In the app: Preferences -> Sync Method = WebDAV (Nextcloud),
     Shared URL = the WebDAV folder, HTTP Authentication Account = the account
     whose password is the REMOTE password (app passwords qualify).
  5. Sync from the overflow menu, then compare with scripts/webdav-test.py status:
     after a successful upload the remote db must be byte-identical to the
     app's own files/upm.db.

  Known gotchas:
    * The auth account must store the remote (app) password - a normal account
      password is rejected with HTTP 401 when 2FA is enabled on Nextcloud.
    * With a Shared URL set, the app refuses account edits ("sync required")
      until a sync has run within the last 5 minutes (Utilities.isSyncRequired).
      Temporarily set Sync Method = Disabled to get around it.
    * EMULATOR_GPU=swiftshader_indirect is the stable renderer but it may never
      paint the framebuffer (screencap is black); uiautomator dumps still work,
      so scripts/upm-ui.py is the reliable way to "see" the app.
    * The TRANSPARENT sync activities are not exported, so `am start` cannot
      launch them - go through the overflow menu.

