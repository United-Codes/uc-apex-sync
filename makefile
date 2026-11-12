# Install uc-apex-sync as a command and work on it.
#
#   make install                  symlink into ~/.local/bin (upgrade: git pull)
#   make install BIN_DIR=/usr/local/bin

BIN_DIR ?= $(HOME)/.local/bin

.DEFAULT_GOAL := help

# List the available commands.
help:
	@awk '/^#/ { if (!c) d = substr($$0, 3); c = 1; next } \
	  /^[a-z][a-z-]*:/ && c { sub(/:.*/, ""); printf "  \033[1;36m%-10s\033[0m %s\n", $$0, d } \
	  { c = 0 }' $(firstword $(MAKEFILE_LIST))

# Symlink uc-apex-sync into BIN_DIR (default ~/.local/bin), so git pull upgrades it.
install:
	@mkdir -p "$(BIN_DIR)"
	ln -sf "$(CURDIR)/uc-apex-sync.sh" "$(BIN_DIR)/uc-apex-sync"
	@case ":$$PATH:" in *":$(BIN_DIR):"*) ;; \
	  *) echo "note: $(BIN_DIR) is not on your PATH; add it in your shell profile" ;; esac
	@"$(BIN_DIR)/uc-apex-sync" --version

# Remove the symlink from BIN_DIR.
uninstall:
	rm -f "$(BIN_DIR)/uc-apex-sync"

# Run the tests (no database needed).
test:
	test/run.sh

# Run shellcheck.
lint:
	shellcheck -x uc-apex-sync.sh test/*.sh test/fake-sql

.PHONY: help install uninstall test lint
