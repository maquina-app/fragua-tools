FROM ubuntu:24.04

LABEL org.opencontainers.image.source=https://github.com/maquina-app/fragua-tools
LABEL org.opencontainers.image.description="Fragua agent runtime — full Rails stack with all native development libraries, for Apple Container / Docker"
LABEL org.opencontainers.image.licenses=MIT

ENV container=container
ENV DEBIAN_FRONTEND=noninteractive
ENV XDG_CONFIG_HOME=/fragua-config
ENV FRAGUA_WORKDIR=/fragua-workdir
# Per-tool config dirs → each persisted in its own named volume.
# gh and claude store tokens in plaintext files on Linux, so a volume keeps them.
ENV GH_CONFIG_DIR=/fragua-gh
ENV GH_NO_UPDATE_NOTIFIER=1
ENV CLAUDE_CONFIG_DIR=/fragua-claude
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
#   container build --build-arg CLI_REFRESH=$(date +%s) ...
ARG CLI_REFRESH=0

RUN echo "cli refresh=${CLI_REFRESH}" \
    && npm install -g @anthropic-ai/claude-code

RUN curl -fsSL \
    https://github.com/maquina-app/fragua-tools/releases/latest/download/install.sh | sh

RUN mkdir -p /fragua-config /fragua-gh /fragua-claude /fragua-workdir /root/.ssh \
    && chmod 700 /root/.ssh

# ── Entrypoint — load the Claude token from the config volume if present ───────
# Set CLAUDE_CODE_OAUTH_TOKEN once (write it into the fragua-config volume during
# setup) and the agent picks it up on every run — no --env needed. An explicit
# --env CLAUDE_CODE_OAUTH_TOKEN still wins if you'd rather pass it at runtime.
RUN cat > /usr/local/bin/fragua-entrypoint.sh <<'EOF'
#!/bin/sh
set -e
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r /fragua-config/claude-oauth-token ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(cat /fragua-config/claude-oauth-token)"
  export CLAUDE_CODE_OAUTH_TOKEN
fi
exec "$@"
EOF
RUN chmod +x /usr/local/bin/fragua-entrypoint.sh

# Also export the token for login shells (e.g. `exec ... bash -l`), so the token
# is present even when the entrypoint is bypassed.
RUN cat > /etc/profile.d/fragua-claude-token.sh <<'EOF'
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -r /fragua-config/claude-oauth-token ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(cat /fragua-config/claude-oauth-token)"
fi
EOF

# ...and for non-login interactive bash (e.g. `exec ... bash`).
RUN echo '[ -r /fragua-config/claude-oauth-token ] && export CLAUDE_CODE_OAUTH_TOKEN="$(cat /fragua-config/claude-oauth-token)"' >> /etc/bash.bashrc

ENTRYPOINT ["/usr/local/bin/fragua-entrypoint.sh"]
CMD ["fragua", "agent", "--workdir", "/fragua-workdir"]
