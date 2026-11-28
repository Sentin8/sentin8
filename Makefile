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

SERVICES := auth acme proxy bus db storage post push stat secrets sign func cron flow ai sys app bff web

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

# Compose input: the group folder carries NO `.env`, so `docker compose`
# would otherwise load ZERO variables and any required interpolation
# (the pgadmin auth-host route, DESIGN §3.2.5) would fail. Every compose
# call against docker-compose.yml goes through this variable so the
# operator .env at the TREE ROOT is always the one input.
COMPOSE := docker compose --env-file $(abspath ..)/.env

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
BINARY_PREFIX = $(subst $(space),:,$(foreach d,$(shell for g in sentin8-*/ ../bank8/bank8-*/ ../hotel8/hotel8-*/ ../openfin8/openfin8-*/ ../email8/email8-*/ ../exchange8/exchange8-*/ ../bill8/bill8-*/ ../trade8/trade8-*/ ; do [ -d "$$g/target/$(BINARY_DIR)" ] && echo "$$g/target/$(BINARY_DIR)"; done),$(abspath $(d))))
space := $(empty) $(empty)

.PHONY: help build build-sdk build-starters build-services build-flutter build-one clean start stop status \
	$(PROFILED:%=%-release) $(PROFILED:%=%-debug) infra-up infra-down enroll test test-openapi heads \
	lint-fleet-lists \
	ingress-port ca-tls ca-trust ca-untrust ca-trust-status \
	core-up core-down core-logs core-status \
	conformance-up conformance-down conformance-purge conformance-seed \
       conformance-seed-all conformance-all conformance-hosted \
       conformance-hosted-bootstrap conformance-hosted-up \
       conformance-acme-internal conformance-acme-upstream

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

build-services: build-starters ## Build the 18 platform service repos
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
PLATFORM_SERVICES := sentin8:captain,sentin8:acme,sentin8:auth,sentin8:sys,sentin8:bus,sentin8:proxy,sentin8:db,sentin8:storage,sentin8:post,sentin8:push,sentin8:stat,sentin8:secrets,sentin8:sign,sentin8:func,sentin8:cron,sentin8:flow,sentin8:ai,sentin8:app,sentin8:bff,sentin8:web

# Ingress bind precondition (PORTBIND-1, packaging DESIGN §4.1). The proxy
# binds :443 (and the ACME :80 listener when SENTIN8_PROXY_HTTP_PORT is
# set) as the unprivileged user running this shell. Linux refuses ports
# below `net.ipv4.ip_unprivileged_port_start` with EACCES; the kernel
# default is 1024, so a fresh dev host would fail at bind with an opaque
# error long after the boot started. Fail here, before spawning anything,
# and print the exact remedy.
#
# The packaged deployment does NOT need this: its unit grants the
# capability (AmbientCapabilities=CAP_NET_BIND_SERVICE). The appliance does
# not need it either (its container starts as root). This is the source/dev
# path only, where cargo produces a new inode per build so a `setcap`
# xattr cannot survive - machine policy is the correct mechanism here.
# The lowest port the ingress actually needs: :443 always, plus the ACME
# :80 challenge listener when the operator enabled it (the env file wins
# over the shell so the advice matches what the fleet will bind).
INGRESS_ENV_HTTP_PORT = $(shell grep -h '^SENTIN8_PROXY_HTTP_PORT=' ../.env 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')
INGRESS_HTTP_PORT = $(or $(SENTIN8_PROXY_HTTP_PORT),$(INGRESS_ENV_HTTP_PORT))
INGRESS_LOWEST_PORT = $(if $(filter-out 0,$(INGRESS_HTTP_PORT)),$(INGRESS_HTTP_PORT),443)
define ingress_port_check
if [ -r /proc/sys/net/ipv4/ip_unprivileged_port_start ]; then \
	floor=$$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start); \
	if [ "$$floor" -gt $(INGRESS_LOWEST_PORT) ]; then \
		if [ -n "$$(docker ps --filter name=sentin8-http80 --filter status=running -q 2>/dev/null)" ]; then \
			: ; \
		else \
			echo "ERROR: this host refuses to bind ports below $$floor (net.ipv4.ip_unprivileged_port_start)," >&2; \
			echo "       but the ingress must publish :$(INGRESS_LOWEST_PORT) for ACME HTTP-01." >&2; \
			echo "       Either:" >&2; \
			echo "         make http80-up      # rootless Docker sidecar - no sudo" >&2; \
			echo "         make ingress-port   # lower the host floor (asks for sudo)" >&2; \
			exit 1; \
		fi; \
	fi; \
