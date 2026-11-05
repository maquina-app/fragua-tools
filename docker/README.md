# Fragua agent container (Docker / OrbStack)

A ready-to-run image for the [Fragua](https://fragua.app) agent — a complete
Rails development environment with every common native-extension library
pre-installed, for **Docker** or **[OrbStack](https://orbstack.dev)** on macOS.

Published as **`ghcr.io/maquina-app/fragua-docker:latest`**.

> Full step-by-step setup — installing OrbStack/Docker, host tools, named
> volumes, login, and running the agent — is in **[SETUP.md](./SETUP.md)** and at
> **<https://fragua.app/guides>**. This README covers what the image contains and
> how to build/publish it.
>
> Running on **Apple Container** instead? See the sibling
> [`../container`](../container) image.

## What the image provides

Built on `ubuntu:26.04`, it bundles:

- **Language runtimes via [mise](https://mise.jdx.dev)** — Ruby and Node, pinned
  in `/usr/local/mise/config/config.toml`. Project-level `.mise.toml` files
  override the global versions automatically.
- **Ruby toolchain** — `bundler` and `rails` pre-installed, with global
  `bundle config` build flags wired to the system libraries (`nokogiri`, `pg`,
  `mysql2`, `hiredis`).
- **Full native-extension stack** so `bundle install` "just works":
  - Build toolchain — `build-essential`, `pkg-config`, `cmake`
  - SSL/crypto — `libssl`, `libsodium`, `libsasl2`
  - Databases — SQLite, PostgreSQL (`libpq`), MySQL/MariaDB client, `hiredis`
  - Image/media — ImageMagick, libvips, WebP, JPEG-turbo, PNG, HEIF, EXIF,
    RAW, `ffmpeg`
  - PDF — Liberation / DejaVu / Noto fonts; render with the bundled Chrome
    (Ubuntu 26.04 no longer packages `wkhtmltopdf`)
  - Parsing & RPC — libxml2/libxslt, Protobuf, gRPC tooling
  - Geospatial — GEOS, PROJ (for rgeo)
  - Rendering — Pango, Cairo
- **CLIs** — GitHub CLI (`gh`) with the [`gh-signoff`](https://github.com/basecamp/gh-signoff)
  extension, `git`, Claude Code (`@anthropic-ai/claude-code`), the **Fragua CLI**, the
  **recuerd0 CLI**, and **equipr** (a skills/commands/MCP installer — all installed from
  the latest release).
- **Node / TypeScript** — `typescript`, `tsx`, `pnpm` and `yarn` installed globally,
  plus `python3` so `node-gyp` can build native modules. Global `pnpm add -g`
  packages persist in the `fragua-data` volume.
- **Headless browser automation** — [`agent-browser`](https://www.npmjs.com/package/agent-browser)
  and `playwright`, both using **Google Chrome** from Google's apt repository. The
  build fails if Chrome is below `MIN_CHROME`. No runtime download is needed: use
  `channel: "chrome"` (`--browser chrome` for the Playwright MCP server). A
  project's own Playwright version can still run `npx playwright install chromium`.

  Chrome doesn't update itself inside a container; a rebuild is what patches it.
  The agent runs as root, so Chrome needs `--no-sandbox`. Playwright and
  `agent-browser` handle that, but `--sandbox` makes Chrome refuse to start.

Default command:

```
fragua agent --workdir /fragua-workdir
```

## Volumes

The image is **host-independent**: at runtime it mounts only named volumes — no
host paths, no SSH-agent forwarding. You sign in / set up identity *once inside*
the container (see [SETUP.md](./SETUP.md)), and everything persists in volumes
across rebuilds. This is necessary because on macOS
`gh`/`claude` keep tokens in the Keychain, so a host bind-mount can't deliver them.

| Volume           | Mount path        | Runtime mode | Purpose                                              |
| ---------------- | ----------------- | ------------ | ---------------------------------------------------- |
| `fragua-config`  | `/fragua-config`  | `rw` | fragua token + status/DB, Git identity (`gitconfig`), Claude token + session state (`XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL`, `CLAUDE_CONFIG_DIR=/fragua-config/claude`), and equipr's config + skills cache/state (`/fragua-config/equipr`) plus equipr-installed skills (via `~/.claude` → `/fragua-config/claude`) |
| `fragua-secrets` | `/fragua-secrets` | `ro` | GitHub CLI token (`GH_CONFIG_DIR=/fragua-secrets/gh`) + the container's SSH keypair (`/root/.ssh` → `/fragua-secrets/ssh`). Mounted `rw` only during setup. |
| `fragua-workdir` | `/fragua-workdir` | `rw` | Agent working tree — clones, `bundle install`, DBs, assets (`FRAGUA_WORKDIR`) |
| `fragua-data`    | `/fragua-data`    | `rw` | The active `claude` (`/fragua-data/npm/bin`), `fragua`, `recuerd0`, and `equipr` (`/fragua-data/bin`) CLIs, plus runtime-installed gems + global node modules (`GEM_HOME=/fragua-data/gems`, `NPM_CONFIG_PREFIX=/fragua-data/npm`) — so CLI updates and agent installs survive a rebuild |

Create them once:

```bash
docker volume create fragua-config
docker volume create fragua-secrets
docker volume create fragua-workdir
docker volume create fragua-data
```

`fragua-secrets` holds the credentials the agent uses but must not overwrite (gh
token + SSH **private** key), so it's mounted **read-only at runtime** — and `rw`
only during the one-time setup that writes them. `fragua-data` persists everything
the agent installs at runtime (`gem install`, `bundle install`, `npm install -g`),
which otherwise lives in the container's writable layer and is lost on rebuild.
The `claude`, `fragua`, `recuerd0`, and `equipr` CLIs also live here: the entrypoint installs them on
first boot and they take precedence over the image's baseline copies, so you can
update them from a running container without a rebuild (see
[Updating the CLIs](#updating-the-clis-without-a-rebuild)). The heavy build-time
toolchain (Ruby, Node, Rails, native libraries) stays in the image.

During the one-time setup you choose whether to **reuse your existing host SSH
key + Git identity** or **generate a fresh one** for the container (a new key
must be registered on GitHub). The Claude token is generated on the host once
(`claude setup-token`) and written into `fragua-config`; the image's entrypoint
loads it on every run. See the guide for the exact steps.

## Backing up credentials

`./fragua-backup` packs the files that would otherwise force a full re-setup — the
gh token, SSH keypair, Claude/Codex/fragua tokens, `gitconfig` and the recuerd0
config — into **one archive** you can copy to another machine and restore into
its volumes:

```bash
./fragua-backup                                  # → ./fragua-backups/fragua-backup-<ts>.tgz
./fragua-backup --encrypt                        # → ...tgz.gpg (AES-256, prompts for a passphrase)
./fragua-backup --restore ~/fragua-backup-<ts>.tgz.gpg   # write it into the volumes
```

Both volumes are mounted read-only for a backup, so it's safe while the agent is
running; missing files (a tool you never logged into) are skipped, not fatal. The
restore re-applies the modes the tools require (`700` on `ssh/`, `600` on the
private key and tokens) and root ownership.

A backup pauses to confirm the two fragua fields that are per-machine — the
runner name and `concurrency` (how many processes) — and records your answers in
the archive's copy of `fragua/config.toml`; the live volume is untouched. Two
runners must not share a name, so set a fresh one when cloning to a second
machine: `--runner-name NAME --concurrency N` (or `--yes` to keep both).

Cloning a whole setup to another machine is then: `--encrypt`, `scp`, create the
four volumes there, `--restore`. No re-login, no `claude setup-token`. Details in
[SETUP.md](./SETUP.md#backing-up-your-credentials--and-moving-them-to-another-machine).

## Updating the CLIs without a rebuild

The `claude` and `fragua` CLIs live in the `fragua-data` volume and take
precedence over the baseline copies baked into the image. The entrypoint
installs them on **first boot** if missing, so a fresh volume bootstraps itself
(this needs network access; if it fails, the image baseline is used and a warning
is logged). To pull the latest versions into a running container — no rebuild:

```bash
docker exec fragua-agent fragua-refresh-cli            # update all
docker exec fragua-agent fragua-refresh-cli claude     # just Claude Code
docker exec fragua-agent fragua-refresh-cli fragua     # just fragua
docker exec fragua-agent fragua-refresh-cli recuerd0   # just recuerd0
docker exec fragua-agent fragua-refresh-cli equipr     # just equipr
```

Wiping the `fragua-data` volume re-bootstraps the CLIs on the next start. The
build-time `--refresh-cli` flag (below) is now only needed to refresh the image's
offline baseline.

## Building & publishing

Use the `build.sh` helper in this directory. It builds the image and pushes it
to GHCR by default.

```bash
# build + push ghcr.io/maquina-app/fragua-docker:latest
./build.sh

# build only (no push)
./build.sh --no-push

# clean rebuild
./build.sh --no-cache

# apply OS security updates and re-fetch Chrome + the CLIs (keeps the heavy
# layers cached)
./build.sh --refresh-cli

# multi-arch build + push via buildx (Docker only). Pushes a dated tag, pulls this
# host's variant back as local/fragua:latest, smoke-tests it, then moves :latest.
./build.sh --platform linux/amd64,linux/arm64

# publish without running smoke-test.sh
./build.sh --skip-smoke
```

Every build runs [`smoke-test.sh`](./smoke-test.sh) before `latest` moves, and always
pulls the current `ubuntu:26.04` base. Pushing `latest` also pushes a dated tag
such as `:20261104-1530`, so a bad image can be rolled back:

```bash
docker pull ghcr.io/maquina-app/fragua-docker:20261104-1530
docker tag  ghcr.io/maquina-app/fragua-docker:20261104-1530 local/fragua:latest
```

Multi-arch pushes also attach an SBOM and build provenance, which vulnerability
scanners can read. Rebuild regularly: **only a rebuild applies OS, Chrome, Ruby or
Node security patches**. They don't reach a running container, and image updates
never patch the kernel, which belongs to the host (or OrbStack's VM).

> `--refresh-cli` busts the security-update layer, the CLI + Chrome install layers
> and the cheap ones after, so you get patched packages and the newest CLIs without
> the ~10–15 min full rebuild. Under the hood it passes
> `--build-arg CLI_REFRESH=$(date +%s)`. For the common case — updating the CLIs
> a running agent actually uses — prefer `fragua-refresh-cli` (see
> [Updating the CLIs](#updating-the-clis-without-a-rebuild)); no rebuild needed.

### Authentication

The push targets `ghcr.io`. Either run `docker login ghcr.io` beforehand, or
export credentials and let the script log in for you:

```bash
export GITHUB_USER=<your-github-username>
export GITHUB_TOKEN=<PAT with write:packages scope>
./build.sh
```

### Notes

- **Architecture** — a plain `./build.sh` builds for your host arch (arm64 on
  Apple silicon). Use `--platform linux/amd64,linux/arm64` to publish a
  multi-arch manifest so both Intel and ARM hosts can pull the same tag. This is
  the main advantage over the Apple Container build.
  Publishing single-arch is easy to do by accident and fails late: the mismatch
  is only a `WARNING` on `docker run`, and the image then runs under QEMU, where
  Chromium aborts (`GPU process isn't usable`) rather than failing cleanly.
- **amd64 can't be built under Rosetta** — Ubuntu 26.04's `tar` fails under OrbStack's
  Rosetta emulation (`Cannot mkdir: Function not implemented`), which stops the
  multi-arch build at its first `tar`. Turn Rosetta off to build with QEMU
  (`orb config set rosetta false`, then restart OrbStack). Real amd64 hosts aren't
  affected. Chrome still aborts under QEMU, so test amd64 on a real amd64 host.
- **Package visibility** — the first push creates a **private** package. Make it
  public under
  [`maquina-app` packages](https://github.com/orgs/maquina-app/packages) if you
  want anonymous pulls.
- **Recommended packages are skipped** — the image installs with
  `--no-install-recommends`, so add anything a project needs from those explicitly.
  `wkhtmltopdf` is gone too: Ubuntu 26.04 no longer packages it, so render PDFs
  with Chrome.
- **First build takes ~10–15 min** (the native library layer is large);
  subsequent cached rebuilds are fast.

## Configurable build variables

`build.sh` reads these env vars (defaults shown):

| Var        | Default                    |
| ---------- | -------------------------- |
| `REGISTRY` | `ghcr.io`                  |
| `IMAGE`    | `maquina-app/fragua-docker`|
| `TAG`      | `latest`                   |
| `ENGINE`   | `docker`                   |
