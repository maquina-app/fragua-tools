# Fragua on Docker / OrbStack — full setup guide

Run the [Fragua](https://fragua.app) agent in an isolated container on macOS
using **Docker** or **[OrbStack](https://orbstack.dev)**, with a complete Rails
stack and all native development libraries pre-installed.

**Why this setup:** maximum isolation + full stack. Agent runs — `bundle
install`, DB migrations, asset compilation, image processing, PDF generation —
all stay inside the `fragua-workdir` volume. All four volumes survive `docker
compose down` and image rebuilds, so there's no re-login and no lost work after
an update. Nothing in your Mac's `~/` is exposed to agent writes.

> OrbStack is recommended on Apple silicon (lighter, faster, better SSH-agent
> handling), but plain Docker Desktop works too.

> **Already running the older five-volume layout** (`fragua-gh`, `fragua-ssh`,
> `fragua-claude`)? **Back up first**, then migrate — see
> [Migrating from the five-volume layout](#migrating-from-the-five-volume-layout)
> at the end before you rebuild.

---

## Phase 1 — Install the runtime + host tools

### 1a. Install OrbStack (or Docker Desktop)

```bash
brew install orbstack          # recommended
# — or — download Docker Desktop from docker.com/products/docker-desktop
docker --version && docker info
```

### 1b. Install Claude Code on your Mac (the only host tool needed)

Because the agent runs **entirely inside the container**, the only tool you need
on the Mac — besides Docker/OrbStack — is **Claude Code**, used once to mint the
agent's token (`claude setup-token`, Phase 3b; it needs a browser). Everything
else (`git`, `gh`, `fragua`, Ruby/Node) lives in the image, and all sign-ins
happen inside the container in Phase 3.

```bash
npm install -g @anthropic-ai/claude-code   # or the native installer; skip if already installed
```

> No host `gh auth login` / `fragua login` / `claude login` — those are done
> inside the container, so nothing on your Mac is wired into the agent.

---

## Phase 2 — Get the image

### Option A — pull the published image (fastest)

```bash
# 1. (only if the package is private) authenticate to GHCR
#    use a PAT with `read:packages`
docker login ghcr.io -u <github-username>

# 2. pull the image
docker pull ghcr.io/maquina-app/fragua-docker:latest

# 3. tag it locally so the guide / compose.yaml `local/fragua:latest` works
docker tag ghcr.io/maquina-app/fragua-docker:latest local/fragua:latest

# 4. confirm it's present
docker image ls | grep fragua
```

> Pulling avoids the 10–15 min build — you get the exact published image. To
> pin a specific build instead of `latest`, replace the tag in steps 2–3.

### Option B — build it yourself

From this directory (contains the `Dockerfile`, `build.sh`, `compose.yaml`):

```bash
./build.sh --no-push                # builds ghcr.io/...:latest locally, no push
# or directly:
docker build -t local/fragua:latest .
```

The first build takes **~10–15 min** — the native-library layer is large.
Cached rebuilds are fast.

> If you built via `build.sh`, also tag it as `local/fragua:latest` (the name
> the guide and `compose.yaml` use):
> `docker tag ghcr.io/maquina-app/fragua-docker:latest local/fragua:latest`

---

## Phase 3 — Create volumes + one-time setup (host-independent)

This setup keeps **everything inside named volumes** — credentials, Git identity,
and a dedicated SSH key — so the running agent depends on **nothing** from your
Mac (no `~/.gitconfig` bind, no SSH-agent forwarding, no token env). The only
host action is generating the Claude token once (it needs a browser).

### 3a. Create the four named volumes

```bash
docker volume create fragua-config     # fragua token, git identity, claude token + state → /fragua-config
docker volume create fragua-secrets    # gh token + SSH keypair → /fragua-secrets (ro at runtime)
docker volume create fragua-workdir    # agent work             → /fragua-workdir (FRAGUA_WORKDIR)
docker volume create fragua-data       # runtime gems + node modules + bins → /fragua-data

# confirm all four exist before running the agent
docker volume ls | grep fragua
```

| Volume           | Mount path        | Runtime mode | Holds                                              |
| ---------------- | ----------------- | ------------ | -------------------------------------------------- |
| `fragua-config`  | `/fragua-config`  | `rw`         | fragua token + status/DB, `gitconfig` (`GIT_CONFIG_GLOBAL`), claude token + state (`CLAUDE_CONFIG_DIR=/fragua-config/claude`) |
| `fragua-secrets` | `/fragua-secrets` | `ro`*        | gh token (`GH_CONFIG_DIR=/fragua-secrets/gh`) + SSH keypair (`/root/.ssh` → `/fragua-secrets/ssh`) |
| `fragua-workdir` | `/fragua-workdir` | `rw`         | clones, `bundle install`, DBs, assets (`FRAGUA_WORKDIR`) |
| `fragua-data`    | `/fragua-data`    | `rw`         | runtime `gem install` / `bundle install` / `npm install -g` output (`GEM_HOME`, `NPM_CONFIG_PREFIX`) |

\* `fragua-secrets` is mounted **`rw` during the one-time setup below** (so you can
write the gh token + SSH key) and **`ro` for every normal run** — the agent uses
the credentials but can't overwrite them.

### 3b. Generate the Claude token on your Mac (one host step)

Claude Code's interactive `/login` uses a browser OAuth **redirect** that can't
complete in a headless container (you'd get `Invalid OAuth Request / Unknown
scope`). Generate a long-lived token on your Mac instead — you'll paste it into
the volume in the next step so the container never needs it from the host again:

```bash
# on the Mac — completes in your browser, prints a token
claude setup-token
```

Copy the printed token; you'll paste it inside the container below.

### 3c. One-time setup inside the container

Two steps — **Git identity** and the **SSH key** — let you choose:

- **Option A — reuse your existing host identity + key.** Copies them once into
  the volumes. Nothing new to register on GitHub. *Requires a passphrase-less
  private key* (a copied key can't prompt for a passphrase in the headless agent).
- **Option B — create a fresh identity + key for the container.** ⚠️ A new key
  and identity **must be registered on GitHub** (the steps below do this with
  `gh ssh-key add`), and commits will be attributed to the new name/email.

> **Recommendation:** if your existing key is **passphrase-protected**, use
> **Option B** rather than Option A. A copied passphrase key can't be unlocked in
> the headless agent, so the only way to make Option A work would be to strip its
> passphrase — leaving an unencrypted copy of your personal key in the volume.
> Option B gives the container its own dedicated, passphrase-less key you can
> revoke independently on GitHub, which is the safer posture for an autonomous
> agent anyway.

Start the setup shell. The two `host-*` mounts at the end are needed **only for
Option A** (to copy your files in) — omit them for Option B:

Mount `fragua-secrets` **`rw`** for setup (it's `ro` at runtime). The config-dir
env vars (`XDG_CONFIG_HOME`, `GH_CONFIG_DIR`, `CLAUDE_CONFIG_DIR`,
`GIT_CONFIG_GLOBAL`) are baked into the image, so they don't need `--env` here.
The two `host-*` mounts are needed **only for Option A** — omit them for Option B:

```bash
docker run --rm -it \
  -v fragua-config:/fragua-config:rw \
  -v fragua-secrets:/fragua-secrets:rw \
  -v ${HOME}/.ssh:/host-ssh:ro \              # Option A only
  -v ${HOME}/.gitconfig:/host-gitconfig:ro \  # Option A only
  local/fragua:latest bash

# ── inside the container ──────────────────────────────────────────────
# 0. Create the secret subdirs (the empty volume hides the image's baked dirs)
mkdir -p /fragua-secrets/gh /fragua-secrets/ssh && chmod 700 /fragua-secrets/ssh

# 1. GitHub CLI — device-code flow works headless (opens a code + URL).
#    --insecure-storage forces the token into GH_CONFIG_DIR=/fragua-secrets/gh on
#    the volume; without it gh may save to an in-VM keyring that doesn't persist.
gh auth login --insecure-storage

# 2. Git identity + SSH key — do EITHER Option A or Option B.
#    /root/.ssh is a symlink → /fragua-secrets/ssh, so keys land in the volume.

#   ── Option A · reuse host identity + key (copy once) ────────────────
cp /host-gitconfig /fragua-config/gitconfig
cp /host-ssh/id_ed25519 /host-ssh/id_ed25519.pub /root/.ssh/   # or id_rsa / id_ecdsa
chmod 600 /root/.ssh/id_*
ssh -o IdentitiesOnly=yes -i /root/.ssh/id_ed25519 -T git@github.com   # "Hi <you>!"

#   ── Option B · fresh identity + key (must register on GitHub) ───────
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "fragua-docker"
gh auth refresh -h github.com -s admin:public_key      # grant key-management scope
gh ssh-key add /root/.ssh/id_ed25519.pub --title "fragua-docker"   # ← registers it
ssh -o IdentitiesOnly=yes -i /root/.ssh/id_ed25519 -T git@github.com   # "Hi <you>!"

# 3. Claude token — write it into the config volume (the image's entrypoint
#    reads this file on every run, so no env is ever needed)
printf '%s' 'PASTE_THE_setup-token_VALUE' > /fragua-config/claude-oauth-token
chmod 600 /fragua-config/claude-oauth-token
export CLAUDE_CODE_OAUTH_TOKEN="$(cat /fragua-config/claude-oauth-token)"
claude -p "reply with the single word: ok"             # confirms the token works

# 4. Fragua
fragua login                               # paste your AgentToken from fragua.app → Settings
fragua doctor
exit
```

> **⚠️ Option B = new GitHub identity.** Pushes use a brand-new SSH key, so it
> must be on your account (`gh ssh-key add`, or GitHub → Settings → SSH keys),
> and commits are attributed to the name/email you set — not your usual host
> identity. Option A avoids both, since it reuses what's already on your account.

> Everything now lives in volumes: the `fragua`/`git`/`claude` tokens in
> `fragua-config`, and the `gh` token + SSH key together in `fragua-secrets`. The
> image trusts GitHub's host key via baked-in `known_hosts`, so `git@github.com`
> never prompts.

> **Tip — git over HTTPS instead of SSH:** if your repos use `https://github.com`
> remotes, skip the SSH key entirely and run `gh auth setup-git` in step 1 to
> have `gh` act as git's credential helper. Use the SSH key for `git@github.com:`
> remotes.

---

## Phase 4 — Run the agent

### 4a. Mount table

Every mount is an **internal named volume** — there are **no host paths** and no
SSH-agent forwarding. The running agent is fully decoupled from your Mac.

| Source                       | Destination       | Mode             |
| ---------------------------- | ----------------- | ---------------- |
| `fragua-config` (named vol)  | `/fragua-config`  | `rw` (internal)  |
| `fragua-secrets` (named vol) | `/fragua-secrets` | `ro`             |
| `fragua-workdir` (named vol) | `/fragua-workdir` | `rw` (internal)  |
| `fragua-data` (named vol)    | `/fragua-data`    | `rw` (internal)  |

#### Why these mounts — and what's writable

- **`fragua-config` → `rw` (internal)** — the fragua agent writes its status and
  a local DB here, so it must be writable. It also holds the Git identity
  (`gitconfig`), the Claude token file (read by the entrypoint — no env needed),
  and Claude Code's session/project state (`/fragua-config/claude`). Internal
  named volume, so writes never reach your Mac.
- **`fragua-secrets` → `ro`** — the GitHub CLI token and the SSH key, together.
  Read-only at runtime: the agent uses them but can't rewrite or corrupt them.
  (It was `rw` during setup *only* so you could write them.)
- **`fragua-workdir` → `rw` (internal)** — all agent output (`git clone`,
  `bundle install`, DB files, compiled assets) lands here.
- **`fragua-data` → `rw` (internal)** — runtime-installed gems + global node
  modules + their bins, so a `gem install` / `bundle install` / `npm install -g`
  the agent runs survives a rebuild instead of being re-fetched each time.

> **Key takeaway:** there are no host mounts at all. Every writable target is an
> **internal named volume**, so writes never reach your Mac. The GitHub token and
> SSH key stay read-only.

### 4b. Start with Docker Compose (recommended)

The repo ships a ready-to-use [`compose.yaml`](./compose.yaml) — it mounts only
the four volumes (no host paths, no env), since the config-dir vars are baked
into the image and the entrypoint loads the Claude token from the volume. From
this directory:

```bash
docker compose up -d
docker compose logs --follow
docker compose exec fragua-agent fragua status
```

Check **fragua.app → Agents** — the machine appears online within seconds.
A workspace's own `.mise.toml` overrides the global Ruby/Node version when the
agent enters that directory.

> Prefer a one-off `docker run`? The equivalent of the Compose file (note
> `fragua-secrets` is `:ro`):
>
> ```bash
> docker run -d --name fragua-agent --restart unless-stopped \
>   -v fragua-config:/fragua-config:rw \
>   -v fragua-secrets:/fragua-secrets:ro \
>   -v fragua-workdir:/fragua-workdir:rw \
>   -v fragua-data:/fragua-data:rw \
>   local/fragua:latest
> ```

---

## Lifecycle

```bash
# rebuild — all volumes survive, no re-setup needed
docker compose exec fragua-agent fragua prune --yes
docker compose down
docker build --no-cache -t local/fragua:latest .
docker compose up -d

# just update the CLIs (Claude Code + fragua) without a full rebuild:
./build.sh --refresh-cli    # or: docker build --build-arg CLI_REFRESH=$(date +%s) -t local/fragua:latest .

# inspect the workdir without touching the running agent
docker run --rm -v fragua-workdir:/data:ro alpine ls -la /data

# drop just the runtime gem/node cache (forces a clean re-install, keeps creds)
docker volume rm fragua-data && docker volume create fragua-data

# nuclear — wipes all work + every credential (forces full re-setup, incl. SSH key)
docker compose down
docker volume rm fragua-workdir fragua-config fragua-secrets fragua-data
```

> No host coupling means **no re-create after a Mac reboot** — the agent doesn't
> depend on the SSH agent socket anymore.

---

## Troubleshooting

- **`mise: not found` while building** — the image installs mise into
  `/usr/local/mise/bin` (on `PATH`); if you've modified the Dockerfile, keep
  `MISE_INSTALL_PATH=/usr/local/mise/bin/mise` on the install line.
- **`git` push fails "Permission denied (publickey)"** — the SSH key in
  `fragua-secrets` isn't registered on GitHub. With **Option B** run `gh ssh-key add`
  (Phase 3c); with **Option A** make sure you copied a key already on your
  account. Test with `ssh -i /root/.ssh/id_ed25519 -T git@github.com`.
- **SSH key asks for a passphrase / hangs** — a copied **Option A** key has a
  passphrase, which can't be entered headless. Use a passphrase-less key, or
  switch to **Option B** (a fresh key with `-N ""`).
- **`git@github.com` push fails "Host key verification failed"** — the image
  seeds `known_hosts` at build time; if you stripped that line, re-add the
  `ssh-keyscan github.com` step or pass `-o StrictHostKeyChecking=accept-new`.
- **`claude` `/login` fails with "Invalid OAuth Request / Unknown scope"** — the
  browser redirect flow can't complete in a headless container. Use
  `claude setup-token` on your Mac and write the result to
  `/fragua-config/claude-oauth-token` (Phase 3b–3c).
- **`claude -p` says "not logged in" at runtime** — the token file is missing or
  empty. Check `/fragua-config/claude-oauth-token` exists in the `fragua-config`
  volume; the image's entrypoint reads it on every run.
- **`gh` says "not logged in" at runtime** — the `fragua-secrets` volume isn't
  mounted or is empty. Re-run the Phase 3c `gh auth login --insecure-storage`.
- **`gh` asks you to authenticate on every run / the token never persists** — `gh`
  saved it to an in-VM keyring instead of the volume, or the image is stale. Fix:
  (1) confirm `echo $GH_CONFIG_DIR` prints `/fragua-secrets/gh` — an old image
  prints `/fragua-gh`, which isn't mounted, so the token is discarded on exit;
  rebuild + re-tag `local/fragua:latest` if so. (2) Re-run
  `gh auth login --insecure-storage` and check the token landed with
  `grep -c oauth_token /fragua-secrets/gh/hosts.yml` (expect > 0).
- **`gh`/`git` can't write at runtime ("read-only file system")** — expected:
  `fragua-secrets` is `ro` at runtime by design. To rotate the token or key,
  re-run the Phase 3c setup shell (which mounts it `:rw`).
- **Runtime `gem install` / `npm i -g` vanished after a rebuild** — confirm the
  `fragua-data` volume is mounted (Phase 4). Without it, those installs live in the
  container's writable layer and are discarded on `down`/`rm`.
- **Agent doesn't appear online** — confirm `fragua login` succeeded inside the
  container (Phase 3c) and that the `fragua-config` volume is mounted in Phase 4.
- **`linux/amd64` host can't run an arm64 image** — publish a multi-arch image
  with `./build.sh --platform linux/amd64,linux/arm64`.

---

## Migrating from the five-volume layout

Older images used five volumes — `fragua-config`, `fragua-gh`, `fragua-ssh`,
`fragua-claude`, `fragua-workdir`. The current image uses four: `fragua-config`
(now also holds Claude state under `claude/`), `fragua-secrets` (gh + ssh, `ro` at
runtime), `fragua-workdir`, and the new `fragua-data`. Migrate in three steps.

### 1. Back up every existing volume to the host

Mount all five old volumes read-only plus the current host directory, and tar each
one out. Tarballs land in `./fragua-backup/` on your Mac.

```bash
docker run --rm -it \
  -v fragua-config:/v/config:ro \
  -v fragua-gh:/v/gh:ro \
  -v fragua-ssh:/v/ssh:ro \
  -v fragua-claude:/v/claude:ro \
  -v fragua-workdir:/v/workdir:ro \
  -v "$PWD":/backup:rw \
  local/fragua:latest bash -c '
    mkdir -p /backup/fragua-backup
    for v in config gh ssh claude workdir; do
      tar czf /backup/fragua-backup/$v.tgz -C /v/$v . ;
    done
    ls -la /backup/fragua-backup'
```

Confirm `config.tgz`, `gh.tgz`, `ssh.tgz`, `claude.tgz` exist and are non-empty
before continuing. (`workdir.tgz` may be large; the agent re-clones, so it's
optional to keep.)

### 2. Build the new image + create the new volumes

```bash
./build.sh --no-push                       # or: docker build -t local/fragua:latest .
docker volume create fragua-config
docker volume create fragua-secrets
docker volume create fragua-workdir
docker volume create fragua-data
```

> If you'd rather start the new `fragua-config` clean, skip the restore below and
> just re-run the Phase 3c setup. The restore only saves you re-doing the logins.

### 3. Restore the backup into the new layout

`gh` and `claude` move into subdirectories; everything else keeps its place.

```bash
docker run --rm -it \
  -v fragua-config:/fragua-config:rw \
  -v fragua-secrets:/fragua-secrets:rw \
  -v "$PWD/fragua-backup":/backup:ro \
  local/fragua:latest bash -c '
    tar xzf /backup/config.tgz -C /fragua-config
    mkdir -p /fragua-config/claude /fragua-secrets/gh /fragua-secrets/ssh
    tar xzf /backup/claude.tgz -C /fragua-config/claude
    tar xzf /backup/gh.tgz     -C /fragua-secrets/gh
    tar xzf /backup/ssh.tgz    -C /fragua-secrets/ssh
    chmod 700 /fragua-secrets/ssh
    chmod 600 /fragua-secrets/ssh/id_* 2>/dev/null || true'
```

Then start the agent normally (Phase 4b). `fragua-data` stays empty — gems and node
modules re-install on first use and persist from then on.

> If `gh` reports "not authenticated" after the restore, the backed-up `hosts.yml`
> was written by an older `gh` schema. Just re-run the login in a `--bash` session:
> `gh auth login --insecure-storage`. The SSH key restore is schema-agnostic and
> needs no redo.

Once the agent is online and `git push` works, you can delete the old volumes:

```bash
docker volume rm fragua-gh fragua-ssh fragua-claude
```
