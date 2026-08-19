FROM ubuntu:24.04

LABEL org.opencontainers.image.source=https://github.com/maquina-app/fragua-tools
LABEL org.opencontainers.image.description="Fragua agent runtime — full Rails stack with all native development libraries, for Apple Container / Docker"
LABEL org.opencontainers.image.licenses=MIT

ENV container=container
ENV DEBIAN_FRONTEND=noninteractive
ENV XDG_CONFIG_HOME=/fragua-config
ENV FRAGUA_WORKDIR=/fragua-workdir
# Per-tool config dirs, consolidated into two volumes by mount mode:
#   • /fragua-config  (rw)  — fragua + git + claude state/token
#   • /fragua-secrets (ro at runtime) — gh + ssh, the credentials the agent uses
#     but must not overwrite. gh and ssh store secrets in plaintext on Linux.
ENV GH_CONFIG_DIR=/fragua-secrets/gh
ENV GH_NO_UPDATE_NOTIFIER=1
ENV CLAUDE_CONFIG_DIR=/fragua-config/claude
ENV CODEX_HOME=/fragua-config/codex
# Runs as root by design. Claude Code refuses --dangerously-skip-permissions as
# root unless a sandbox is detected; IS_SANDBOX=1 is that signal. ENV so it
# reaches entrypoint/CMD, shells, and `container exec` alike. See SETUP.md.
ENV IS_SANDBOX=1
# Git reads its global config from here → persisted in the fragua-config volume,
# so identity is set once in-container instead of bind-mounting host ~/.gitconfig.
ENV GIT_CONFIG_GLOBAL=/fragua-config/gitconfig
ENV MISE_DATA_DIR=/usr/local/mise
ENV MISE_CONFIG_DIR=/usr/local/mise/config
ENV PATH=/usr/local/mise/shims:/usr/local/mise/bin:$PATH

# ── Systemd tuning for Apple container VMs ───────────────────────────────────
RUN apt-get update && apt-get install -y systemd dbus \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && >/etc/machine-id && >/var/lib/dbus/machine-id \
    && systemctl set-default multi-user.target \
    && systemctl mask \
        dev-hugepages.mount sys-fs-fuse-connections.mount \
        systemd-update-utmp.service systemd-tmpfiles-setup.service \
        console-getty.service \
    && systemctl disable networkd-dispatcher.service 2>/dev/null || true

# ── Native extension libs ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    \
    # build toolchain
    build-essential pkg-config cmake \
    \
    # SSL / crypto
    libssl-dev \
    \
    # Ruby build deps
    libreadline-dev zlib1g-dev libyaml-dev libffi-dev \
    libgmp-dev libgdbm-dev libdb-dev \
    \
    # compression
    liblzma-dev libbz2-dev libzstd-dev \
    \
    # nokogiri
    libxml2-dev libxslt1-dev libexpat1-dev \
    \
    # databases
    sqlite3 libsqlite3-dev \
    libpq-dev \
    default-libmysqlclient-dev \
    \
    # Redis — hiredis fast client
    libhiredis-dev \
    \
    # gRPC / Protobuf
    libprotobuf-dev protobuf-compiler \
    \
    # image processing
    imagemagick libvips-dev \
    libwebp-dev libjpeg-turbo8-dev libpng-dev \
    libheif-dev libexif-dev libraw-dev \
    ffmpeg \
    \
    # PDF generation
    wkhtmltopdf \
    fonts-liberation fonts-dejavu fonts-noto \
    \
    # geospatial (rgeo)
    libgeos-dev libproj-dev \
    \
    # font / graphics rendering
    libpango1.0-dev libcairo2-dev \
    \
    # network + utils
    curl wget git ca-certificates gnupg openssh-client unzip \
    \
    # rbnacl — JWT, modern crypto
    libsodium-dev \
    \
    # ruby-ldap, enterprise auth
    libsasl2-dev \
    \
    # libgdal-dev  # PostGIS / heavy geospatial (+150MB) — uncomment if needed
    \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI ────────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── SSH known_hosts — let git authenticate to GitHub non-interactively ─────────
# Without this, the agent's first `git@github.com` push fails host-key
# verification ("Host key verification failed") before auth even happens.
RUN mkdir -p /etc/ssh \
    && ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >> /etc/ssh/ssh_known_hosts

# ── mise ──────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/mise/bin/mise sh \
    && mise settings set experimental true

RUN mkdir -p /usr/local/mise/config \
    && cat > /usr/local/mise/config/config.toml <<'EOF'
