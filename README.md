# fragua-tools

Public home of the **Fragua CLI** (`fragua`) — the Fragua execution host that runs
Fragua agents on your own machine. This repository holds two things:

- **Release binaries** — produced automatically by the release pipeline of the
  private source repository. The CLI's source code is not here.
- **Container images** — the definitions for images that package `fragua` with a
  full Rails development environment. See
  [Run it in a container](#run-it-in-a-container).

## Install

**Homebrew (macOS):**

```
brew install maquina-app/tap/fragua
```

**curl (macOS + Linux, including Arch):**

```
curl -fsSL https://github.com/maquina-app/fragua-tools/releases/latest/download/install.sh | sh
```

The installer detects your OS/arch, downloads the matching `fragua-<os>-<arch>`
asset, verifies its sha256 against `checksums.txt`, and installs to
`/usr/local/bin` (falling back to `$HOME/.local/bin`).

**Debian/Ubuntu (`.deb`) and Fedora/RHEL (`.rpm`):** attached to each
[release](https://github.com/maquina-app/fragua-tools/releases).

**Windows:** download `fragua-windows-amd64.zip` (or `-arm64`) from the
[latest release](https://github.com/maquina-app/fragua-tools/releases/latest),
unzip, and put `fragua.exe` on your `PATH`. Everything works except service
install — `fragua agent install/start/stop` reports an unsupported-OS error; run
`fragua agent` directly instead.

> The installer never starts the service for you — the daemon needs your keychain
> token first. After installing, run `fragua login`, then `fragua agent install`.

## Run it in a container

To run the agent isolated from your machine, use one of the ready-made images
instead of installing the CLI. Both include a Rails development environment with
the common native libraries, plus `fragua`, Claude Code, `gh`, `recuerd0` and
`equipr`. You sign in once inside the container, and named volumes keep your
credentials and work across rebuilds.

| Your runtime          | Image                                     | Setup guide                        |
| --------------------- | ----------------------------------------- | ---------------------------------- |
| Apple Container       | `ghcr.io/maquina-app/fragua-container`    | [container/SETUP.md](container/SETUP.md) |
| Docker or OrbStack    | `ghcr.io/maquina-app/fragua-docker`       | [docker/SETUP.md](docker/SETUP.md) |

Each directory's `README.md` covers what its image contains and how to build it
yourself.

## License

The `fragua` binary is proprietary software. See [LICENSE](LICENSE).
