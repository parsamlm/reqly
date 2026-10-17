# SQLite

[SQLite](https://sqlite.org), for the core's storage on Windows. GRDB links a SQLite the system provides; Windows has none to build against, so Reqly brings its own. The Mac and Linux use their system's SQLite. SQLite is in the [public domain](https://sqlite.org/copyright.html).

- Version: 3.53.4, from `sqlite-amalgamation-3530400.zip` on the [download page](https://sqlite.org/download.html).
- SHA3-256 of the zip: `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`, as the download page lists it.
- `sqlite3.c` and `sqlite3.h` are the zip's files, unchanged. `windows/scripts/build-sqlite.ps1` builds them into `sqlite3.lib`, with full-text search (FTS5) and WAL snapshots, which Reqly's search and GRDB use, and like the Mac's SQLite, with WAL commits that don't wait for the disk (`SQLITE_DEFAULT_WAL_SYNCHRONOUS=1`).

To update, replace the two files with a newer release's and change the version above.
