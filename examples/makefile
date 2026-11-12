# Export, import and merge-safe sync of an APEX app in APEXlang format.
#
# Copy this makefile and uc-apex-sync.sh into your project:
#
#   makefile
#   scripts/uc-apex-sync.sh
#   src/app/<app-alias>/...      (created by make export-app)
#
# The connection name differs per developer, so it lives in a local, untracked
# .env file. Copy .env.example to .env and adjust.
# Precedence: command line > .env > defaults below, e.g.
#   make export-app DB_CONN=my-conn

-include .env

DB_CONN     ?= my_app@dev.example.com
APP_ID      ?= 100
# The APEXlang export appends a folder named after the app alias (lower case)
# to -dir, so -dir is the parent and the app lands in $(EXPORT_DIR)/my-app.
EXPORT_DIR  ?= ./src/app
APP_DIR     ?= $(EXPORT_DIR)/my-app
# sync-*: the branch you import from, and the branch mirroring the DB.
SYNC_BRANCH ?= main
DB_BRANCH   ?= apex-db
SYNC        ?= ./scripts/uc-apex-sync.sh
SQLCL       ?= sql

SYNC_ENV = DB_CONN="$(DB_CONN)" APP_ID="$(APP_ID)" APP_DIR="$(APP_DIR)" \
	SYNC_BRANCH="$(SYNC_BRANCH)" DB_BRANCH="$(DB_BRANCH)" SQLCL="$(SQLCL)"

.DEFAULT_GOAL := help

# List the available commands.
# Each target is described by the first line of the comment block above it.
help:
	@awk '/^#/ { if (!c) d = substr($$0, 3); c = 1; next } \
	  /^[a-z][a-z-]*:/ && c { sub(/:.*/, ""); printf "  \033[1;36m%-14s\033[0m %s\n", $$0, d } \
	  { c = 0 }' $(firstword $(MAKEFILE_LIST))

# Export the app from $(DB_CONN) into $(APP_DIR), overwriting local changes.
export-app:
	printf 'apex export -applicationid $(APP_ID) -exptype APEXLANG -dir $(EXPORT_DIR) -overwrite-files\nexit\n' | $(SQLCL) -name "$(DB_CONN)"

# Merge-safe import: export the DB, merge it into SYNC_BRANCH, validate, import.
# Only changed components are imported (APEX 26.2+). Re-run after resolving
# conflicts.
#   make sync-app                       asks before importing
#   make sync-app YES=1                 no prompt
#   make sync-app MSG="..."             commit message for pending app changes
#   make sync-app FILES="pages/p00010*" import only changes to these files
#   make sync-app FULL=1                import the whole app
sync-app:
	MSG="$(MSG)" $(SYNC_ENV) $(SYNC) sync $(if $(YES),-y) $(if $(FULL),--full) $(FILES)

# Export the DB and merge its changes into SYNC_BRANCH, without importing.
sync-pull:
	MSG="$(MSG)" $(SYNC_ENV) $(SYNC) pull

# Show what sync-app would import (offline).
sync-status:
	@$(SYNC_ENV) $(SYNC) status $(FILES)

# One-time: create DB_BRANCH at the commit whose app dir matches the DB.
#   make sync-init              find that commit automatically
#   make sync-init BASE=26ce6c5 use this commit
sync-init:
	$(SYNC_ENV) $(SYNC) init $(BASE)

# Import $(APP_DIR) as is, overwriting any Builder changes. Prefer sync-app.
import-app:
	printf 'apex import -input $(APP_DIR)\nexit\n' | $(SQLCL) -name "$(DB_CONN)"

# Check the .apx sources without a database connection.
validate-app:
	printf 'apex validate -input $(APP_DIR)\nexit\n' | $(SQLCL) -nolog

# Show which connection the targets above would use.
show-conn:
	@echo "DB_CONN=$(DB_CONN) APP_ID=$(APP_ID) APP_DIR=$(APP_DIR)"

.PHONY: help export-app sync-app sync-pull sync-status sync-init import-app validate-app show-conn
