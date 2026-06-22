# Fragua on Docker / OrbStack — full setup guide

Run the [Fragua](https://fragua.app) agent in an isolated container on macOS
using **Docker** or **[OrbStack](https://orbstack.dev)**, with a complete Rails
stack and all native development libraries pre-installed.

**Why this setup:** maximum isolation + full stack. Agent runs — `bundle
install`, DB migrations, asset compilation, image processing, PDF generation —
all stay inside the `fragua-workdir` volume. Both volumes survive `docker
compose down` and image rebuilds, so there's no re-login and no lost work after
an update. Nothing in your Mac's `~/` is exposed to agent writes.

> OrbStack is recommended on Apple silicon (lighter, faster, better SSH-agent
> handling), but plain Docker Desktop works too.

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

### 3a. Create the five named volumes

```bash
docker volume create fragua-config    # fragua token, git identity, claude token → /fragua-config
docker volume create fragua-gh         # gh token        → /fragua-gh   (GH_CONFIG_DIR)
docker volume create fragua-claude     # claude state    → /fragua-claude (CLAUDE_CONFIG_DIR)
docker volume create fragua-ssh        # SSH keypair     → /root/.ssh
docker volume create fragua-workdir    # agent work      → /fragua-workdir (FRAGUA_WORKDIR)

# confirm all five exist before running the agent
docker volume ls | grep fragua
```

| Volume           | Mount path        | Runtime mode | Holds                                              |
| ---------------- | ----------------- | ------------ | -------------------------------------------------- |
| `fragua-config`  | `/fragua-config`  | `rw`         | fragua token + status/DB, `gitconfig`, claude token (`XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL`) |
| `fragua-gh`      | `/fragua-gh`      | `ro`         | GitHub CLI token (`GH_CONFIG_DIR`)                 |
| `fragua-ssh`     | `/root/.ssh`      | `ro`         | the container's own SSH keypair                    |
| `fragua-claude`  | `/fragua-claude`  | `rw`         | Claude Code session state (`CLAUDE_CONFIG_DIR`)    |
| `fragua-workdir` | `/fragua-workdir` | `rw`         | clones, `bundle install`, DBs, assets (`FRAGUA_WORKDIR`) |

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

```bash
docker run --rm -it \
  --env XDG_CONFIG_HOME=/fragua-config \
  --env GH_CONFIG_DIR=/fragua-gh \
  --env CLAUDE_CONFIG_DIR=/fragua-claude \
  --env GIT_CONFIG_GLOBAL=/fragua-config/gitconfig \
  -v fragua-config:/fragua-config:rw \
  -v fragua-gh:/fragua-gh:rw \
  -v fragua-claude:/fragua-claude:rw \
  -v fragua-ssh:/root/.ssh:rw \
  -v ${HOME}/.ssh:/host-ssh:ro \              # Option A only
  -v ${HOME}/.gitconfig:/host-gitconfig:ro \  # Option A only
  local/fragua:latest bash

# ── inside the container ──────────────────────────────────────────────
# 1. GitHub CLI — device-code flow works headless (opens a code + URL)
gh auth login

# 2. Git identity + SSH key — do EITHER Option A or Option B:

#   ── Option A · reuse host identity + key (copy once) ────────────────
cp /host-gitconfig /fragua-config/gitconfig
chmod 700 /root/.ssh
cp /host-ssh/id_ed25519 /host-ssh/id_ed25519.pub /root/.ssh/   # or id_rsa / id_ecdsa
chmod 600 /root/.ssh/id_*
ssh -o IdentitiesOnly=yes -i /root/.ssh/id_ed25519 -T git@github.com   # "Hi <you>!"

#   ── Option B · fresh identity + key (must register on GitHub) ───────
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
chmod 700 /root/.ssh
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

> Everything now lives in volumes: `gh`/`fragua`/`git`/`claude` tokens in
> `fragua-config`+`fragua-gh`, the SSH key in `fragua-ssh`. The image trusts
> GitHub's host key via baked-in `known_hosts`, so `git@github.com` never prompts.

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
| `fragua-gh` (named vol)      | `/fragua-gh`      | `ro`             |
| `fragua-ssh` (named vol)     | `/root/.ssh`      | `ro`             |
| `fragua-claude` (named vol)  | `/fragua-claude`  | `rw` (internal)  |
| `fragua-workdir` (named vol) | `/fragua-workdir` | `rw` (internal)  |

#### Why these mounts — and what's writable

- **`fragua-config` → `rw` (internal)** — the fragua agent writes its status and
  a local DB here at runtime, so it must be writable. It also holds the Git
  identity (`gitconfig`) and the Claude token file (read by the entrypoint — no
  env needed). It's an internal named volume, so writes never reach your Mac.
- **`fragua-gh` / `fragua-ssh` → `ro`** — the GitHub CLI token and the SSH key.
  Read-only at runtime: the agent uses them but can't rewrite or corrupt them.
  (They were `rw` during setup *only* so you could write them.)
- **`fragua-claude` → `rw` (internal)** — Claude Code writes session history and
  per-project state on every run, so this one must be writable.
- **`fragua-workdir` → `rw` (internal)** — all agent output (`git clone`,
  `bundle install`, DB files, compiled assets) lands here.

> **Key takeaway:** there are no host mounts at all. Every writable target is an
> **internal named volume**, so writes never reach your Mac. The GitHub token and
> SSH key stay read-only.

### 4b. Start with Docker Compose (recommended)

The repo ships a ready-to-use [`compose.yaml`](./compose.yaml) — it mounts only
the five volumes (no host paths, no env), since the config-dir vars are baked
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

> Prefer a one-off `docker run`? The equivalent of the Compose file:
>
> ```bash
> docker run -d --name fragua-agent --restart unless-stopped \
>   -v fragua-config:/fragua-config:rw \
>   -v fragua-gh:/fragua-gh:ro \
>   -v fragua-ssh:/root/.ssh:ro \
>   -v fragua-claude:/fragua-claude:rw \
>   -v fragua-workdir:/fragua-workdir:rw \
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

# inspect the workdir without touching the running agent
docker run --rm -v fragua-workdir:/data:ro alpine ls -la /data

# nuclear — wipes all work + every credential (forces full re-setup, incl. SSH key)
docker compose down
docker volume rm fragua-workdir fragua-config fragua-gh fragua-claude fragua-ssh
```

> No host coupling means **no re-create after a Mac reboot** — the agent doesn't
> depend on the SSH agent socket anymore.

---

## Troubleshooting

- **`mise: not found` while building** — the image installs mise into
  `/usr/local/mise/bin` (on `PATH`); if you've modified the Dockerfile, keep
  `MISE_INSTALL_PATH=/usr/local/mise/bin/mise` on the install line.
- **`git` push fails "Permission denied (publickey)"** — the SSH key in
  `fragua-ssh` isn't registered on GitHub. With **Option B** run `gh ssh-key add`
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
- **`gh` says "not logged in" at runtime** — the `fragua-gh` volume isn't mounted
  or is empty. Re-run the Phase 3c `gh auth login`.
- **Agent doesn't appear online** — confirm `fragua login` succeeded inside the
  container (Phase 3c) and that the `fragua-config` volume is mounted in Phase 4.
- **`linux/amd64` host can't run an arm64 image** — publish a multi-arch image
  with `./build.sh --platform linux/amd64,linux/arm64`.
