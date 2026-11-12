# uc-apex-sync

Merge-safe APEXlang imports for Oracle APEX apps in Git.

You edit an APEX app as APEXlang files in your repo, while a colleague edits the
same app in the App Builder on the shared dev database. A plain `apex import`
overwrites their work. `uc-apex-sync` exports the app first, lets Git merge
their changes with yours, and only then imports. On APEX 26.2+ it imports only
the components you changed, so the rest of the app is not touched at all.

```
$ uc-apex-sync sync
==> committed local changes in src/app/my-app
==> exporting app 100 from dev
==> DB has changes since the last sync:
 src/app/my-app/pages/p00003-orders.apx | 2 +-
==> validating src/app/my-app
==> changes to import into dev:
 src/app/my-app/pages/p00001-home.apx | 4 ++--
==> import: only these files (APEX 26.2+):
    pages/p00001-home.apx
Import into dev? [y/N] y
==> importing 1 file(s)
==> recording the new DB state in apex-db
==> done; apex-db matches the DB
```

It is a single Bash script without dependencies beyond Git and SQLcl. Install
it once and call it from your projects' makefiles. Background and
motivation: [Make APEXlang Easy: Makefiles and Merge-Safe Imports](https://hartenfeller.dev/blog/make-apexlang-easy).

## How it works

The local `apex-db` branch records the last exported database state. Git uses
that shared history to compare your local edits with changes made in App
Builder and merge them into your working branch.

```
main      ──A───B (your edits)────────M───────R
              \                      /       /
apex-db        A────────S (DB export)───────S' (DB after import)
```

`sync` runs these steps and stops at the first problem. Every step checks where
it stands, so you can run it again after fixing the reported problem.

1. **Commit your pending changes** in the app dir (asks for a message; other
   files in the repo are left alone).
2. **Export the app** into a separate worktree on `apex-db` and commit it as a
   DB snapshot, along with an ID- and timestamp-independent checksum of the app.
3. **Merge `apex-db` into your branch.** Different parts changed: Git merges
   them. Same lines changed: you get normal merge conflicts; resolve, commit,
   then run `sync` again. No import happens while conflicts are unresolved.
4. **Validate** the merged result with `apex validate`.
5. **Plan the import.** Only changed components on APEX 26.2+, otherwise the
   full app (see below). You confirm (or pass `-y`).
6. **Check nobody saved meanwhile.** The checksum is read again; if the app
   changed since the export, `sync` aborts. Run it again to merge that change.
7. **Import.**
8. **Export again** and record that as the new `apex-db`. APEX normalizes the
   formatting of what you import, and that normalized version is merged back
   so the next sync starts from what is really in the DB.

### Partial imports (APEX 26.2+)

APEX 26.2 / SQLcl 26.3 added `apex import -files`, which imports only the given
component files. `sync` uses it by default: it imports exactly the files that
differ between `apex-db` and your branch. Whatever others save on other
components, even during the import, can't be overwritten, and the import is
faster.

| Change                                              | Import                                                   |
| --------------------------------------------------- | -------------------------------------------------------- |
| `.apx` file changed or added                        | that file                                                |
| static file, script, etc. that belongs to an `.apx` | the owning `.apx` (e.g. `shared-components/static-files.apx`) |
| `.apx` file deleted                                 | full app (a partial import cannot delete components)     |
| component types APEX refuses to import on their own (e.g. install scripts) | full app, after asking               |
| anything else (`deployments/*.json`, paths with spaces) | full app                                             |
| APEX older than 26.2                                | full app                                                 |

`--full` forces a full import.

### Importing only some of your changes

```sh
uc-apex-sync sync pages/p00010-orders.apx
uc-apex-sync sync 'pages/p0001*' shared-components/lovs/
```

`sync` still exports and merges the whole app, but imports only changes that
match the supplied paths. Paths are relative to `APP_DIR` and accept Git glob
patterns; quote patterns so your shell does not expand them first.

Other local changes remain pending until a later `sync`; `status` shows them.
Selecting paths requires partial imports (APEX 26.2+ and SQLcl 26.3+). If the
selection requires a full import, such as when a component was deleted, the
command stops instead.

## Requirements

- Git 2.28+ and Bash (3.2 is fine, so the macOS default works; on Windows use WSL)
- SQLcl with APEXlang support (`apex export -exptype APEXLANG`); 26.3+ for partial imports
- APEX 26.1+; 26.2+ for partial imports
- A SQLcl saved connection (`sql -name <name>`) to the app's parsing schema or a
  user with access to the workspace

## Install

Clone the repo once and link the script onto your PATH. Upgrading is a
`git pull`, for all your projects at once.

```sh
git clone https://github.com/United-Codes/uc-apex-sync.git ~/.local/share/uc-apex-sync
make -C ~/.local/share/uc-apex-sync install    # symlinks ~/.local/bin/uc-apex-sync

# upgrade
git -C ~/.local/share/uc-apex-sync pull
```

Make sure `~/.local/bin` is on your `PATH`. If it is missing, add
`export PATH="$HOME/.local/bin:$PATH"` to your shell profile (for example,
`~/.zshrc`), then open a new terminal.

To use a different install directory, run
`make -C ~/.local/share/uc-apex-sync install BIN_DIR=/usr/local/bin`.
To remove the link, run `make -C ~/.local/share/uc-apex-sync uninstall`
(with the same `BIN_DIR` if you changed it).

**Fallback: copy it into the project.** If you can't install it on every
machine (CI, a colleague without the clone), or want to pin a version for a
project, commit the script as `scripts/uc-apex-sync.sh`. The example makefile
uses that copy when it exists and the installed command otherwise.

```sh
mkdir -p scripts
curl -fsSL -o scripts/uc-apex-sync.sh \
  https://raw.githubusercontent.com/United-Codes/uc-apex-sync/main/uc-apex-sync.sh
chmod +x scripts/uc-apex-sync.sh
```

## Project setup

1. Copy [`examples/makefile`](examples/makefile) into your project and adjust
   `APP_ID`, `EXPORT_DIR`, and `APP_DIR`. The export creates a folder named
   after the app alias in lower case: for alias `MY-APP` and
   `EXPORT_DIR=./src/app`, use `APP_DIR=./src/app/my-app`. Set `SYNC_BRANCH`
   if you work on a branch other than `main`.

   Each developer copies [`examples/.env.example`](examples/.env.example) to
   `.env` in the project root and sets `DB_CONN` to their SQLcl saved connection
   name. Add `.env` to `.gitignore` to keep it out of Git.

   The makefile is optional. To run `uc-apex-sync` directly, export the
   [configuration variables](#configuration) in your shell first; the script
   does not load `.env` itself. Run project commands from the repository root.

2. Export the app once and commit it (skip if it is already in the repo):

   ```sh
   make export-app && git add src/app && git commit -m "Export app"
   ```

3. Create the `apex-db` branch:

   ```sh
   make sync-init            # or: uc-apex-sync init
   ```

   `init` exports the app and looks for the newest commit whose app dir is
   identical, so it works even if you have local commits since the last export.
   If the DB has changed since, no commit matches; pass the commit of your
   last export explicitly: `make sync-init BASE=<commit>`.

From then on, use `make sync-app` (or `uc-apex-sync sync`) to import changes.
If Git reports merge conflicts, resolve them in your working branch, commit
the resolution, and run the same command again.

Every developer runs `init` once per clone. `apex-db` is a local branch; don't
push it, since it describes the DB as _your_ clone last saw it.

## Commands

| Command                           | Make target          | What it does                                                     |
| --------------------------------- | -------------------- | ---------------------------------------------------------------- |
| `init [<commit>]`                 | `sync-init [BASE=]`  | create `apex-db` at the commit that matches the DB              |
| `sync [-y] [-m msg] [--full] [<path>...]` | `sync-app [YES=1] [MSG=] [FULL=1] [FILES=]` | export, merge, validate, import |
| `pull [-m msg]`                   | `sync-pull`          | export and merge only; never writes to the DB                    |
| `status [<path>...]`              | `sync-status`        | what `sync` would import; offline                               |

## Configuration

The script reads these environment variables. The example makefile passes
them from its settings and `.env`. `DB_CONN`, `APP_ID`, and `APP_DIR` are
required for database commands; `status` only requires `APP_DIR`.

| Variable         | Default    | Description                                                             |
| ---------------- | ---------- | ----------------------------------------------------------------------- |
| `DB_CONN`        |            | SQLcl saved connection name                                             |
| `APP_ID`         |            | application id                                                          |
| `APP_DIR`        |            | app dir in the repo, e.g. `src/app/my-app`. The export writes to its parent and names the folder after the app alias in lower case, so the two must match. |
| `SYNC_BRANCH`    | `main`     | the branch you import from; `sync` refuses to run on any other          |
| `DB_BRANCH`      | `apex-db`  | branch mirroring the DB; use one per app or per DB if a repo holds several |
| `APEX_WORKSPACE` |            | workspace name, if the connection can see several                       |
| `SQLCL`          | `sql`      | SQLcl executable                                                        |
| `MSG`            |            | commit message for pending app changes (same as `-m`)                   |

## Limits

- **The window between check and import.** Step 6 narrows the risk but can't
  remove it: if someone saves in the Builder in the seconds between the
  checksum check and the end of the import, that save may be overwritten. With
  partial imports this only affects the components being imported. On a busy
  shared database, give your team a heads-up.
- **Validation is not a guarantee.** A merge can be clean for Git and
  `apex validate` and still fail on import (e.g. a missing database object).
  The import is then reported as failed; check the app before running again.
- **Formatting.** After each import, APEX's normalized formatting of the
  imported files is merged back into your branch. Where that conflicts with
  your text, the DB version wins (`-X theirs`), since it is what was imported.

## Tests

```sh
make test              # no database needed (uses test/fake-sql)
test/run.sh conflict   # only tests whose name contains "conflict"
make lint              # shellcheck
```

`test/fake-sql` stands in for SQLcl and keeps the "database" in a directory. It
reproduces the behavior the script depends on, as observed with SQLcl 26.3 and
APEX 26.2: SQLcl exits 0 even on errors, `-files` takes only existing `.apx`
files and refuses install scripts without importing anything, partial imports
don't delete, and exports normalize formatting.

The integration test runs the main scenarios against a real database. It
copies an existing app to a scratch application id (default 9154, overwritten
and removed afterwards); the source app is only exported.

```sh
IT_DB_CONN=my-conn IT_SOURCE_APP_ID=154 test/integration.sh
```

## License

[MIT](LICENSE)