[tools]
ruby = "4.0.0"
node = "26"
EOF

RUN mise install --yes \
    && mise reshim \
    && rm -rf /root/.cache/mise

# ── Bundler — system libs for native gems ────────────────────────────────────
RUN bundle config set --global build.nokogiri \
        "--use-system-libraries --with-xml2-include=/usr/include/libxml2" \
    && bundle config set --global build.pg \
        "--with-pg-config=$(which pg_config)" \
    && bundle config set --global build.mysql2 \
        "--with-mysql-config=$(which mysql_config)" \
    && bundle config set --global build.hiredis \
        "--with-hiredis-dir=/usr"

# ── Ruby gems ─────────────────────────────────────────────────────────────────
RUN gem install bundler \
    && gem install rails

# ── Claude Code + Fragua CLI ──────────────────────────────────────────────────
# Bump CLI_REFRESH to re-fetch the latest Claude Code AND fragua release without
# a full --no-cache rebuild — it busts this layer and everything after it:
#   container build --build-arg CLI_REFRESH=$(date +%s) ...
ARG CLI_REFRESH=0

RUN echo "cli refresh=${CLI_REFRESH}" \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

RUN curl -fsSL \
    https://github.com/maquina-app/fragua-tools/releases/latest/download/install.sh | sh

RUN curl -fsSL \
    https://github.com/maquina-app/recuerd0-cli/releases/latest/download/install.sh | sh

RUN curl -fsSL \
    https://github.com/maquina-app/equipr/releases/latest/download/install.sh | sh

RUN npm install -g @openai/codex \
    && npm cache clean --force

RUN npm install -g agent-browser \
    && npx --yes playwright install --with-deps chromium \
    && ln -sf "$(find /root/.cache/ms-playwright -name chrome -type f -path '*chrome-linux*' | head -n1)" /usr/local/bin/chromium \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/local/bin/chromium

RUN gh extension install basecamp/gh-signoff

# Config/secret dirs, plus the runtime-toolchain volume mountpoint. The agent's
# own SSH dir is a symlink into the (read-only at runtime) secrets volume, so the
# key lives beside the gh token and the agent can use but not overwrite it.
RUN mkdir -p \
        /fragua-config /fragua-config/claude /fragua-config/codex \
        /fragua-config/agents/skills \
        /fragua-secrets/gh /fragua-secrets/ssh \
        /fragua-workdir \
        /fragua-data/gems /fragua-data/npm /fragua-data/bin \
    && printf '[settings]\ncli_auth_credentials_store = "file"\n' > /fragua-config/codex/config.toml \
    && rm -rf /root/.ssh \
    && ln -s /fragua-secrets/ssh /root/.ssh \
    && chmod 700 /fragua-secrets/ssh \
    && rm -rf /root/.agents \
    && ln -s /fragua-config/agents /root/.agents \
    && rm -rf /root/.claude \
    && ln -s /fragua-config/claude /root/.claude \
    && mkdir -p /root/.cache /root/.local/state \
    && ln -s /fragua-config/equipr/cache /root/.cache/equipr \
    && ln -s /fragua-config/equipr/state /root/.local/state/equipr

