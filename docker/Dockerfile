FROM ubuntu:24.04

LABEL org.opencontainers.image.source=https://github.com/maquina-app/fragua-tools
LABEL org.opencontainers.image.description="Fragua agent runtime — full Rails stack with all native development libraries, for Docker / OrbStack"
LABEL org.opencontainers.image.licenses=MIT

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
# Git reads its global config from here → persisted in the fragua-config volume,
# so identity is set once in-container instead of bind-mounting host ~/.gitconfig.
ENV GIT_CONFIG_GLOBAL=/fragua-config/gitconfig
ENV MISE_DATA_DIR=/usr/local/mise
ENV MISE_CONFIG_DIR=/usr/local/mise/config
ENV PATH=/usr/local/mise/shims:/usr/local/mise/bin:$PATH

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
    # optional — uncomment if needed:
    # libgdal-dev         # PostGIS / heavy geospatial (+150MB)
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
    && mise reshim

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
#   docker build --build-arg CLI_REFRESH=$(date +%s) ...
ARG CLI_REFRESH=0

RUN echo "cli refresh=${CLI_REFRESH}" \
    && npm install -g @anthropic-ai/claude-code

RUN curl -fsSL \
    https://github.com/maquina-app/fragua-tools/releases/latest/download/install.sh | sh

# Config/secret dirs, plus the runtime-toolchain volume mountpoint. The agent's
# own SSH dir is a symlink into the (read-only at runtime) secrets volume, so the
# key lives beside the gh token and the agent can use but not overwrite it.
RUN mkdir -p \
        /fragua-config /fragua-config/claude \
        /fragua-secrets/gh /fragua-secrets/ssh \
        /fragua-workdir \
        /fragua-data/gems /fragua-data/npm /fragua-data/bin \
    && rm -rf /root/.ssh \
    && ln -s /fragua-secrets/ssh /root/.ssh \
    && chmod 700 /fragua-secrets/ssh

# ── Runtime CLI refresh — install/update Claude Code + fragua into the volume ──
# The build-time installs above are an offline baseline; this script puts fresh
# copies in the rw /fragua-data volume (first on PATH) so the CLIs can be updated
# from a running container with no image rebuild. The entrypoint runs it with
# --if-missing on first boot; run it by hand to force an update:
#   docker compose exec fragua-agent fragua-refresh-cli
RUN cat > /usr/local/bin/fragua-refresh-cli <<'EOF'
#!/bin/sh
# Install/update the Fragua + Claude Code CLIs into the persistent
# /fragua-data volume so updates need no image rebuild.
#   fragua-refresh-cli                 # force-update both to latest
#   fragua-refresh-cli --if-missing    # install only those absent (used by entrypoint)
#   fragua-refresh-cli claude|fragua   # restrict to one CLI
set -e
MODE=all; ONLY=""
for a in "$@"; do
  case "$a" in
    --if-missing) MODE=if-missing ;;
    claude|fragua) ONLY="$a" ;;
    *) echo "usage: fragua-refresh-cli [--if-missing] [claude|fragua]" >&2; exit 1 ;;
  esac
done
export NPM_CONFIG_PREFIX=/fragua-data/npm
mkdir -p /fragua-data/npm /fragua-data/bin

want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

if want claude; then
  if [ "$MODE" = all ] || ! [ -x /fragua-data/npm/bin/claude ]; then
    echo "==> installing Claude Code into /fragua-data/npm"
    npm install -g @anthropic-ai/claude-code
  fi
fi

if want fragua; then
  if [ "$MODE" = all ] || ! [ -x /fragua-data/bin/fragua ]; then
    echo "==> installing Fragua CLI into /fragua-data/bin"
    # install.sh has no install-dir override; it writes /usr/local/bin/fragua as
    # root, so run it then relocate the binary into the volume.
    curl -fsSL https://github.com/maquina-app/fragua-tools/releases/latest/download/install.sh | sh
    install -D -m 0755 "$(command -v fragua)" /fragua-data/bin/fragua
  fi
fi
echo "==> CLIs:"
command -v fragua && fragua --version 2>/dev/null || true
command -v claude && claude --version 2>/dev/null || true
EOF
RUN chmod +x /usr/local/bin/fragua-refresh-cli

# ── Entrypoint — load the Claude token + wire the runtime-toolchain volume ─────
# 1. Claude token: write it into the fragua-config volume once during setup and
#    the agent picks it up on every run — no env needed. An explicit
#    CLAUDE_CODE_OAUTH_TOKEN in the environment still wins if you'd rather pass it.
# 2. Toolchain redirect: point gem/npm installs at the rw /fragua-data volume so
#    runtime `gem install` / `bundle install` / `npm install -g` survive a
#    rebuild. This is set HERE (runtime), not as a build ENV — otherwise the
#    build-time installs above would target a path the empty volume later hides,
#    and `--refresh-cli` could not refresh them.
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
fragua-refresh-cli --if-missing || echo "warn: CLI bootstrap skipped (using image baseline)" >&2
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
