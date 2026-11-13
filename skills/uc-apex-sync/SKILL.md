---
name: uc-apex-sync
description: Merge-safe import of APEXlang files into an Oracle APEX app with uc-apex-sync. Use when the user wants to import, deploy, sync or push APEXlang (.apx) changes to an APEX app on a shared dev database, pull in App Builder changes made by colleagues, set up uc-apex-sync in a project (makefile, apex-db branch), or resolve merge conflicts from a sync.
---

# uc-apex-sync

`uc-apex-sync` imports APEXlang changes into an APEX app without overwriting
changes colleagues made in the App Builder. It exports the app first, merges the
export into your branch with Git, validates, and only then imports (only the
changed components on APEX 26.2+ / SQLcl 26.3+).

Never use a plain `apex import` (or `make import-app`) on a shared database when
`uc-apex-sync` is set up: it overwrites other people's work.

## Check the setup first

1. Is the tool available? `command -v uc-apex-sync` or `./scripts/uc-apex-sync.sh`.
   If not, tell the user to install it (see https://github.com/United-Codes/uc-apex-sync#install).
2. Does the project have a makefile with `sync-*` targets? If so, prefer
   `make sync-...`: it passes `DB_CONN`, `APP_ID`, `APP_DIR` from `.env`.
   Otherwise those variables must be exported (`DB_CONN`, `APP_ID`, `APP_DIR`;
   optional `SYNC_BRANCH`, `DB_BRANCH`, `APEX_WORKSPACE`, `SQLCL`).
3. Does the local `apex-db` branch exist (`git branch --list apex-db`)? If not,
   run `init` once (see below).

Run commands from the repository root.

## Commands

| Command | Make target | Purpose |
| --- | --- | --- |
| `uc-apex-sync status [<path>...]` | `make sync-status` | what `sync` would import; offline, safe |
| `uc-apex-sync pull [-m msg]` | `make sync-pull` | export + merge only; never writes to the DB |
| `uc-apex-sync sync [-y] [-m msg] [--full] [<path>...]` | `make sync-app [YES=1] [MSG=] [FULL=1] [FILES=]` | export, merge, validate, import |
| `uc-apex-sync init [<commit>]` | `make sync-init [BASE=]` | one-time: create `apex-db` at the commit matching the DB |

## Workflow

1. Run `status` to preview. It needs no database.
2. Run `sync`. It commits pending changes in the app dir (needs a message: pass
   `-m`/`MSG=`), exports into the `apex-db` branch, merges, validates, shows the
   plan and asks for confirmation.
3. **Importing writes to a shared database.** Do not pass `-y`/`YES=1` unless the
   user explicitly said to import without asking. Otherwise let the user
   confirm the prompt themselves (suggest `! make sync-app`).
4. To import only part of the changes, pass paths relative to `APP_DIR`
   (Git globs, quoted): `uc-apex-sync sync 'pages/p0001*'`. Other changes stay
   pending. Requires partial imports; stops if a full import would be needed.
5. `--full` forces a full app import. Deleting an `.apx` file also requires one.
   Confirm with the user before forcing it.

## When it stops

`sync` stops at the first problem and can simply be re-run after fixing it.

- **Merge conflicts**: resolve them in the working branch (SYNC_BRANCH), commit
  the resolution, run `sync` again. No import happens while conflicts exist.
  Look at the conflicting files first and ask the user when the choice is not
  obvious: one side is a colleague's work.
- **App changed since the export**: someone saved in the Builder during the
  sync. Run `sync` again to merge that change.
- **Validation failed**: fix the reported `.apx` problem, commit, re-run.
- **Import failed**: check the app state before running again.
- **Wrong branch**: `sync` refuses to run unless on `SYNC_BRANCH` (default `main`).

## Rules

- `apex-db` is a local branch mirroring the DB as this clone last saw it. Never
  push it, never commit to it by hand, never delete it casually.
- `init` fails with no matching commit if the DB changed since the last export;
  then pass the commit of the last export: `init <commit>`.
- After an import, APEX's normalized formatting is merged back into the branch;
  expect a follow-up merge commit.