# npm CLI promote/install helper — called by fragua-refresh-cli with <bin> <pkg> <mode>
RUN cat > /usr/local/bin/fragua-npm-cli <<'EOF'
#!/bin/sh
set -e
bin=$1; pkg=$2; mode=${3:-all}
# The image's npm globals live under whatever prefix mise set up, not
# /usr/local. Ask npm with the volume prefix unset so we resolve the image
# baseline instead of the volume copy we are about to replace.
ipfx=$(NPM_CONFIG_PREFIX= npm prefix -g 2>/dev/null || true); ipfx=${ipfx:-/usr/local}
base=$ipfx/bin/$bin; bpkg=$ipfx/lib/node_modules/$pkg
vol=/fragua-data/npm/bin/$bin
vpkg=/fragua-data/npm/lib/node_modules/$pkg; do_net=0
ver() { [ -x "$1" ] || return 0; { "$1" --version 2>/dev/null || "$1" version 2>/dev/null; } | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1; }
is_newer() { [ -n "$1" ] || return 1; [ -n "$2" ] || return 0; [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }
case "$mode" in
  all)        do_net=1 ;;
  if-missing) [ -x "$vol" ] || do_net=1 ;;
  promote)
    bv=$(ver "$base"); vv=$(ver "$vol")
    if [ -e "$base" ] && { [ ! -e "$vol" ] || is_newer "$bv" "$vv"; }; then
      echo "==> promoting $bin ${vv:-(absent)} -> ${bv:-?} from the image baseline"
      rm -rf "$vpkg"; mkdir -p "$(dirname "$vpkg")"
      cp -a "$bpkg" "$(dirname "$vpkg")/"
      # The baseline bin is a relative symlink into its own node_modules; reuse
      # that target verbatim so the volume link resolves inside the volume.
      tgt=$(readlink "$base" 2>/dev/null || true)
      case "$tgt" in
        ../lib/node_modules/*) ln -sf "$tgt" "$vol" ;;
        *) cp -a "$base" "$vol" ;;
      esac
    fi ;;
esac
# Must not be a bare `[ ... ] && cmd`: that returns 1 when do_net=0 and `set -e`
# would abort the caller mid-way through its CLI list.
if [ "$do_net" = 1 ]; then npm install -g "$pkg"; fi
EOF
RUN chmod +x /usr/local/bin/fragua-npm-cli

# Runtime CLI refresh: maintains the /fragua-data (PATH-first) copies. Entrypoint
# runs it --promote each boot. Keep lean (Apple Container Dockerfile limit).
RUN cat > /usr/local/bin/fragua-refresh-cli <<'EOF'
#!/bin/sh
set -e
MODE=all; ONLY=""
for a in "$@"; do
  case "$a" in
    --promote)     MODE=promote ;;
    --if-missing)  MODE=if-missing ;;
    claude|codex|fragua|recuerd0|equipr) ONLY="$a" ;;
    *) echo "usage: fragua-refresh-cli [--promote|--if-missing] [claude|codex|fragua|recuerd0|equipr]" >&2; exit 1 ;;
  esac
done
export NPM_CONFIG_PREFIX=/fragua-data/npm
mkdir -p /fragua-data/npm/lib/node_modules/@anthropic-ai /fragua-data/npm/lib/node_modules/@openai /fragua-data/npm/bin /fragua-data/bin

# The volume holds arch-specific binaries. If it was filled on another arch
# (image rebuilt or pulled for a different platform) those copies are junk:
# dynamically linked ones fail outright, static ones silently run under QEMU.
# Drop them so this run re-promotes from the image baseline.
ARCH=$(uname -m); STAMP=/fragua-data/.arch
mach() { od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n'; }
stale=0
if [ -f "$STAMP" ]; then
  [ "$(cat "$STAMP" 2>/dev/null)" = "$ARCH" ] || stale=1
elif [ -e /fragua-data/bin/fragua ] && [ -e /usr/local/bin/fragua ]; then
  # No stamp: volume predates it, so compare ELF machine against the baseline.
  [ "$(mach /fragua-data/bin/fragua)" = "$(mach /usr/local/bin/fragua)" ] || stale=1
fi
if [ "$stale" = 1 ]; then
  echo "==> volume CLI copies are for another arch - clearing so this boot re-promotes"
  rm -rf /fragua-data/npm/lib/node_modules/@anthropic-ai/claude-code \
         /fragua-data/npm/lib/node_modules/@openai/codex \
         /fragua-data/npm/bin/claude /fragua-data/npm/bin/codex \
         /fragua-data/bin/fragua /fragua-data/bin/recuerd0 /fragua-data/bin/equipr
fi
printf '%s\n' "$ARCH" > "$STAMP" 2>/dev/null || true
# Native gem extensions are arch-specific too, but rebuilding them is per-project
# work (bundle install), so say so rather than deleting someone's gems.
if [ -d /fragua-data/gems/extensions ] \
   && ls /fragua-data/gems/extensions 2>/dev/null | grep -qv "^${ARCH}-"; then
  echo "warn: /fragua-data/gems has extensions built for another arch;" >&2
  echo "      run 'bundle install' in affected projects to rebuild them." >&2
fi

want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# version via `--version` (fragua/claude) or the `version` subcommand (recuerd0)
ver() { [ -x "$1" ] || return 0; { "$1" --version 2>/dev/null || "$1" version 2>/dev/null; } | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1; }

is_newer() {
  [ -n "$1" ] || return 1
  [ -n "$2" ] || return 0
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

static_cli() {  # <name> <install-url> — single static binary CLIs (fragua, recuerd0)
  want "$1" || return 0
  base=/usr/local/bin/$1; vol=/fragua-data/bin/$1; do_net=0
  case "$MODE" in
    all)        do_net=1 ;;
    if-missing) [ -x "$vol" ] || do_net=1 ;;
    promote)
      bv=$(ver "$base"); vv=$(ver "$vol")
      if [ ! -x "$vol" ] || is_newer "$bv" "$vv"; then
        echo "==> promoting $1 ${vv:-(absent)} -> ${bv:-?} from the image baseline"
        install -D -m 0755 "$base" "$vol"
      fi ;;
  esac
  if [ "$do_net" = 1 ]; then
    echo "==> installing the latest $1 CLI into the volume"
    curl -fsSL "$2" | sh
    install -D -m 0755 "$base" "$vol"
  fi
}
static_cli fragua   https://github.com/maquina-app/fragua-tools/releases/latest/download/install.sh
static_cli recuerd0 https://github.com/maquina-app/recuerd0-cli/releases/latest/download/install.sh
static_cli equipr   https://github.com/maquina-app/equipr/releases/latest/download/install.sh

if want claude; then fragua-npm-cli claude @anthropic-ai/claude-code "$MODE"; fi
if want codex;  then fragua-npm-cli codex  @openai/codex             "$MODE"; fi

echo "==> active CLIs:"
command -v fragua && fragua --version 2>/dev/null || true
command -v claude && claude --version 2>/dev/null || true
command -v codex && codex --version 2>/dev/null || true
command -v recuerd0 && recuerd0 version 2>/dev/null || true
command -v equipr && equipr --version 2>/dev/null || true
EOF
RUN chmod +x /usr/local/bin/fragua-refresh-cli

# ── Entrypoint — load Claude token + wire the runtime-toolchain volume ─────────
# Toolchain redirect is set HERE (runtime), not as build ENV, so build-time
# gem/npm installs land in the image (refreshable), not the empty volume that
# would hide them. An explicit --env CLAUDE_CODE_OAUTH_TOKEN wins. See SETUP.md.
RUN cat > /usr/local/bin/fragua-entrypoint.sh <<'EOF'
#!/bin/sh
set -e
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r /fragua-config/claude-oauth-token ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(cat /fragua-config/claude-oauth-token)"
  export CLAUDE_CODE_OAUTH_TOKEN
fi
mkdir -p /fragua-data/gems /fragua-data/npm /fragua-data/bin 2>/dev/null || true
export GEM_HOME=/fragua-data/gems
export GEM_PATH="${GEM_HOME}:$(ruby -e 'print Gem.default_dir' 2>/dev/null)"
export NPM_CONFIG_PREFIX=/fragua-data/npm
export PATH="/fragua-data/gems/bin:/fragua-data/npm/bin:/fragua-data/bin:${PATH}"
fragua-refresh-cli --promote || echo "warn: CLI promote skipped (using whatever is on PATH)" >&2
exec "$@"
EOF
RUN chmod +x /usr/local/bin/fragua-entrypoint.sh

# Replicate the same exports for shells that bypass the entrypoint — login shells
# (`exec ... bash -l`, /etc/profile.d) and non-login interactive bash
# (`exec ... bash`, /etc/bash.bashrc) — so the token + toolchain paths are present.
RUN cat > /etc/profile.d/fragua-runtime.sh <<'EOF'
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r /fragua-config/claude-oauth-token ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(cat /fragua-config/claude-oauth-token)"
fi
export GEM_HOME=/fragua-data/gems
export GEM_PATH="${GEM_HOME}:$(ruby -e 'print Gem.default_dir' 2>/dev/null)"
export NPM_CONFIG_PREFIX=/fragua-data/npm
export PATH="/fragua-data/gems/bin:/fragua-data/npm/bin:/fragua-data/bin:${PATH}"
EOF

RUN { \
      echo '[ -r /fragua-config/claude-oauth-token ] && export CLAUDE_CODE_OAUTH_TOKEN="$(cat /fragua-config/claude-oauth-token)"'; \
      echo 'export GEM_HOME=/fragua-data/gems'; \
      echo 'export GEM_PATH="${GEM_HOME}:$(ruby -e '"'"'print Gem.default_dir'"'"' 2>/dev/null)"'; \
      echo 'export NPM_CONFIG_PREFIX=/fragua-data/npm'; \
      echo 'export PATH="/fragua-data/gems/bin:/fragua-data/npm/bin:/fragua-data/bin:${PATH}"'; \
    } >> /etc/bash.bashrc

ENTRYPOINT ["/usr/local/bin/fragua-entrypoint.sh"]
CMD ["fragua", "agent", "--workdir", "/fragua-workdir"]
