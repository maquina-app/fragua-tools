# Copy Claude Code plugins into a Fragua container

Claude Code plugins installed on the host (`~/.claude/plugins/`) do **not** exist
inside a fresh Fragua agent container. This document explains how to bundle them,
install them into the container's persistent config volume, and verify they load.

## Why a plain copy doesn't work

The plugin tree is self-contained, but the two registry files embed **absolute host
paths** that don't exist in the container:

- `installed_plugins.json` → `installPath` points into `~/.claude/plugins/cache/…`
- `known_marketplaces.json` → `installLocation` points into `~/.claude/plugins/marketplaces/…`

So the tree must be copied **and** those paths rewritten to the container's
`CLAUDE_CONFIG_DIR` (`/fragua-config/claude`). Separately, the enabled/disabled
state lives in `settings.json` under `enabledPlugins` (`"plugin@marketplace": true`),
not with the plugins — it must be merged in too.

The destination, `/fragua-config/claude`, is in the **`fragua-config` rw volume**,
so once installed the plugins survive `--refresh-cli` and full image rebuilds.

> **Caveat:** `CLAUDE_CONFIG_DIR`, `installed_plugins.json`, and `known_marketplaces.json`
> are undocumented Claude Code internals. This works today but a future release could
> change the layout. The two scripts below are small and easy to adjust if so.

## The two scripts (this `plugins/` folder)

- **`pack-claude-plugins.sh`** — run on the **host**. Bundles `~/.claude/plugins/`
  (dropping marketplace `.git` history), snapshots the `enabledPlugins` block from
  `settings.json`, records the source path prefix, and tucks the installer inside
  the tarball. Output: `fragua-plugins.tar.gz` (~3 MB).
- **`install-claude-plugins.sh`** — run **inside the container**. Extracts into
  `$CLAUDE_CONFIG_DIR/plugins`, rewrites the absolute host paths to the container
  path (done in `node` for portability), and merges `enabledPlugins` into
  `settings.json` without clobbering other settings.

## Procedure

### 1. Bundle on the host (from this `plugins/` folder)

```bash
cd plugins
./pack-claude-plugins.sh                 # → ./fragua-plugins.tar.gz
# optional: silence macOS xattr warnings on extraction
COPYFILE_DISABLE=1 ./pack-claude-plugins.sh
```

### 2. Install inside the container

Use `fragua-host shell`, which mounts `$PWD` at `/host` — but **only when the agent
is stopped** (a running agent execs into the live container with no `/host` mount,
since the named volumes are single-RW-attach). So stop it first:

```bash
fragua-host -c down                      # -d for Docker/OrbStack
fragua-host -c shell                     # $PWD → /host

# inside the setup shell:
mkdir -p /tmp/fp && tar -xzf /host/fragua-plugins.tar.gz -C /tmp/fp
bash /tmp/fp/install-claude-plugins.sh /host/fragua-plugins.tar.gz
exit

fragua-host -c up
```

**Alternatives without the launcher:** add `-v "$PWD/fragua-plugins.tar.gz":/host-plugins.tar.gz:ro`
to the setup-shell `run` command, or `docker cp` the tarball into a running container
then `docker exec` the installer.

> A harmless `tar: Ignoring unknown extended header keyword 'LIBARCHIVE.xattr.com.apple.provenance'`
> warning on extraction is just macOS xattr metadata that GNU tar skips — extraction
> still succeeds.

## Verification (run inside the container)

Three levels, fastest first.

### A. On-disk sanity — no model call, instant

```bash
echo "$CLAUDE_CONFIG_DIR"                                              # /fragua-config/claude
ls "$CLAUDE_CONFIG_DIR"/plugins/marketplaces                          # maquina  claude-plugins-official
grep -c '/fragua-config' "$CLAUDE_CONFIG_DIR"/plugins/installed_plugins.json   # >0 → paths rewritten
grep -c '/Users/'        "$CLAUDE_CONFIG_DIR"/plugins/installed_plugins.json   # MUST be 0
node -e 'console.log(Object.keys(require(process.env.CLAUDE_CONFIG_DIR+"/settings.json").enabledPlugins||{}))'
```

### B. Loader debug — confirms Claude actually loads them

```bash
claude --debug -p "reply with the single word: ok" 2>&1 \
  | grep -iE "plugin|marketplace|skill|command" | head -40
```

You should see it reading `/fragua-config/claude/plugins` and registering each
marketplace. Plugins that are present but **disabled** show up skipped here — that
means the `enabledPlugins` merge didn't take (re-check step A).

### C. Behavioral — the model enumerates what it has

This prompt works well as the definitive check:

```bash
claude -p "List every plugin-provided skill, slash command, and subagent currently available to you. Just the names."
```

Enabled plugins inject their skills/commands/subagents into the model's context, so
a correct install makes them appear by name. If a plugin is missing or disabled, it
simply won't be listed (the model won't invent it). Use level B as the tiebreaker if
the output looks incomplete.

## When to re-run

Only when you add or update plugins on the host: re-run `pack-claude-plugins.sh`,
then the install step again. Routine rebuilds (`build.sh`, `--refresh-cli`) preserve
the plugins because they live in the `fragua-config` volume.
