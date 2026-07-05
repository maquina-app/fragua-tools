#!/usr/bin/env bash
#
# install-claude-plugins.sh — INSTALL the bundle produced by pack-claude-plugins.sh
# INTO a Fragua agent container.
#
# Run this *inside* the container's one-time setup shell (where /fragua-config is
# mounted rw). It:
#   1. extracts the plugins tree into $CLAUDE_CONFIG_DIR/plugins  (the rw
#      `fragua-config` volume → survives rebuilds);
#   2. rewrites the absolute host paths baked into installed_plugins.json
#      (installPath) and known_marketplaces.json (installLocation) to the
#      container's path;
#   3. merges the bundled enabledPlugins map into $CLAUDE_CONFIG_DIR/settings.json,
#      preserving any other settings.
#
# Usage (inside the container):
#   bash install-claude-plugins.sh /path/to/fragua-plugins.tar.gz
#
set -euo pipefail

BUNDLE="${1:?usage: install-claude-plugins.sh /path/to/fragua-plugins.tar.gz}"
DEST="${CLAUDE_CONFIG_DIR:-/fragua-config/claude}"
DEST_PLUGINS="$DEST/plugins"

[ -f "$BUNDLE" ] || { echo "error: bundle not found: $BUNDLE" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -C "$TMP" -xzf "$BUNDLE"

SRC_PREFIX="$(cat "$TMP/SOURCE_PREFIX")"

# 1. Drop the tree into place (cp -a preserves perms/symlinks; merges if a tree
#    already exists rather than failing).
mkdir -p "$DEST_PLUGINS"
cp -a "$TMP/plugins/." "$DEST_PLUGINS/"

# 2. Rewrite absolute host paths → container path. The registries reference the
#    cache/ and marketplaces/ subdirs by absolute path; nothing else does. Done
#    in node (always present, portable) to avoid BSD/GNU sed -i differences.
for f in installed_plugins.json known_marketplaces.json; do
  if [ -f "$DEST_PLUGINS/$f" ]; then
    node -e '
      const fs = require("fs");
      const [, file, from, to] = process.argv;   // node -e: argv[1] is first arg
      fs.writeFileSync(file, fs.readFileSync(file, "utf8").split(from).join(to));
    ' "$DEST_PLUGINS/$f" "$SRC_PREFIX" "$DEST_PLUGINS"
  fi
done

# 3. Merge enabledPlugins into settings.json (create the file if absent). node is
#    always present in this image (Claude Code runs on it).
SETTINGS="$DEST/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
node -e '
  const fs = require("fs");
  const [, settingsPath, enabledPath] = process.argv;   // node -e: argv[1] is first arg
  const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  const enabled  = JSON.parse(fs.readFileSync(enabledPath, "utf8"));
  settings.enabledPlugins = Object.assign({}, settings.enabledPlugins, enabled);
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
' "$SETTINGS" "$TMP/enabled-plugins.json"

echo "Installed plugins into $DEST_PLUGINS"
echo "  marketplaces: $(ls "$DEST_PLUGINS/marketplaces" 2>/dev/null | tr '\n' ' ')"
echo "  enabled:      $(node -e 'console.log(Object.keys(require(process.argv[1]).enabledPlugins||{}).join(", "))' "$SETTINGS")"
echo
echo "Verify after starting the agent:  claude --debug   (look for plugin load lines)"
