# Fragua agent container

A ready-to-run image for the [Fragua](https://fragua.app) agent — a complete
Rails development environment with every common native-extension library
pre-installed, tuned to run under [Apple Container](https://github.com/apple/container)
(and compatible with Docker).

Published as **`ghcr.io/maquina-app/fragua-container:latest`**.

> Full step-by-step setup — installing Apple Container, starting the runtime
> (kernel install), host tools, named volumes, login, and running the agent —
> is in **[SETUP.md](./SETUP.md)** and at **<https://fragua.app/guides>**. This
> README covers what the image contains and how to build/publish it.

## What the image provides

Built on `ubuntu:24.04` and tuned for Apple Container VMs (systemd trimmed for
fast boot), it bundles:

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
  - PDF — `wkhtmltopdf` plus Liberation / DejaVu / Noto fonts
  - Parsing & RPC — libxml2/libxslt, Protobuf, gRPC tooling
  - Geospatial — GEOS, PROJ (for rgeo)
  - Rendering — Pango, Cairo
- **CLIs** — GitHub CLI (`gh`), `git`, Claude Code (`@anthropic-ai/claude-code`),
  and the **Fragua CLI** (installed from the latest release).

Default command:

```
fragua agent --workdir /fragua-workdir
```

## Volumes

The image is **host-independent**: at runtime it mounts only named volumes — no
host paths, no `--ssh`. You sign in / set up identity *once inside* the container
(see [SETUP.md](./SETUP.md)), and everything persists in volumes across rebuilds.
This is necessary because on macOS `gh`/`claude` keep tokens in the Keychain, so
a host bind-mount can't deliver them.

| Volume           | Mount path        | Runtime mode | Purpose                                              |
| ---------------- | ----------------- | ------------ | ---------------------------------------------------- |
| `fragua-config`  | `/fragua-config`  | `rw` | fragua token + status/DB, Git identity (`gitconfig`), Claude token + session state (`XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL`, `CLAUDE_CONFIG_DIR=/fragua-config/claude`) |
| `fragua-secrets` | `/fragua-secrets` | `ro` | GitHub CLI token (`GH_CONFIG_DIR=/fragua-secrets/gh`) + the container's SSH keypair (`/root/.ssh` → `/fragua-secrets/ssh`). Mounted `rw` only during setup. |
| `fragua-workdir` | `/fragua-workdir` | `rw` | Agent working tree — clones, `bundle install`, DBs, assets (`FRAGUA_WORKDIR`) |
| `fragua-data`    | `/fragua-data`    | `rw` | Runtime-installed gems + global node modules + bins (`GEM_HOME=/fragua-data/gems`, `NPM_CONFIG_PREFIX=/fragua-data/npm`) — so agent installs survive a rebuild |

Create them once:

```bash
container volume create fragua-config
container volume create fragua-secrets
container volume create fragua-workdir
container volume create fragua-data
```

`fragua-secrets` holds the credentials the agent uses but must not overwrite (gh
token + SSH **private** key), so it's mounted **read-only at runtime** — and `rw`
only during the one-time setup that writes them. `fragua-data` persists everything
the agent installs at runtime (`gem install`, `bundle install`, `npm install -g`),
which otherwise lives in the container's writable layer and is lost on rebuild;
the build-time toolchain (Ruby, Node, Rails, Claude Code, fragua) stays in the
image so `--refresh-cli` still updates it.

During the one-time setup you choose whether to **reuse your existing host SSH
key + Git identity** or **generate a fresh one** for the container (a new key
must be registered on GitHub). The Claude token is generated on the host once
(`claude setup-token`) and written into `fragua-config`; the image's entrypoint
loads it on every run. See the guide for the exact steps.

## Building & publishing

Use the `build.sh` helper in this directory. It builds the image and pushes it
to GHCR by default.

```bash
# build + push ghcr.io/maquina-app/fragua-container:latest
./build.sh

# build only (no push)
./build.sh --no-push

# clean rebuild
./build.sh --no-cache

# re-fetch the latest Claude Code + fragua CLI (keeps the heavy layers cached)
./build.sh --refresh-cli

# build with Docker instead of Apple Container
./build.sh --engine docker
```

> `--refresh-cli` busts only the Claude Code + fragua install layers (and the
> cheap ones after), so you get the newest CLIs without the ~10–15 min full
> rebuild. Under the hood it passes `--build-arg CLI_REFRESH=$(date +%s)`.

### Authentication

The push targets `ghcr.io`. Either log in beforehand
(`container registry login ghcr.io` / `docker login ghcr.io`), or export
credentials and let the script log in for you:

```bash
export GITHUB_USER=<your-github-username>
export GITHUB_TOKEN=<PAT with write:packages scope>
./build.sh
```

### Notes

- **Architecture** — building on Apple silicon produces a `linux/arm64` image.
  It runs natively under Apple Container and on arm64 Docker hosts. amd64 hosts
  need a separately built/multi-arch image.
- **Package visibility** — the first push creates a **private** package. Make it
  public under
  [`maquina-app` packages](https://github.com/orgs/maquina-app/packages) if you
  want anonymous pulls.
- **First build takes ~10–15 min** (the native library layer is large);
  subsequent cached rebuilds are fast.

## Configurable build variables

`build.sh` reads these env vars (defaults shown):

| Var        | Default                       |
| ---------- | ----------------------------- |
| `REGISTRY` | `ghcr.io`                     |
| `IMAGE`    | `maquina-app/fragua-container`|
| `TAG`      | `latest`                      |
| `ENGINE`   | `container`                   |