fi
endef

# The same remedy as a target: grant the ingress its low ports on THIS dev
# host. One sudo prompt applies the live value and the persistent drop-in,
# so `make start` works now and after a reboot. The value is the lowest port
# the fleet will actually bind (443, or 80 when the ACME challenge listener
# is enabled) - derived from .env like the check above, never hardcoded.
# Deliberately an explicit target, never an implicit step of `make start`:
# a boot must not escalate privileges on its own.
# Packaged hosts do not need this (the unit grants CAP_NET_BIND_SERVICE).
ingress-port: ## Dev host: allow the ingress low ports (sudo sysctl + persistent drop-in)
	@if [ ! -r /proc/sys/net/ipv4/ip_unprivileged_port_start ]; then \
		echo "This kernel has no ip_unprivileged_port_start - nothing to do."; exit 0; \
	fi; \
	floor=$$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start); \
	if [ "$$floor" -le $(INGRESS_LOWEST_PORT) ]; then \
		echo "OK: this host already binds ports below $$floor, so the ingress can hold :$(INGRESS_LOWEST_PORT)."; \
		exit 0; \
	fi; \
	echo "→ granting ports below $(INGRESS_LOWEST_PORT) - sudo password required"; \
	sudo sysctl -w net.ipv4.ip_unprivileged_port_start=$(INGRESS_LOWEST_PORT) >/dev/null || exit 1; \
	printf '%s\n' 'net.ipv4.ip_unprivileged_port_start=$(INGRESS_LOWEST_PORT)' \
		| sudo tee /etc/sysctl.d/99-sentin8-ingress.conf >/dev/null || exit 1; \
	echo "→ persisted to /etc/sysctl.d/99-sentin8-ingress.conf (survives reboot)"; \
	echo "→ active floor: $$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)"

infra-up: ## Dev infra plane: compose up (postgres + valkey; fresh volumes = fresh initdb)
	@if [ ! -f ../.run/secrets/infra-tls/postgres-server.crt ]; then \
		echo 'infra-tls material missing - running make infra-tls first'; \
		$(MAKE) --no-print-directory infra-tls; \
	else \
		$(MAKE) --no-print-directory infra-tls INFRA_SANS=postgres,valkey; \
	fi
	@for vol in sentin8_sentin8-pgdata sentin8_sentin8-valkeydata; do \
		docker run --rm -v $$vol:/d alpine chown -R 1000:1000 /d 2>/dev/null || true; \
	done
	$(COMPOSE) up -d postgres valkey
	@if [ "$${PGADMIN_DISABLE:-0}" != "1" ]; then \
		$(MAKE) --no-print-directory infra-pgadmin; \
	fi

