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

SERVICES := auth acme proxy bus db storage post stat secrets sign func cron flow ai sys app bff web

# Cargo profile flag: empty = dev/debug (default), --release = release.
# Set it on the command line (RELEASE=--release make start) or use the
# equivalent *-release / *-debug wrapper targets defined further below.
RELEASE ?=

# ── Build identity stamps (sentin8-build-info README) ────────
# Every cargo invocation through this Makefile is stamped with the repo's
# own git short hash (SENTIN8_GIT_SHA) and the active cargo profile
# (SENTIN8_BUILD_PROFILE), which sentin8-build-info bakes into the binary
# via option_env! — banners and /v1/health then render
# `{version}+{hash}[.d]` so operators can verify WHICH binary runs.
#
# DELIVERY SHAPE : the stamps ride the SAME shell line as
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
# every binary EMPTY (the first delivery did exactly that).
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

.PHONY: help build build-sdk build-starters build-services build-flutter build-one clean start stop status \
	$(PROFILED:%=%-release) $(PROFILED:%=%-debug) infra-up infra-down enroll test test-openapi heads \
	core-up core-down core-logs core-status \
	conformance-up conformance-down conformance-purge conformance-seed \
       conformance-seed-all conformance-all

help: ## Show this help
	@echo "sentin8/ platform group"
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Profile wrappers: build start stop status take a"
	@echo "-release / -debug suffix, e.g. make start-release == RELEASE=--release make start."

build: build-sdk build-flutter build-starters build-services ## Build the group in DAG order (RELEASE=--release for release)

# build-flutter - the UI bundles the fleet SERVES are build artifacts of
# their app repos (`flutter build web`). The fleet does not rebuild them:
# sentin8-auth serves `sentin8-auth-ui/build/web` (SENTIN8_AUTH_UI_DIR) and
# sentin8:web serves each app's dash/web dir from Valkey `captain:app_dir:*`
# keys - a `make clean` in an app repo deletes the bundle while the platform
# keeps running, and every auth UI page then 404s (the post-reset
# global-setup death class, 2026-10-29). Deterministic skip: a rebuild runs
# ONLY when the bundle is missing (the pubspec did not change checks stay
# the app repos' concern), keeping `make build` a stable no-op.
build-flutter: ## Rebuild any served Flutter web bundle that is missing (auth-ui, dash)
	@test -f sentin8-auth-ui/build/web/index.html || { \
		echo "==> flutter build: sentin8-auth-ui (bundle missing)"; \
		$(MAKE) --no-print-directory -C sentin8-auth-ui build || exit 1; }
	@test -f sentin8-dash/build/web/index.html || { \
		echo "==> flutter build: sentin8-dash (bundle missing)"; \
		$(MAKE) --no-print-directory -C sentin8-dash build || exit 1; }

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

# clean — every child repo's own clean (cargo/flutter target/ + their
# local .run .run/logs .tmp), including start-adjacent repos (cli,
# captain, flutter apps, e2e, packaging) and the non-repo dirs that
# only carry artifacts. Tree-level .run/.tmp (RUNDIR above) are the
# WHOLE TREE's fleet state — the ROOT `make clean` owns their teardown;
# this group's clean leaves them alone.
clean: ## Clean every child repo (target/, build artifacts, local .run/.tmp)
	@for d in $$(ls -d sentin8-*/ 2>/dev/null); do \
		[ -f "$$d/Makefile" ] || continue; \
		echo "==> clean: $$d"; \
		$(MAKE) --no-print-directory -C "$$d" clean || exit 1; \
	done

# ── Fleet run ─────────────────────────────────────────────────────────────
# Profile-agnostic: the default profile runs target/debug binaries,
# RELEASE=--release (or `make start-release`) runs target/release. Captain
# spawns from the BINARY_PREFIX chain covering every repo's target dir for
# the active profile; never mix profiles in a running fleet — stop first,
# then start the other profile. Vertical catalogs ride
# SENTIN8_CAPTAIN_CATALOG_PATHS from the root .env.

