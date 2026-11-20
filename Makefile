SHELL := /bin/bash
ROOT := $(shell cd "$(dir $(lastword $(MAKEFILE_LIST)))" && pwd)

.PHONY: all build test verify measure soak install uninstall dist clean help

all: build

build:
	@$(ROOT)/scripts/build.sh

test:
	@$(ROOT)/scripts/test.sh

verify: build
	@$(ROOT)/scripts/verify.sh

verify-real-music: build
	@MAG_VERIFY_REAL_MUSIC=1 $(ROOT)/scripts/verify.sh

verify-login-item: build
	@MAG_VERIFY_LOGIN_ITEM=1 $(ROOT)/scripts/verify.sh

measure: build
	@$(ROOT)/scripts/measure.sh

soak: build
	@SOAK_SECONDS=$${SOAK_SECONDS:-1800} $(ROOT)/scripts/soak.sh

install: build
	@$(ROOT)/scripts/install-user.sh

uninstall:
	@$(ROOT)/scripts/uninstall.sh

dist: build test verify
	@$(ROOT)/scripts/make-dist.sh

clean:
	@rm -rf $(ROOT)/build

help:
	@echo "Soramimi"
	@echo "  make build            build build/Soramimi.app (ad-hoc signed)"
	@echo "  make test             run pure-logic unit tests"
	@echo "  make verify           full static + runtime verification"
	@echo "  make verify-real-music  verification including a real Apple Music launch test"
	@echo "  make verify-login-item  verification including login-item register/unregister (mutates Login Items)"
	@echo "  make measure          memory/CPU/size measurements"
	@echo "  make soak             long-running stability soak (SOAK_SECONDS=...)"
	@echo "  make install          install to ~/Applications (no sudo)"
	@echo "  make uninstall        remove from ~/Applications and reset state"
	@echo "  make dist             build a zip of the app and a source tarball"
	@echo "  make clean            remove build artifacts"
