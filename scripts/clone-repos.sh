#!/usr/bin/env bash
# clone-repos.sh - Clone all sentin8 sub-repositories into the workspace root.
#
# Usage (from /home/hamid/dev/sentin8.new):
#   ./scripts/clone-repos.sh            # clones every repo
#   ./scripts/clone-repos.sh auth bus   # clones only sentin8-auth and sentin8-bus
#
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# If the user passed explicit repo names, honour them.  Otherwise default
# to "everything except the workspace root itself (sentin8/)".
if [[ $# -eq 0 ]]; then
    # Gather only directories that already have a .git remote (already-cloned
    # repos).  We use those remotes so nothing has to change if you forked
    # and pointed origin at your own fork.
    declare -a NAMES=()
    for d in "$WORKSPACE_ROOT"/sentin8-*/; do
        [ -d "$d/.git" ] || continue
        NAME="$(basename "$d")"
        REMOTE="$(cd "$d" && git remote get-url origin 2>/dev/null)" || continue
        NAMES+=("$NAME")
    done

    if [[ ${#NAMES[@]} -eq 0 ]]; then
        # No pre-cloned repos - fall back to the known master list.
        NAMES=(
            sentin8-acme sentin8-ai sentin8-app sentin8-auth sentin8-auth-ui
            sentin8-bff   sentin8-bus  sentin8-captain sentin8-ci sentin8-cli
            sentin8-cron  sentin8-dash sentin8-db      sentin8-e2e sentin8-flow
            sentin8-flutter sentin8-func sentin8-packaging sentin8-post sentin8-proxy
            sentin8-sdk sentin8-secrets sentin8-site sentin8-site-engine
            sentin8-stat  sentin8-storage sentin8-sys sentin8-web
        )
    fi
else
    NAMES=("$@")
fi

ORG="Sentin8"   # GitHub org that holds the repos; overridable via env.
: "${SENTIN8_ORG:=}" && ORG="$SENTIN8_ORG"  # honour SENTIN8_ORG if set.

cd "$WORKSPACE_ROOT" || exit 1

for NAME in "${NAMES[@]}"; do
    # Strip the "sentin8-" prefix (if present) and reconstruct the directory name.
    DIR="${NAME}"
    REMOTE="https://github.com/${ORG}/${DIR}.git"

    if [[ -d "$WORKSPACE_ROOT/$DIR/.git" ]]; then
        echo "✓  $DIR already cloned - skipping."
    else
        echo "→ Cloning $REMOTE ..."
        git clone "$REMOTE" "$WORKSPACE_ROOT/$DIR" || { echo "✗  failed: $DIR"; continue; }
    fi
done

echo ""
echo "Done.  ${#NAMES[@]} repos in $(ls -d "$WORKSPACE_ROOT"/sentin8-* 2>/dev/null | wc -l) total."
