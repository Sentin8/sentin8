# SPDX-FileCopyrightText: Copyright Logically Magic Inc. <hello@logicallymagic.com>
# SPDX-FileCopyrightText: Copyright Hamid Jahanzad <Hamid@Jahanzad.com>
# SPDX-FileCopyrightText: Copyright Contributors to the Sentin8
# SPDX-License-Identifier: Apache-2.0

# Makefile — sentin8/ platform group (RS §4.4)
#
# Group build in DAG order: SDK -> starters -> services. Infra lives here
# (the whole tree's compose file, §2.2.1). Each child repo is independent;
# its own `cargo build` is self-sufficient — this file is convenience.
#
# Zero vertical reach-in (AGENTS rule 1): this group builds and spawns ONLY
# sentin8-* binaries. Verticals are built by their own group Makefiles and
# enter the captain via SENTIN8_CAPTAIN_CATALOG_PATHS (root .env), keeping
# this group vertical-agnostic.

SHELL := /bin/bash
CARGO ?= cargo

SERVICES := auth acme proxy bus db storage post stat secrets func cron flow ai sys app bff web

# Cargo profile flag: empty = dev/debug (default), --release = release.
# Set it on the command line (RELEASE=--release make start) or use the
# equivalent *-release / *-debug wrapper targets defined further below.
RELEASE ?=

# ── Build identity stamps (BUILDID-1, sentin8-build-info README) ────────
# Every cargo invocation through this Makefile is stamped with the repo's
# own git short hash (SENTIN8_GIT_SHA) and the active cargo profile
# (SENTIN8_BUILD_PROFILE), which sentin8-build-info bakes into the binary
# via option_env! — banners and /v1/health then render
# `{version}+{hash}[.d]` so operators can verify WHICH binary runs.
#
# DELIVERY SHAPE (STATUSID-1): the stamps ride the SAME shell line as
# the cargo command — make runs each recipe LINE in its own shell, so
# the original multi-line `define` (an `export …` recipe line before the
# cargo line) evaporated before cargo started and stamped NOTHING.
# $(stamp_env,repo) expands to an env-PREFIX prepended to the command;
# the `$$()` shell substitution (not make's `$(shell)`) keeps it working
# inside recipe loops where the repo dir is a shell variable.
#
# EVERY cargo invocation is stamped — builds, tests, AND the
# `cargo run` control paths (start/stop/status/enroll): cargo
# fingerprints option_env!, so an unstamped `cargo run` would REBUILD
# a freshly stamped binary back to an unstamped identity (flip-flop).
# Packaging (sentin8-packaging/debian/rules) sets its own stamps; ad-hoc
# cargo builds stay unstamped (fallbacks: bare version +
# debug_assertions cfg).
#
# A repo without .git (vendored/exported source) keeps an EMPTY hash —
# sentin8-build-info omits the +hash part rather than stamping a lie.
#
# Usage inside a recipe (prefix on the cargo command itself, AFTER the
# cd into the repo — the hash resolves from the shell's cwd):
#	@cd sentin8-auth && $(call stamp_env,sentin8-auth) $(CARGO) build $(RELEASE)
# The hash resolves via PLAIN `git rev-parse` (no -C path): the stamp
# expands on the same shell line AFTER the `cd`, so a repo-relative
# `git -C <repo>` would resolve from INSIDE the repo and miss, stamping
# every binary EMPTY (the first STATUSID-1 delivery did exactly that).
# The call argument is documentary — it names the repo the stamp
# applies to; the expansion itself is cwd-based.
stamp_env = SENTIN8_BUILD_PROFILE=$(if $(RELEASE),release,debug) SENTIN8_GIT_SHA=$$(git rev-parse --short HEAD 2>/dev/null)

