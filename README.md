# fragua-tools

Public release distribution for **Fragua CLI** (`fragua`) — the Fragua execution
host that runs Fragua agents on your own machine.

The source code lives in a private repository; this repository hosts the
downloadable release binaries only. Releases here are produced automatically by
the source repo's release pipeline.

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

## License

The `fragua` binary is proprietary software. See [LICENSE](LICENSE).
