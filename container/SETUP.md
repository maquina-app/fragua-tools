# Fragua on Apple Container — full setup guide

Run the [Fragua](https://fragua.app) agent in a fully isolated VM on macOS using
[Apple Container](https://github.com/apple/container), with a complete Rails
stack and all native development libraries pre-installed.

**Why this setup:** maximum isolation + full stack. Agent runs — `bundle install`,
DB migrations, asset compilation — all stay inside the `fragua-workdir` volume.
All four volumes survive image rebuilds, so there's no re-login and no lost work
after an update. Nothing in your Mac's `~/` is exposed to agent writes.

> Requires Apple silicon (M-series) and macOS 15 or later.

> **Already running the older five-volume layout** (`fragua-gh`, `fragua-ssh`,
> `fragua-claude`)? **Back up first**, then migrate — see
> [Migrating from the five-volume layout](#migrating-from-the-five-volume-layout)
> at the end before you rebuild.

---

## Phase 1 — Install Apple Container + start the runtime

### 1a. Install the Apple Container CLI

```bash
open https://github.com/apple/container/releases/latest
# download the .pkg → double-click → enter admin password
container --version
```

### 1b. Start the container system (installs the VM kernel)

Apple Container runs each container in a lightweight VM, which needs a Linux
kernel. The **first** `container system start` downloads and installs a
recommended default kernel — answer `Y` at the prompt:

```bash
container system start
```

```
Launching container-apiserver...
Testing access to container-apiserver...
Verifying machine API server is running...
No default kernel configured.
Install the recommended default kernel from
[https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst]? [Y/n]: Y
Installing kernel...
```

> This prompt only appears the first time. If you script the setup or run
> headless, pre-install the kernel non-interactively:
>
> ```bash
> container system kernel set --recommended
> container system start
> ```

Verify the runtime is up:

```bash
container system status
```

### 1c. Install Claude Code on your Mac (the only host tool needed)

Because the agent runs **entirely inside the container**, the only tool you need
on the Mac — besides the `container` CLI — is **Claude Code**, used once to mint
the agent's token (`claude setup-token`, Phase 3b; it needs a browser).
Everything else (`git`, `gh`, `fragua`, Ruby/Node) lives in the image, and all
sign-ins happen inside the container in Phase 3.

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
container registry login ghcr.io -u <github-username>

# 2. pull the image
container image pull ghcr.io/maquina-app/fragua-container:latest

# 3. tag it locally so the rest of the guide's `local/fragua:latest` works
container image tag ghcr.io/maquina-app/fragua-container:latest local/fragua:latest

# 4. confirm it's present
container image list | grep fragua
```

> Pulling avoids the 10–15 min build — you get the exact published image. To
> pin a specific build instead of `latest`, replace the tag in steps 2–3.

### Option B — build it yourself

From this directory (contains the `Dockerfile` and `build.sh`):

```bash
./build.sh --no-push                       # builds local/... via build.sh, no registry push
# or directly:
container build -t local/fragua:latest .
```

The first build takes **~10–15 min** — the native-library layer is large.
Cached rebuilds are fast.

---

## Phase 3 — Create volumes + one-time setup (host-independent)

This setup keeps **everything inside named volumes** — credentials, Git identity,
and a dedicated SSH key — so the running agent depends on **nothing** from your
Mac (no `--ssh`, no `~/.gitconfig` bind, no `--env` token). The only host action
is generating the Claude token once (it needs a browser).

### 3a. Create the four named volumes

```bash
container volume create fragua-config     # fragua token, git identity, claude token + state → /fragua-config
container volume create fragua-secrets    # gh token + SSH keypair → /fragua-secrets (ro at runtime)
container volume create fragua-workdir    # agent work             → /fragua-workdir (FRAGUA_WORKDIR)
container volume create fragua-data       # runtime gems + node modules + bins → /fragua-data

# confirm all four exist before running the agent
container volume list
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
  private key* (a copied key can't prompt for a passphrase in the headless
  agent).
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
container run --rm -it \
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
#    the volume; without it gh may save to an in-VM keyring that doesn't persist
#    (this image ships dbus, so gh otherwise prefers the keyring).
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
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "fragua-container"
gh auth refresh -h github.com -s admin:public_key      # grant key-management scope
gh ssh-key add /root/.ssh/id_ed25519.pub --title "fragua-container"   # ← registers it
ssh -o IdentitiesOnly=yes -i /root/.ssh/id_ed25519 -T git@github.com   # "Hi <you>!"

# 3. Claude token — write it into the config volume (the image's entrypoint
#    reads this file on every run, so no --env is ever needed)
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
`--ssh`. The running agent is fully decoupled from your Mac.

| Source                       | Destination       | Mode             |
| ---------------------------- | ----------------- | ---------------- |
| `fragua-config` (named vol)  | `/fragua-config`  | `rw` (internal)  |
| `fragua-secrets` (named vol) | `/fragua-secrets` | `ro`             |
| `fragua-workdir` (named vol) | `/fragua-workdir` | `rw` (internal)  |
| `fragua-data` (named vol)    | `/fragua-data`    | `rw` (internal)  |

#### Why these mounts — and what's writable

- **`fragua-config` → `rw` (internal)** — the fragua agent writes its status and
  a local DB here, so it must be writable. It also holds the Git identity
  (`gitconfig`), the Claude token file (read by the entrypoint — no `--env`
  needed), and Claude Code's session/project state (`/fragua-config/claude`).
  Internal named volume, so writes never reach your Mac.
- **`fragua-secrets` → `ro`** — the GitHub CLI token and the SSH key, together.
  Read-only at runtime: the agent uses them but can't rewrite or corrupt them.
  (It was `rw` during setup *only* so you could write them.)
- **`fragua-workdir` → `rw` (internal)** — all agent output (`git clone`,
  `bundle install`, DB files, compiled assets) lands here.
- **`fragua-data` → `rw` (internal)** — runtime-installed gems + global node
  modules + their bins, so a `gem install` / `bundle install` / `npm install -g`
  the agent runs survives a rebuild instead of being re-fetched each time.

> **Key takeaway:** there are no host mounts at all. Every writable target is an
> **internal named volume** — the agent's config/state, toolchain cache, and
> working tree — so writes never reach your Mac. The GitHub token and SSH key stay
> read-only.

### 4b. Start the container

```bash
container run \
  --name fragua-agent \
  --detach \
  -v fragua-config:/fragua-config:rw \
  -v fragua-secrets:/fragua-secrets:ro \
  -v fragua-workdir:/fragua-workdir:rw \
  -v fragua-data:/fragua-data:rw \
  local/fragua:latest
```

> The config-dir env vars (`XDG_CONFIG_HOME`, `GH_CONFIG_DIR`,
> `CLAUDE_CONFIG_DIR`, `GIT_CONFIG_GLOBAL`) are baked into the image, and the
> entrypoint loads the Claude token from the volume — so the run line needs only
> the volume mounts. No host shell state required.

Check **fragua.app → Agents** — the machine appears online within seconds.
Project `.mise.toml` files override the global Ruby/Node version automatically.

---

## Lifecycle

```bash
# follow logs / inspect the workdir
container logs --follow fragua-agent
container exec -it fragua-agent bash      # inspect workdir, run rails cmds

# rebuild — all volumes survive
container exec fragua-agent fragua prune --yes
container stop fragua-agent && container rm fragua-agent
container build --no-cache -t local/fragua:latest .
# re-run 4b — no re-login, workdir + gem/node cache preserved

# just update the CLIs (Claude Code + fragua) without a full rebuild:
./build.sh --refresh-cli    # or: container build --build-arg CLI_REFRESH=$(date +%s) -t local/fragua:latest .

# drop just the runtime gem/node cache (forces a clean re-install, keeps creds)
container volume delete fragua-data && container volume create fragua-data

# nuclear — wipe everything (forces full re-setup, incl. a new SSH key)
container rm -f fragua-agent
container volume delete fragua-workdir fragua-config fragua-secrets fragua-data
```

---

## Troubleshooting

- **`container system start` hangs on "Verifying machine API server"** — the
  kernel isn't installed. Re-run and accept the kernel prompt (`Y`), or run
  `container system kernel set --recommended` first (see Phase 1b).
- **`mise: not found` while building** — the image installs mise into
  `/usr/local/mise/bin` (on `PATH`); if you've modified the Dockerfile, keep
  `MISE_INSTALL_PATH=/usr/local/mise/bin/mise` on the install line.
- **Agent doesn't appear online** — confirm `fragua login` succeeded inside the
  container (Phase 3c) and that the `fragua-config` volume is mounted in 4b.
- **`claude` `/login` fails with "Invalid OAuth Request / Unknown scope"** — the
  browser redirect flow can't complete in a headless container. Don't use
  `/login`; run `claude setup-token` on your **Mac** and write the result to
  `/fragua-config/claude-oauth-token` (Phase 3b–3c).
- **`claude -p` says "not logged in" at runtime** — the token file is missing or
  empty. Check `/fragua-config/claude-oauth-token` exists in the `fragua-config`
  volume; the image's entrypoint reads it on every run. (An explicit
  `--env CLAUDE_CODE_OAUTH_TOKEN` overrides the file if you prefer.)
- **`gh` says "not logged in" at runtime** — the `fragua-secrets` volume isn't
  mounted, or it's empty. Re-run the Phase 3c `gh auth login --insecure-storage`.
- **`gh` asks you to authenticate on every run / the token never persists** — this
  image ships `dbus`, so plain `gh auth login` saves the token to an in-VM keyring
  that isn't on the volume. Fix: (1) confirm `echo $GH_CONFIG_DIR` prints
  `/fragua-secrets/gh` — an old image prints `/fragua-gh`, which isn't mounted, so
  the token is discarded on exit; rebuild + re-tag `local/fragua:latest` if so.
  (2) Re-run `gh auth login --insecure-storage` and verify with
  `grep -c oauth_token /fragua-secrets/gh/hosts.yml` (expect > 0).
- **`gh`/`git` can't write at runtime ("read-only file system")** — expected:
  `fragua-secrets` is `ro` at runtime by design. To rotate the token or key,
  re-run the Phase 3c setup shell (which mounts it `:rw`).
- **Runtime `gem install` / `npm i -g` vanished after a rebuild** — confirm the
  `fragua-data` volume is mounted (Phase 4b). Without it, those installs live in
  the container's writable layer and are discarded on `rm`.
- **`git@github.com` push fails "Host key verification failed"** — the image
  seeds `known_hosts` at build time; if you stripped that line, re-add the
  `ssh-keyscan github.com` step or pass `-o StrictHostKeyChecking=accept-new`.
- **`git` push fails "Permission denied (publickey)"** — the SSH key in
  `fragua-secrets` isn't registered on GitHub. With **Option B** run `gh ssh-key add`
  (Phase 3c); with **Option A** make sure you copied a key that's already on your
  account. Test with `ssh -i /root/.ssh/id_ed25519 -T git@github.com`.
- **SSH key asks for a passphrase / hangs** — a copied **Option A** key has a
  passphrase, which can't be entered in the headless agent. Use a passphrase-less
  key, or switch to **Option B** (a fresh key with `-N ""`).
- **`linux/amd64` host can't run the image** — images built on Apple silicon are
  `linux/arm64`; build/publish a matching arch for x86 hosts.

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
container run --rm -it \
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
./build.sh --no-push                       # or: container build -t local/fragua:latest .
container volume create fragua-config
container volume create fragua-secrets
container volume create fragua-workdir
container volume create fragua-data
```

> If you'd rather start the new `fragua-config` clean, skip the restore below and
> just re-run the Phase 3c setup. The restore only saves you re-doing the logins.

### 3. Restore the backup into the new layout

`gh` and `claude` move into subdirectories; everything else keeps its place.

```bash
container run --rm -it \
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
> was written by an older `gh` schema (and this image prefers a keyring anyway).
> Just re-run the login in a `--bash` session: `gh auth login --insecure-storage`.
> The SSH key restore is schema-agnostic and needs no redo.

Once the agent is online and `git push` works, you can delete the old volumes:

```bash
container volume delete fragua-gh fragua-ssh fragua-claude
```
