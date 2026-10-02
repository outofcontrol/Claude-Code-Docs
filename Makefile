# SPDX-FileCopyrightText: 2026 OutofControl
# SPDX-License-Identifier: Apache-2.0 OR MIT

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
CONFIG_DIR ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/claude-docs-watch

.PHONY: install uninstall test lint

install:
	install -d "$(BINDIR)" "$(CONFIG_DIR)"
	install -m 755 bin/claude-docs-watch "$(BINDIR)/claude-docs-watch"
	test -e "$(CONFIG_DIR)/config" || install -m 600 examples/config.example "$(CONFIG_DIR)/config"

uninstall:
	rm -f "$(BINDIR)/claude-docs-watch"

test:
	bash tests/run.sh

lint:
	shellcheck bin/claude-docs-watch tests/run.sh
	reuse lint