# pgAdmin 4 in front of the SAME PostgreSQL (see the pgadmin service's
# header): a convenience console, loopback-only. Console sign-in is the
# PLATFORM's SSO - there is no static password and no hardcoded domain.
# `infra/pgadmin/pgadmin-oidc-login.sh` registers an OIDC client via DCR
# against this tree's auth (SENTIN8_DOMAIN from the tree-root .env) and
# writes .run/pgadmin/config_system.py, which pgAdmin loads as its FINAL
# config layer - that is what replaces AUTHENTICATION_SOURCES=["internal"].
# Opt out of SSO with PGADMIN_OIDC_DISABLE=1 (the console then cannot sign
# anyone in; it is a debugging switch, not a fallback).
infra-pgadmin: ## Dev infra: bring up the pgAdmin 4 console (SSO) on 127.0.0.1:5050
	@if [ "$${PGADMIN_OIDC_DISABLE:-0}" = "1" ]; then \
		echo "PGADMIN_OIDC_DISABLE=1 - skipping the SSO registration"; \
	else \
		./infra/pgadmin/pgadmin-oidc-login.sh || { \
			echo "ERROR: pgAdmin SSO registration failed." >&2; \
			echo "  The console has no static password - without a client nobody can sign in." >&2; \
			echo "  Is the fleet up (make start) and the CA trusted (make ca-trust)?" >&2; \
			exit 1; \
		}; \
	fi
	@# The console image runs as a NON-ROOT uid (`USER 5050`, gid 0), so a
	@# volume created root-owned by docker is unwritable - the first boot dies
	@# on `PermissionError: /var/lib/pgadmin/pgadmin4.db`. The owner must be
	@# the IMAGE's uid, never a literal: chowning to the host operator's uid
	@# (1000) locks the console out of its own database, because it still runs
	@# as 5050. Derived here so a tag bump cannot drift (DESIGN §3.2.5).
	@uid=$$(docker image inspect dpage/pgadmin4:9 --format '{{.Config.User}}' 2>/dev/null | cut -d: -f1); \
	docker run --rm -v sentin8_sentin8-pgadmin:/d alpine:3 \
		chown -R "$${uid:-0}:0" /d 2>/dev/null || true
	@port=$${PGADMIN_PORT:-$$(grep -h '^PGADMIN_PORT=' ../.env 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')}; \
	echo "→ pgAdmin 4: http://127.0.0.1:$${port:-5050}/  (loopback only - sign in with your Sentin8 account)"
	$(COMPOSE) --profile pgadmin up -d --force-recreate pgadmin

infra-pgadmin-sso-reset: ## Dev infra: re-register the console's OIDC client (after a domain/port change)
	@FORCE=1 ./infra/pgadmin/pgadmin-oidc-login.sh
	@$(MAKE) --no-print-directory infra-pgadmin

# servers.json is read ONCE, when the pgadmin volume is empty. Changing the
# pre-registered server (host, cert paths, sslmode) needs this.
infra-reset-pgadmin: ## Dev infra: wipe pgAdmin state so servers.json is re-read
	$(COMPOSE) rm -sf pgadmin 2>/dev/null || true
	docker volume rm -f sentin8_sentin8-pgadmin 2>/dev/null || true
	@echo "pgAdmin state wiped - the next 'make infra-pgadmin' re-reads infra/pgadmin/servers.json."

# CERTPLANE-1: publish :80 for ACME HTTP-01 without sudo. A src/dev host
# refuses unprivileged binds below 443 (ip_unprivileged_port_start=443)
# unless the operator lowers the floor with sudo; the Docker daemon runs as
# root, so a published :80 works regardless. The proxy listens on the
# configured high port and this sidecar forwards :80 -> host:{port}. Only
# `/.well-known/acme-challenge/*` is served on that port by the proxy, so
# nothing else is exposed. On a host that allows the privileged bind, set
# SENTIN8_PROXY_HTTP_PORT=80 and skip this target entirely.
http80-up: ## Dev host: publish :80 for ACME HTTP-01 via a rootless Docker sidecar
	@port=$$(grep -h '^SENTIN8_PROXY_HTTP_PORT=' ../.env 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r'); \
	port=$${port:-8080}; \
	if [ "$$port" = "80" ]; then \
		echo "SENTIN8_PROXY_HTTP_PORT=80 - the proxy binds :80 itself, sidecar not needed."; exit 0; \
	fi; \
	if ss -ltn 2>/dev/null | grep -q ':80 '; then \
		echo "ERROR: :80 is already in use - stop whatever holds it first." >&2; exit 1; \
	fi; \
	echo "→ publishing :80 -> host:$$port (socat sidecar, no sudo needed)"; \
	docker rm -f sentin8-http80 >/dev/null 2>&1 || true; \
	docker run -d --restart unless-stopped --name sentin8-http80 \
		-p 80:8080 \
		--add-host host.docker.internal:host-gateway \
		alpine/socat:latest \
		TCP-LISTEN:8080,fork,reuseaddr TCP:host.docker.internal:$$port >/dev/null; \
	sleep 1; \
	ss -ltn | grep -q ':80 ' && echo "OK: :80 published" \
		|| { echo "ERROR: sidecar did not bind :80" >&2; docker logs sentin8-http80 2>&1 | tail -5 >&2; exit 1; }

http80-down: ## Dev host: remove the :80 sidecar
	@docker rm -f sentin8-http80 >/dev/null 2>&1 && echo "removed :80 sidecar" || echo "no sidecar running"

infra-down: ## Dev infra plane: compose down (volumes KEPT; infra stays warm)
	$(COMPOSE) --profile pgadmin stop postgres valkey pgadmin \
		&& $(COMPOSE) --profile pgadmin rm -f postgres valkey pgadmin

start: ## Start the PLATFORM fleet (core scope, STARTSCOPE-1; RELEASE=--release for release)
	@test -f ../.env || { echo 'No ../.env — copy ../.env.example first.'; exit 1; }
	@$(call ingress_port_check)
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
                --mint-workloads=sentin8:acme,sentin8:ai,sentin8:app,sentin8:auth,sentin8:bff,sentin8:bus,sentin8:cron,sentin8:db,sentin8:flow,sentin8:func,sentin8:post,sentin8:push,sentin8:proxy,sentin8:secrets,sentin8:sign,sentin8:stat,sentin8:storage,sentin8:sys,sentin8:web,wallet8:holder
MODES ?=
ca-tls: ## Ensure the CA root + intermediate per PQ mode (default: active; MODES=a,b,c for specific)
	@set -a; . ../.env; set +a; \
	./sentin8-acme/target/$(if $(filter --release,$(RELEASE)),release,debug)/sentin8-acme \
		--ensure-ca \
		$(if $(MODES),--modes=$(MODES))

# CATRUST-1 (acme DESIGN §4.0b): publish the platform CA into the system
# trust store. Installs ALL THREE families' root + intermediate so a
# posture flip needs no re-install; every anchor filename carries its
# family, because the classical/hybrid/exclusive CAs are unrelated
# authorities and an unnamespaced anchor cannot be told apart across
# postures (the script deletes the legacy unnamespaced names). One file
# per certificate - Debian copies files verbatim and never splits the
# two-cert acme-ca/root-ca.crt bundle. sudo once for the anchor dir.
CA_TRUST_MODES ?=
ca-trust: ## Install the platform CA (all 3 families' root+intermediate) into the system + NSS trust stores
	@set -a; . ../.env; set +a; \
	sudo -E ./sentin8-acme/scripts/ca-trust.sh install $(CA_TRUST_MODES)

ca-untrust: ## Remove every Sentin8 CA from the system + NSS trust stores
	@set -a; . ../.env; set +a; \
	sudo -E ./sentin8-acme/scripts/ca-trust.sh uninstall

ca-trust-status: ## Show which Sentin8 CAs are installed (no privilege needed)
	@set -a; . ../.env; set +a; \
	./sentin8-acme/scripts/ca-trust.sh status

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
test: lint-fleet-lists
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-sdk && $(call stamp_env,sentin8-sdk) $(CARGO) test --workspace
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-cli && $(call stamp_env,sentin8-cli) $(CARGO) test
	@set -a; . ../.env; set +a; export SQLX_OFFLINE=true; \
	cd sentin8-captain && $(call stamp_env,sentin8-captain) $(CARGO) test

lint-fleet-lists: ## Guard: Makefile build/start lists and the captain catalog must agree
	@python3 sentin8-cli/scripts/check-fleet-lists.py

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

# ---- Conformance rig issuance mode (RIGMODE-3) ----
# The rig does NOT select a domain. `SENTIN8_DOMAIN` comes from the tree
# .env like every other variable - there is exactly one way to run against
# a different domain: set it in .env and reset the fleet (the CA, the
# enrolled hostnames and the issued leaves are all domain-scoped).
#
# What the rig DOES select is the certificate issuer, because that is a
# policy choice a test run legitimately changes without touching identity:
#   internal - platform CA for everything; no upstream, no internet.
#   upstream - declared `external` hostnames relay to the upstream CA;
#              the platform plane stays on the platform CA.
#
# The chosen target writes conformance/domain.env - the ONE override block
# every rig consumer reads, sourced AFTER ../.env by start-conformance.
# It never contains SENTIN8_DOMAIN.
#
# ALWAYS point CONFORMANCE_ACME_UPSTREAM_URL at Let's Encrypt STAGING:
# production allows 50 certs per registered domain per week, and one
# battery can consume that.
CONFORMANCE_MODE_FILE ?= conformance/domain.env

# The battery family env slugs (mirrors conformance-seed-all.sh's FAMILY
# map and gen-extra-hosts.sh's FAMILIES - that table is the source of
# truth; keep the three in lockstep).
CONFORMANCE_FAMILY_SLUGS := cert cert-fcl cert-imp cert-hyb cert-fp cert-sm cert-vp cert-f2m cert-fapi1 cert-fapi2 cert-ciba cert-vci cert-haip cert-wallet cert-vpw

conformance-acme-internal: ## Rig mode: platform CA for everything (no upstream, fully offline)
	@mkdir -p $(dir $(CONFORMANCE_MODE_FILE))
	@printf '# Generated by make conformance-acme-internal (RIGMODE-3, TLS-EXPOSURE-1)\nSENTIN8_ACME_FORCE_INTERNAL=true\nSENTIN8_ACME_UPSTREAM_DIRECTORY_URL=\n' > $(CONFORMANCE_MODE_FILE)
	@echo "rig issuer: internal only (platform CA, no upstream)"
	@echo "  domain comes from ../.env (SENTIN8_DOMAIN)"
	@echo "  next: make start-conformance && make conformance-up"

conformance-acme-upstream: ## Rig mode: upstream CA for declared externals (CONFORMANCE_ACME_UPSTREAM_URL required)
	@if [ -z "$(CONFORMANCE_ACME_UPSTREAM_URL)" ]; then \
		echo 'CONFORMANCE_ACME_UPSTREAM_URL is required - use the LE STAGING directory:'; \
		echo '  https://acme-staging-v02.api.letsencrypt.org/directory'; exit 1; fi
	@mkdir -p $(dir $(CONFORMANCE_MODE_FILE))
	@printf '# Generated by make conformance-acme-upstream (RIGMODE-3, TLS-EXPOSURE-1)\nSENTIN8_ACME_FORCE_INTERNAL=false\nSENTIN8_ACME_UPSTREAM_DIRECTORY_URL=%s\nSENTIN8_ACME_UPSTREAM_CONTACT=%s\n' \
		"$(CONFORMANCE_ACME_UPSTREAM_URL)" \
		"$(if $(CONFORMANCE_ACME_UPSTREAM_CONTACT),$(CONFORMANCE_ACME_UPSTREAM_CONTACT),a@m.n)" > $(CONFORMANCE_MODE_FILE)
	@echo "rig issuer: upstream CA for enrolled externals, platform CA otherwise"
	@echo "  domain comes from ../.env (SENTIN8_DOMAIN)"
	@echo "  the HTTP challenge port comes from ../.env too - this file never sets it"
	@echo "  next: make start-conformance && make conformance-up"

# Conformance rig fleet posture (auth DESIGN §9a.2 step 3): the suite
# Java client cannot speak the post-quantum TLS transport or verify
# ML-DSA-65 JOSE, so a rig run starts the platform in CLASSICAL mode
# (TLS 1.2/1.3 + RSA/ECDSA certs, RS256 JWTs) with the FAPI cipher
# profile and the RFC 8705 self-signed client-cert surface. `make start`
# below keeps whatever ../.env declares (production posture).
start-conformance: ## Start the platform fleet in the rig posture (classical TLS + FAPI ciphers + self-signed client certs)
	@test -f ../.env || { echo 'No ../.env — copy ../.env.example first.'; exit 1; }
	@$(call ingress_port_check)
	@$(MAKE) --no-print-directory infra-up
	@export SENTIN8_CAPTAIN_BINARY_PREFIX="$(BINARY_PREFIX)"; \
	export SENTIN8_TLS_PQ_MODE=classical; \
	export SENTIN8_TLS_CIPHER_PROFILE=fapi; \
	export SENTIN8_MTLS_CLIENT_AUTH=self_signed; \
	export SENTIN8_TLS_CLIENT_AUTH=self_signed; \
	export SENTIN8_PG_POOL_MAX=$${SENTIN8_PG_POOL_MAX:-8}; \
	set -a; . ../.env; set +a; \
	test -f $(CONFORMANCE_MODE_FILE) && { \
		if grep -q '^SENTIN8_DOMAIN=' $(CONFORMANCE_MODE_FILE); then \
			echo "ERROR: $(CONFORMANCE_MODE_FILE) sets SENTIN8_DOMAIN." >&2; \
			echo "       The rig never selects a domain - SENTIN8_DOMAIN lives in ../.env." >&2; \
			echo "       Running a different domain means a fleet reset, not an override." >&2; \
			exit 1; \
		fi; \
		set -a; . $(CONFORMANCE_MODE_FILE); set +a; \
		echo "rig issuer override applied (from $(CONFORMANCE_MODE_FILE))"; \
	} || true; \
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

conformance-hosted-bootstrap: ## Hosted suite (certification.openid.net): the ONE interactive step - sign-in + mint the API token
	CONFORMANCE_SUITE_TARGET=hosted $(MAKE) --no-print-directory -C sentin8-auth-oidf bootstrap-suite-token

conformance-hosted-up: start-conformance ## Hosted target: platform fleet in public rig posture (NO suite docker - the OIDF instance is hosted)
	@if [ ! -f $(CONFORMANCE_MODE_FILE) ]; then echo 'No $(CONFORMANCE_MODE_FILE) - select the rig issuer first:'; echo '  make conformance-acme-upstream CONFORMANCE_ACME_UPSTREAM_URL=<le-staging-directory>'; exit 1; fi
	@echo "hosted target: the suite runs at https://www.certification.openid.net (no local stack);"
	@echo "  the OP under test must be publicly reachable (SENTIN8_DOMAIN from ../.env, upstream issuer selected in $(CONFORMANCE_MODE_FILE))."
	@echo "  next: make conformance-seed-all (CONFORMANCE_SUITE_TARGET=hosted) then the battery"

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
	# CERTPLANE-1: when the fleet relays to a public CA, the tenant auth
	# hosts carry THAT chain, and the suite's JVM will not accept it from
	# the platform root alone. Harvest the issuer acme actually stored and
	# let server.Dockerfile import it as a second anchor. A platform-CA-only
	# run has no upstream leaf, so the script reports that and we write an
	# empty file - the Dockerfile treats it as a no-op.
	bash sentin8-acme/scripts/harvest-staging-ca.sh \
		-o sentin8-auth-oidf/conformance/staging-ca.crt \
		|| { echo '  (no upstream leaf yet - importing the platform root only)' >&2; \
		     : > sentin8-auth-oidf/conformance/staging-ca.crt; }
	# RIGMODE-1 (auth DESIGN 9a.2 item 2c): regenerate the family
	# extra_hosts from SENTIN8_DOMAIN (the tree .env), then hand compose the
	# per-family host vars (interpolated; the env-file defaults keep an
	# un-regenerated tree working).
	bash sentin8-auth-oidf/conformance/gen-extra-hosts.sh --write
	docker compose --env-file <(grep -v '\#' ../.env 2>/dev/null; cat sentin8-auth-oidf/conformance/extra_hosts.env) -f sentin8-auth-oidf/conformance/docker-compose.yml up -d --build
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

conformance-hosted: ## Run the battery against the HOSTED suite (certification.openid.net; bootstrap + hosted-up + seed first)
	CONFORMANCE_SUITE_TARGET=hosted bash sentin8-auth-oidf/conformance/conformance-run-all.sh