# Absolute tree run dir (RS §4.5.1-2): run_dir() defaults to cwd-relative
# ".run", so the CLI must not resolve the control socket/logs per cwd.
# One tree-root .run for every invocation. (TREE_ROOT differs per repo —
# here the group dir IS inside the tree, so ../ = the tree root.)
RUNDIR := $(abspath ..)/.run
RUNDIR_ENV := SENTIN8_RUN_DIR=$(RUNDIR) SENTIN8_LOG_DIR=$(RUNDIR)/logs SENTIN8_CAPTAIN_SOCK=$(RUNDIR)/captain.sock

# Base targets that take the *-release / *-debug suffixed wrapper forms.
PROFILED := build start stop status

# Binary prefix (colon chain) for captain spawning: every PLATFORM repo's
# target/{debug|release} dir, matching the active RELEASE mode. Computed
# lazily from what exists on disk. Verticals are NOT in this chain — their
# group Makefiles handle their own trees; captain rides their
# SENTIN8_CAPTAIN_CATALOG_PATHS catalogs from the root .env.
BINARY_DIR = $(if $(RELEASE),release,debug)
# Absolute (abspath) — the CLI runs cargo-run from sentin8-cli/, and a
# spawned captain resolves prefix entries relative to ITS cwd; relative
# entries never resolve (RS §4.5.1-1).
BINARY_PREFIX = $(subst $(space),:,$(foreach d,$(shell for d in sentin8-* ; do [ -d "$$d/target/$(BINARY_DIR)" ] && echo "$$d/target/$(BINARY_DIR)"; done),$(abspath $(d))))
space := $(empty) $(empty)

.PHONY: help build build-sdk build-starters build-services build-one start stop status \
	$(PROFILED:%=%-release) $(PROFILED:%=%-debug) infra-up infra-down enroll test test-openapi heads \
	conformance-up conformance-down conformance-purge conformance-seed

help: ## Show this help
	@echo "sentin8/ platform group"
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Profile wrappers: build start stop status take a"
	@echo "-release / -debug suffix, e.g. make start-release == RELEASE=--release make start."

build: build-sdk build-starters build-services ## Build the group in DAG order (RELEASE=--release for release)

build-sdk: ## Build the shared workspace (EVERYTHING depends on this)
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-sdk && $(call stamp_env,sentin8-sdk) $(CARGO) build $(RELEASE) --workspace

build-starters: build-sdk ## Build cli + captain (before any service)
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-cli && $(call stamp_env,sentin8-cli) $(CARGO) build $(RELEASE)
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-captain && $(call stamp_env,sentin8-captain) $(CARGO) build $(RELEASE)

build-services: build-starters ## Build the 17 platform service repos
	@for s in $(SERVICES); do \
		echo "=== sentin8-$$s ==="; \
		$(MAKE) --no-print-directory build-one SERVICE=$$s || exit 1; \
	done

# build-one — one service repo with ITS OWN stamps (each repo carries its
# own .git, so the hash is that repo's HEAD, not the group's). A recursive
# make call (not a loop fragment) because the stamp's `git -C $(1)`
# resolves against the given repo dir. SQLX_OFFLINE=true pins the build
# to the committed .sqlx offline caches (group DESIGN §3.2.2 — builds
# never connect); the operator `.env` is sourced for the TLS/cert env.
# Arguments: SERVICE=<repo-suffix> (e.g. SERVICE=auth), RELEASE as usual.
build-one:
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-$(SERVICE) && $(call stamp_env,sentin8-$(SERVICE)) $(CARGO) build $(RELEASE)

# ── Fleet run ─────────────────────────────────────────────────────────────
# Profile-agnostic: the default profile runs target/debug binaries,
# RELEASE=--release (or `make start-release`) runs target/release. Captain
# spawns from the BINARY_PREFIX chain covering every repo's target dir for
# the active profile; never mix profiles in a running fleet — stop first,
# then start the other profile. Vertical catalogs ride
# SENTIN8_CAPTAIN_CATALOG_PATHS from the root .env.

