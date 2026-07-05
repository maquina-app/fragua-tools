#!/usr/bin/env bash
#
# pack-claude-plugins.sh — bundle this host's Claude Code plugins for transplant
# into a Fragua agent container.
#
# Claude Code stores marketplace plugins as a self-contained tree under
# ~/.claude/plugins (or $CLAUDE_CONFIG_DIR/plugins):
#
#   installed_plugins.json   registry → absolute installPath into cache/
#   known_marketplaces.json  marketplace sources → absolute installLocation
#   cache/                   the ACTUAL loaded plugin content (commands/skills/agents)
#   marketplaces/            git clones of the marketplace repos (catalog metadata)
#   plugin-catalog-cache.json
#
# Two registry files embed ABSOLUTE host paths (…/Users/you/.claude/plugins/…),
# so the tree can't just be dropped onto another machine — the paths must be
# rewritten to the container's CLAUDE_CONFIG_DIR. install-claude-plugins.sh
# (run inside the container) does that rewrite + merges the enabled-state.
#
# The enabled/disabled state does NOT live with the plugins; it's an
# `enabledPlugins` map in settings.json. We snapshot just that block so the
# installer can merge it into the container's settings.json without clobbering
# anything else.
#
# Usage:  ./pack-claude-plugins.sh [output.tar.gz]   (default: fragua-plugins.tar.gz)
#
set -euo pipefail

SRC="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PLUGINS_DIR="$SRC/plugins"
SETTINGS="$SRC/settings.json"
OUT="${1:-fragua-plugins.tar.gz}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -d "$PLUGINS_DIR" ] || { echo "error: no plugins dir at $PLUGINS_DIR" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 1. Copy the plugins tree. Drop the .git history inside each marketplace clone:
#    it's the bulk of the size and isn't needed to LOAD plugins (only to run
#    `/plugin marketplace update`, which a headless agent never does).
mkdir -p "$STAGE/plugins"
( cd "$PLUGINS_DIR" && tar --exclude='marketplaces/*/.git' -cf - . ) \
  | ( cd "$STAGE/plugins" && tar -xf - )

# 2. Record the absolute source prefix so the installer knows what to rewrite.
printf '%s\n' "$PLUGINS_DIR" > "$STAGE/SOURCE_PREFIX"

# 3. Snapshot the enabledPlugins block (python3 ships on macOS; tolerate a
#    missing/!json settings file by emitting an empty map).
python3 - "$SETTINGS" "$STAGE/enabled-plugins.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(src))
except Exception:
    data = {}
json.dump(data.get("enabledPlugins", {}), open(dst, "w"), indent=2)
PY

# 4. Ship the installer alongside the payload (also kept in the repo).
cp "$HERE/install-claude-plugins.sh" "$STAGE/" 2>/dev/null || true

tar -C "$STAGE" -czf "$OUT" .

echo "Wrote $OUT ($(du -h "$OUT" | cut -f1)) containing:"
echo "  plugins/                  $(du -sh "$STAGE/plugins" | cut -f1) (cache + marketplaces, no .git)"
echo "  enabled-plugins.json      $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$STAGE/enabled-plugins.json") enabled"
echo "  install-claude-plugins.sh"
echo
echo "Next: copy $OUT into the container and run install-claude-plugins.sh there"
echo "(see SETUP.md → 'Transplant your Claude Code plugins')."
