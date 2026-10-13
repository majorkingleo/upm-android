---
name: upm-database-format
description: 'Explain or work with the UPM password database file format. USE FOR: understanding how the .db file is laid out (magic, version, salt, encrypted payload), how fields are flat-packed (4-digit length prefix + UTF-8), which cipher protects it (PBEWithSHA256And256BitAES-CBC-BC, 8-byte salt, 20 iterations), the revision counter and how sync uses it, the legacy DES format (v1.0.0/v1.1.0), writing a parser/writer, debugging "Problem reading database file", "Not a password database", or InvalidPasswordException. DO NOT USE FOR: UI/emulator testing (use upm-emulator-testing), sync transport issues, or build errors. INVOKES: read-only code reading in src/com/u17od/upm/database/ and src/com/u17od/upm/crypto/.'
---

# UPM database format

How a `.db` password database is encrypted and serialised on disk. The database
is a **single opaque file**: sync never edits fields, it moves the whole file,
and the revision decides who wins.

## Key source files

| Concern | File |
|---|---|
| Load/save, version handling | `src/com/u17od/upm/database/PasswordDatabase.java` |
| String serialisation | `src/com/u17od/upm/database/FlatPackObject.java` |
| Revision counter | `src/com/u17od/upm/database/Revision.java` |
| Sync settings stored in the db | `src/com/u17od/upm/database/DatabaseOptions.java` |
| One account record | `src/com/u17od/upm/database/AccountInformation.java` |
| Legacy version triplet (pre v2) | `src/com/u17od/upm/database/DatabaseHeader.java` |
| Crypto (AES) | `src/com/u17od/upm/crypto/EncryptionService.java` |
| Crypto (legacy DES) | `src/com/u17od/upm/crypto/DESDecryptionService.java` |

## On-disk layout (current, version 3)

```mermaid
flowchart LR
  A["'UPM' (3 ASCII bytes)"] --> B["DB version byte (0x03)"] --> C["salt (8 bytes)"] --> D["encrypted payload"]
```

| Offset | Size | Meaning |
|---|---|---|
| 0 | 3 | Magic `UPM` (bytes `55 50 4D`) |
| 3 | 1 | Database version byte: `0x02` (v2) or `0x03` (v3) |
| 4 | 8 | Salt (`EncryptionService.SALT_LENGTH = 8`) |
| 12 | rest | Ciphertext of the payload below |

The `UPM` magic is how `PasswordDatabase.load()` tells the modern format apart
from the legacy DES format, which starts directly with the salt.

## Decrypted payload

After PBE decryption, the payload is a stream of **flat-packed fields**:

```
Revision           : one length-prefixed string holding an int
DatabaseOptions    : two length-prefixed strings (remoteLocation, authDBEntry)
AccountInformation : zero or more, each five length-prefixed strings, read until EOF
```

`AccountInformation` field order: `accountName`, `userId`, `password`, `url`,
`notes` (all plaintext strings - the *whole* file is encrypted, so no per-field
encryption).

`DatabaseOptions.remoteLocation` is the "Shared URL" folder; `authDBEntry` is
the name of the account used for HTTP/WebDAV authentication. Both are stored in
the database file (not in Android SharedPreferences).

## Flat-pack encoding (`FlatPackObject`)

Every string (and every int, via its decimal string form) is:

```
LLLL<bytes>      LLLL = 4 ASCII decimal digits, zero-padded (e.g. "0005")
                 <bytes> = exactly LLLL bytes of the UTF-8 encoding (v3+)
```

* v3 reads/writes strings as UTF-8.
* v2 used the system default charset, so `PasswordDatabase.load()` picks
  `Util.defaultCharset()` when `dbVersion < 3` for backwards compatibility.
* Ints are packed as their decimal string (`Revision`, `DatabaseHeader` versions).

## Crypto

* Algorithm: `PBEWithSHA256And256BitAES-CBC-BC` (Bouncy Castle provider, `-BC`).
* Key: `SecretKeyFactory` + `PBEKeySpec(password)`.
* Parameters: `PBEParameterSpec(salt, 20)` - 8-byte salt, **20** iterations.
* Wrong password surfaces as `BadPaddingException` -> `InvalidPasswordException`.
* A fresh database generates a random 8-byte salt (`SHA1PRNG`); re-saving keeps
  the same salt.

## Legacy format (pre v2: 1.0.0 / 1.1.0)

No `UPM` magic. Layout:

```
salt (8 bytes)  +  PBEWithMD5AndDES-encrypted payload
```

The payload starts with a `DatabaseHeader` (three length-prefixed ints:
major/minor/patch) and the app can only *read* these old files - it never
writes them. On load the modern `EncryptionService` is still created so a
subsequent `save()` upgrades the file to v3.

## Revision counter and sync

* `Revision` is one int, flat-packed like any other field.
* `PasswordDatabase.save()` calls `revision.increment()` **every** save, so any
  edit (account change or even a preferences save) bumps the revision.
* `SyncDatabaseActivity.syncDb(...)` compares local vs remote revision:
  * remote missing or remote rev < local rev -> upload (local wins)
  * remote rev > local rev -> download (remote wins, replaces local)
  * equal -> "up to date", no transfer
* Because the whole file is opaque, "remote revision" comes from decrypting the
  downloaded file with the same master password/key.

## Practical sizes

* `scripts/test.db` is 76 bytes: `UPM` (3) + version (1) + salt (8) + one AES
  block (16) padded ciphertext for an empty database (revision + two empty
  option strings). The payload size is always a multiple of the AES block size.
* Each account adds roughly 20 + (sum of its five field byte lengths).

## Gotchas

* `getBytes()` reads the 4 length digits byte-by-byte and throws `EOFException`
  at end of stream - `load()` relies on that `EOFException` to stop reading
  accounts. A truncated file therefore surfaces as a short/empty account list,
  not a clean error.
* A file without the `UPM` magic that also fails DES decrypt is reported as
  `ProblemReadingDatabaseFile("Either your password is incorrect or this file
  isn't a UPM password database")`.
* Fields have no type tags or checksums - only the AES padding and the revision
  math protect against tampering, not integrity.
* `DatabaseOptions` normalises `null` to `""` (`setRemoteLocation(null)` etc.),
  so a freshly configured option is an empty string, never a `null`.