# STARTSCOPE-1 (RS §4.5.2): this group's boot scope — the platform CORE
# only (the 18 sentin8:* service types; captain boot-skips its own entry;
# vertical services are NEVER booted from the platform group's start —
# their databases and enrollment belong to their own groups'
# `make start`). The catalog stays the FULL union (the scope pin filters
# only the boot spawn), so a vertical joins the running fleet any time
# via its group Makefile or `captain start <vertical type>`.
PLATFORM_SERVICES := sentin8:captain,sentin8:acme,sentin8:auth,sentin8:sys,sentin8:bus,sentin8:proxy,sentin8:db,sentin8:storage,sentin8:post,sentin8:stat,sentin8:secrets,sentin8:func,sentin8:cron,sentin8:flow,sentin8:ai,sentin8:app,sentin8:bff,sentin8:web

start: ## Start the PLATFORM fleet (core scope, STARTSCOPE-1; RELEASE=--release for release)
	@test -f ../.env || { echo 'No ../.env — copy ../.env.example first.'; exit 1; }
	@export SENTIN8_CAPTAIN_BINARY_PREFIX="$(BINARY_PREFIX)"; \
	export SENTIN8_PG_POOL_MAX=$${SENTIN8_PG_POOL_MAX:-8}; \
	set -a; . ../.env; set +a; \
	eval "export $(RUNDIR_ENV)"; \
	cd sentin8-cli; \
	if $(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain services --no-infra >/dev/null 2>&1; then \
		echo "→ captain up — starting the platform core via API (idempotent)"; \
		$(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain start $(PLATFORM_SERVICES); \
	else \
		echo "→ captain down — booting the platform core (STARTSCOPE-1 scope pin)"; \
		export SENTIN8_SERVICES="$(PLATFORM_SERVICES)"; \
		$(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain start; \
	fi

stop: ## Stop the whole fleet (graceful; never pkill)
	@set -a; . ../.env; set +a; \
	eval "export $(RUNDIR_ENV)"; \
	cd sentin8-cli && $(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain stop

status: ## Fleet status (per-service instances, health, latency)
	@eval "export $(RUNDIR_ENV)"; \
	cd sentin8-cli && $(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain services

# Profile wrappers — make foo-release == RELEASE=--release make foo, and
# make foo-debug == make foo (dev default). Any $(PROFILED) target takes
# either suffix, so AGENTS.md's debug pipeline (build-debug -> start-debug)
# and the release fleet both go through these shared recipes.
$(PROFILED:%=%-release):
	@$(MAKE) --no-print-directory RELEASE=--release $(patsubst %-release,%,$@)

$(PROFILED:%=%-debug):
	@$(MAKE) --no-print-directory RELEASE= $(patsubst %-debug,%,$@)

infra-tls: ## Materialize the infra TLS material (Valkey + PostgreSQL server leaves, control/admin/ops pairs, pg_hba/pg_ident seeds, workload pre-mint)
	@set -a; . ../.env; set +a; \
	./sentin8-acme/target/$(if $(filter --release,$(RELEASE)),release,debug)/sentin8-acme \
		--ensure-infra-tls \
		--mint-workloads=sentin8:acme,sentin8:ai,sentin8:app,sentin8:auth,sentin8:bff,sentin8:bus,sentin8:cron,sentin8:db,sentin8:flow,sentin8:func,sentin8:post,sentin8:proxy,sentin8:secrets,sentin8:stat,sentin8:storage,sentin8:sys,sentin8:web

infra-up: ## Start dev PostgreSQL 18 + Valkey (THE tree-wide infra, §2.2.1)
	@$(MAKE) --no-print-directory infra-tls
	@docker compose up -d

infra-down: ## Stop the dev infra
	@docker compose down

# fleet-up (FLEET-5, captain DESIGN §11.7): the multi-machine dev entry.
# Boots the base fleet trimmed to the placement-minimal set (acme/auth/
# proxy are pinned singletons; everything else stays available to the
# remote-spawn plane). The docker backend + macvlan prerequisites are in
# sentin8-captain/tofu/README.md.
fleet-up: ## Multi-machine dev: infra + base fleet (docker backend ready)
	@test -f ../.env || { echo 'No ../.env — copy ../.env.example first.'; exit 1; }
	@echo "Multi-host fleet mode (captain DESIGN §11):"
	@echo "  1. compose infra (this runs the standard infra-up)"
	@$(MAKE) infra-up
	@echo "  2. macvlan network (one-time): docker network create -d macvlan \\"
	@echo "       --subnet=192.168.77.0/24 --gateway=192.168.77.1 -o parent=<IFACE> sentin8-fleet"
	@echo "  3. base fleet:"
	@export SENTIN8_CAPTAIN_BINARY_PREFIX="$(BINARY_PREFIX)"; \
	export SENTIN8_PG_POOL_MAX=$${SENTIN8_PG_POOL_MAX:-8}; \
	set -a; . ../.env; set +a; \
	eval "export $(RUNDIR_ENV)"; \
	export SENTIN8_SERVICES="$${SENTIN8_SERVICES:-sentin8:acme,sentin8:auth,sentin8:proxy,sentin8:bus,sentin8:sys,sentin8:bff,sentin8:web}"; \
	cd sentin8-cli && $(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain start

enroll: ## Enroll every platform service repo (composable registration, RS §6)
	@export SENTIN8_CAPTAIN_BINARY_PREFIX="$(BINARY_PREFIX)"; \
	cd sentin8-cli && $(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- vertical enroll \
		../sentin8-captain \
		../sentin8-auth ../sentin8-acme ../sentin8-proxy ../sentin8-bus \
		../sentin8-db ../sentin8-storage ../sentin8-post ../sentin8-stat \
		../sentin8-secrets ../sentin8-func ../sentin8-cron ../sentin8-flow \
		../sentin8-ai ../sentin8-sys ../sentin8-app ../sentin8-bff ../sentin8-web \
		../sentin8-dash

test: ## Run the SDK + starters test suites
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-sdk && $(call stamp_env,sentin8-sdk) $(CARGO) test --workspace
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-cli && $(call stamp_env,sentin8-cli) $(CARGO) test
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-captain && $(call stamp_env,sentin8-captain) $(CARGO) test

test-openapi: ## Run every platform drift-guard test (OAPEC §4.8 — the nightly's router↔spec sweep)
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	for d in sentin8-*; do \
		[ -f "$$d/tests/openapi_drift.rs" ] || continue; \
		echo "==> drift-guard: $$d"; \
		(cd $$d && $(call stamp_env,$$d) $(CARGO) test --test openapi_drift) || exit 1; \
	done

# ── OIDF conformance rig (sentin8-auth DESIGN §9a) ───────────────────
# The free, local OIDF suite run: cert tenant seeding + all profile
# plans except the two design exclusions (Front-Channel Logout,
# Implicit/Hybrid OP). Runbook: scripts/conformance/README.md.

conformance-up: ## Start the OIDF conformance suite stack (mongo + server + nginx at :8443)
	# Bake the platform root CA into the suite server image's JVM truststore
	# (copied into the build context by this target; the derived image
	# imports it with keytool - a bind mount alone does not reach the JVM).
	cp -f ../.run/secrets/acme-ca/root-ca.crt scripts/conformance/root-ca.crt
	docker compose -f scripts/conformance/docker-compose.yml up -d --build
	@echo "suite UI: https://localhost.emobix.co.uk:8443/ (alias sentin8-local)"

conformance-down: ## Stop the suite stack (keeps the mongo volume)
	docker compose -f scripts/conformance/docker-compose.yml down

conformance-purge: ## Stop the suite stack AND delete its volumes (clean slate)
	docker compose -f scripts/conformance/docker-compose.yml down -v

conformance-seed: ## Provision the certification tenant (org/env/user/clients) via the platform API
	bash scripts/conformance/conformance-seed.sh

heads: ## Per-repo HEADs
	@for d in */; do \
		[ -d "$$d/.git" ] || continue; \
		printf "%-22s %s\n" "$$d" "$$(git -C $$d log --oneline -1 2>/dev/null | head -c 60)"; \
	done