# (RS §4.5.2): this group's boot scope — the platform CORE
# only (the 19 sentin8:* service types below; captain boot-skips its own
# entry; vertical services are NEVER booted from the platform group's
# start — their databases and enrollment belong to their own groups'
# `make start`). The catalog stays the FULL union (the scope pin filters
# only the boot spawn), so a vertical joins the running fleet any time
# via its group Makefile or `captain start <vertical type>`.
#
# The pin is passed as ONE comma-joined argument in BOTH branches
# (CLI DESIGN §4.1): the CLI splits/canonicalizes it into
# the start-services list (captain up) or the sentin8-boot allow-list
# (captain down). The CLI owns the cold-boot `SENTIN8_SERVICES` export —
# the Makefile never sets it.
PLATFORM_SERVICES := sentin8:captain,sentin8:acme,sentin8:auth,sentin8:sys,sentin8:bus,sentin8:proxy,sentin8:db,sentin8:storage,sentin8:post,sentin8:stat,sentin8:secrets,sentin8:sign,sentin8:func,sentin8:cron,sentin8:flow,sentin8:ai,sentin8:app,sentin8:bff,sentin8:web

start: ## Start the PLATFORM fleet (core scope, STARTSCOPE-1; RELEASE=--release for release)
	@test -f ../.env || { echo 'No ../.env — copy ../.env.example first.'; exit 1; }
	@if docker inspect sentin8core-machine >/dev/null 2>&1 && \
	   [ "$$(docker inspect -f '{{.State.Running}}' sentin8core-machine 2>/dev/null)" = "true" ]; then \
		echo 'ERROR: the core appliance is running (make core-up).' >&2; \
		echo 'The platform core is already supervised in docker; a second host boot' >&2; \
		echo 'would spawn non-singleton twins (auth/sys/bus/...) that round-robin.' >&2; \
		echo 'Either make core-down first, or hand off individual services:' >&2; \
		echo '  sentin8-cli captain place <host-ip> <service-types>' >&2; \
		exit 1; \
	fi
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
		$(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain start $(PLATFORM_SERVICES); \
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

# Infra TLS material. INFRA_SANS (optional, comma-separated) adds extra
# server-leaf SANs for the core appliance's compose service names (group
# DESIGN §3.3): the appliance dials postgres/valkey BY SERVICE NAME inside
# its bridge netns, so verify-full needs those names in the leaves.
INFRA_SANS ?=
infra-tls: ## Materialize the infra TLS material (Valkey + PostgreSQL server leaves, control/admin/ops pairs, pg_hba/pg_ident seeds, workload pre-mint)
	@set -a; . ../.env; set +a; \
	./sentin8-acme/target/$(if $(filter --release,$(RELEASE)),release,debug)/sentin8-acme \
		--ensure-infra-tls \
		$(if $(INFRA_SANS),--infra-sans=$(INFRA_SANS)) \
		--mint-workloads=sentin8:acme,sentin8:ai,sentin8:app,sentin8:auth,sentin8:bff,sentin8:bus,sentin8:cron,sentin8:db,sentin8:flow,sentin8:func,sentin8:post,sentin8:proxy,sentin8:secrets,sentin8:stat,sentin8:storage,sentin8:sys,sentin8:web

infra-up: ## Start dev PostgreSQL 18 + Valkey (THE tree-wide infra, §2.2.1)
	@$(MAKE) --no-print-directory infra-tls
	@docker compose up -d

infra-down: ## Stop the dev infra
	@docker compose down

# ── The core appliance (group DESIGN.md §3.3, captain DESIGN §11.11) ────────
# The dev split-plane: the platform CORE (postgres + valkey + one machine
# container running captain + the 17 services) in a SECOND compose project,
# verticals on the host. Opt-in - `make start` refuses while the appliance
# is up (the double-boot guard). The appliance identity is 127.0.0.1; the
# host CLI reaches its captain on 127.0.0.1:18000 (per-key routing).
CORE_COMPOSE := -f docker-compose.core.yml -p sentin8core
# Absolute tree root for the compose binds (the PATH FORM note in
# docker-compose.core.yml): compose-relative binds ride the WSL gRPC-FUSE
# proxy and materialize as empty dirs; absolute paths are reliable.
# TREE_ROOT_ACME is the HOST home of the platform Acme data dir
# (SENTIN8_ACME_DATA_DIR's parent) - the appliance mounts it so its acme
# instance serves the SAME platform CA (keys persist on the host).
# Derived from the operator .env's SENTIN8_ACME_DATA_DIR (parent dir);
# overridable on the command line.
SENTIN8_ACME_HOME ?= $(patsubst %/,%,$(dir $(shell grep -h '^SENTIN8_ACME_DATA_DIR=' ../.env 2>/dev/null | cut -d= -f2 | tr -d '\r')))
CORE_ENV := TREE_ROOT=$(abspath ..) TREE_ROOT_ACME=$(SENTIN8_ACME_HOME)

core-up: ## Bring the core appliance up (builds RELEASE binaries first; waits for health)
	@test -f ../.env || { echo 'No ../.env - copy ../.env.example first.'; exit 1; }
	@test -n "$(SENTIN8_ACME_HOME)" || { echo 'Set SENTIN8_ACME_HOME (the parent of SENTIN8_ACME_DATA_DIR, e.g. $$HOME/.sentin8) - the appliance mounts the platform CA dir.'; exit 1; }
	@echo "==> core appliance: ensuring RELEASE binaries (build skipped when fresh)"
	$(MAKE) RELEASE=--release build-sdk build-starters build-services
	@$(MAKE) --no-print-directory infra-tls INFRA_SANS=sentin8core-postgres,sentin8core-valkey
	@echo "==> core appliance: STAGE 1 - infra (postgres + valkey)"
	@echo "==> volume creation + fresh ownership (host uid): compose create materializes the volumes (NOT started); the chown then fixes ownership BEFORE the first boot - the containers run uid 1000 and a root-owned volume is unreadable (the initdb EPERM class)"
	env $(CORE_ENV) docker compose $(CORE_COMPOSE) create --build postgres valkey
	@for vol in sentin8core_sentin8core-pgdata sentin8core_sentin8core-valkeydata sentin8core_sentin8core-run; do \
			docker run --rm -v "$$vol:/d" alpine chown 1000:1000 /d 2>/dev/null \
				|| echo "WARN: could not fix ownership of $$vol"; \
		done
	env $(CORE_ENV) docker compose $(CORE_COMPOSE) up -d postgres valkey
	@echo "==> core appliance: waiting for infra health (postgres + valkey healthy before anything dials them)"
	@deadline=$$(( $$(date +%s) + 120 )); until [ "$$(docker inspect -f '{{.State.Health.Status}}' sentin8core-postgres 2>/dev/null)" = "healthy" ] \
			&& [ "$$(docker inspect -f '{{.State.Health.Status}}' sentin8core-valkey 2>/dev/null)" = "healthy" ]; do \
			if [ $$(date +%s) -gt $$deadline ]; then \
				echo "ERROR: the appliance infra did not become healthy in 120s." >&2; exit 1; \
			fi; sleep 2; done
	@echo "==> core appliance: STAGE 2 - enroll (the valkey ACL + the DB bootstrap BEFORE any fleet connection - the fleet's first valkey connection must find its cert-identity user; the ACL lives in the valkey AOF and a wiped volume reverts to the stock default user)"
	@$(MAKE) --no-print-directory -e enroll
	@echo "==> core appliance: STAGE 3 - the machine container (captain + the 17 services)"
	env $(CORE_ENV) docker compose $(CORE_COMPOSE) up -d --build core
	@echo "==> core appliance: waiting for the machine container health"
	@deadline=$$(( $$(date +%s) + 300 )); \
	until [ "$$(docker inspect -f '{{.State.Health.Status}}' sentin8core-machine 2>/dev/null)" = "healthy" ]; do \
		if [ $$(date +%s) -gt $$deadline ]; then \
			echo "ERROR: the core appliance did not become healthy in 300s." >&2; \
			echo "Logs: docker logs sentin8core-machine; make core-logs" >&2; exit 1; \
		fi; \
		sleep 5; \
	done
	@echo "==> core appliance healthy. The platform core is in docker; verticals run on the host."
	@echo "    release-only runtime; binaries surface as /usr/bin/sentin8-{svc} in the container"
	@echo "    host CLI: export SENTIN8_CORE_APPLIANCE_IP=127.0.0.1 (per-key routing)"
	@echo "    valkey ACL + DB bootstrap ride stage 2 (enroll) - re-run make enroll to refresh fragments"

core-down: ## Graceful appliance stop (captain drains) + volume wipe (fresh initdb next up)
	@echo "==> core appliance: stopping the in-container fleet (graceful)"
	@if docker inspect sentin8core-machine >/dev/null 2>&1; then \
		SENTIN8_SENTIN8_CAPTAIN_URL=http://127.0.0.1:18000 \
		./sentin8-cli/target/release/sentin8-cli captain stop \
		  || echo "WARN: graceful stop failed (container down?) - proceeding to compose down."; \
	fi
	@echo "==> core appliance: compose down -v (volumes removed - fresh initdb next up)"
	env $(CORE_ENV) docker compose $(CORE_COMPOSE) down -v

core-logs: ## Follow the appliance captain + service logs
	@docker exec sentin8core-machine tail -n 200 -f /var/lib/sentin8/run/logs/captain.log 2>/dev/null \
	  || { echo "appliance not running - make core-up first" >&2; exit 1; }

core-status: ## Fleet rows across BOTH captains (appliance + host, when both are up)
	@SENTIN8_SENTIN8_CAPTAIN_URL=http://127.0.0.1:18000 \
		./sentin8-cli/target/release/sentin8-cli captain services 2>/dev/null \
	  || echo "(appliance captain not reachable - is the appliance up? make core-up)"
	@$(MAKE) --no-print-directory status

# fleet-up (captain DESIGN §11.7): the multi-machine dev entry.
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

# enroll (RS §6): every platform repo carrying a service-registration.json
# fragment, DERIVED not listed (the SIGNENROLL-1/2 lesson: the enroll list
# kept going stale on every new repo - derivation cannot). The same
# derivation provision-on-boot performs on cold start, so `make enroll`
# and the boot converge IDENTICAL fragment sets. The pass is idempotent;
# it also bootstraps the platform database first when the scout is absent
# (bootstrap-if-needed gate, CLI DESIGN §4.9a) - the operator flow after a
# dev reset is simply: reset -> make enroll -> make start.
ENROLL_PATHS := $(shell for d in sentin8-*/; do [ -f "$$d/service-registration.json" ] && echo "../$$d"; done)

enroll: ## Enroll every platform service fragment (derived; bootstraps first when the DB is virgin - CLI DESIGN §4.9a)
	@test -n "$(ENROLL_PATHS)" || { echo 'No service-registration.json fragments found.'; exit 1; }
	@export SENTIN8_CAPTAIN_BINARY_PREFIX="$(BINARY_PREFIX)"; \
	cd sentin8-cli && $(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- vertical enroll \
		$(ENROLL_PATHS)

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

# ── OIDF conformance rig (sentin8-auth DESIGN §9a; owned by sentin8-auth-oidf) ──
# The free, local OIDF suite run: cert tenant seeding + all profile
# plans except the two design exclusions (Front-Channel Logout,
# Implicit/Hybrid OP). Runbook: sentin8-auth-oidf/conformance/README.md.

# Conformance rig fleet posture (auth DESIGN §9a.2 step 3): the suite
# Java client cannot speak the post-quantum TLS transport or verify
# ML-DSA-65 JOSE, so a rig run starts the platform in CLASSICAL mode
# (TLS 1.2/1.3 + RSA/ECDSA certs, RS256 JWTs) with the FAPI cipher
# profile and the RFC 8705 self-signed client-cert surface. `make start`
# below keeps whatever ../.env declares (production posture).
start-conformance: ## Start the platform fleet in the rig posture (classical TLS + FAPI ciphers + self-signed client certs)
	@test -f ../.env || { echo 'No ../.env — copy ../.env.example first.'; exit 1; }
	@export SENTIN8_CAPTAIN_BINARY_PREFIX="$(BINARY_PREFIX)"; \
	export SENTIN8_TLS_PQ_MODE=classical; \
	export SENTIN8_TLS_CIPHER_PROFILE=fapi; \
	export SENTIN8_MTLS_CLIENT_AUTH=self_signed; \
	export SENTIN8_TLS_CLIENT_AUTH=self_signed; \
	export SENTIN8_PG_POOL_MAX=$${SENTIN8_PG_POOL_MAX:-8}; \
	set -a; . ../.env; set +a; \
	eval "export $(RUNDIR_ENV)"; \
	cd sentin8-cli; \
	if $(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain services --no-infra >/dev/null 2>&1; then \
		echo "→ captain up (rig posture) — starting the platform core via API (idempotent)"; \
		$(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain start $(PLATFORM_SERVICES); \
	else \
		echo "→ captain down (rig posture) — booting the platform core"; \
		export SENTIN8_SERVICES="$(PLATFORM_SERVICES)"; \
		$(call stamp_env,sentin8-cli) $(CARGO) run $(RELEASE) --quiet --bin sentin8-cli -- captain start; \
	fi

conformance-up: start-conformance ## Start the OIDF conformance suite stack (mongo + server + nginx at :8443)
	# Bake the platform root CA into the suite server image's JVM truststore
	# (copied into the build context by this target; the derived image
	# imports it with keytool - a bind mount alone does not reach the JVM).
	cp -f ../.run/secrets/acme-ca/root-ca.crt sentin8-auth-oidf/conformance/root-ca.crt
	# (auth DESIGN §9a.2 step 1b): the suite's nginx serves a
	# platform-CA leaf (CN conformance-suite, SAN localhost.emobix.co.uk)
	# instead of the image's self-signed cert - minted by `make infra-tls`,
	# mounted read-only by the compose nginx service over the image paths.
	# A missing pair means `make infra-tls` has not run - fail with the hint
	# rather than starting an untrusted ingress.
	test -f ../.run/secrets/infra-tls/conformance-suite-server.crt || { \
		echo 'conformance suite leaf missing - run: make infra-tls'; exit 1; }
	cp -f ../.run/secrets/infra-tls/conformance-suite-server.crt sentin8-auth-oidf/conformance/suite-localhost-emobix.crt
	cp -f ../.run/secrets/infra-tls/conformance-suite-server.key sentin8-auth-oidf/conformance/suite-localhost-emobix.key
	docker compose -f sentin8-auth-oidf/conformance/docker-compose.yml up -d --build
	@echo "suite UI: https://localhost.emobix.co.uk:8443/ (alias sentin8-local)"

conformance-down: ## Stop the suite stack (keeps the mongo volume)
	docker compose -f sentin8-auth-oidf/conformance/docker-compose.yml down

conformance-purge: ## Stop the suite stack AND delete its volumes (clean slate)
	docker compose -f sentin8-auth-oidf/conformance/docker-compose.yml down -v

conformance-seed: ## Provision the certification tenant (org/env/user/clients) via the platform API
	bash sentin8-auth-oidf/conformance/conformance-seed.sh

heads: ## Per-repo HEADs
	@for d in */; do \
		[ -d "$$d/.git" ] || continue; \
		printf "%-22s %s\n" "$$d" "$$(git -C $$d log --oneline -1 2>/dev/null | head -c 60)"; \
	done

conformance-seed-all: ## Provision EVERY family env (profile-per-env, OC-20 - one env + alias per family)
	bash sentin8-auth-oidf/conformance/conformance-seed-all.sh

conformance-all: ## Run the WHOLE battery (each family against its own env; seed first: conformance-seed-all)
	bash sentin8-auth-oidf/conformance/conformance-run-all.sh
