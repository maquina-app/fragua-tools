#!/usr/bin/env bash
#
# Build the Fragua agent image and (optionally) push it to GHCR.
# For Docker / OrbStack.
#
# The build is also tagged `local/fragua:latest` (LOCAL_TAG) — the name
# compose.yaml / fragua-host run — so a rebuild is immediately what they use.
# Multi-arch builds can't be loaded locally, so they push and then pull this
# host's variant back, leaving LOCAL_TAG on the fresh image either way.
#
# Usage:
#   ./build.sh                          # build + push  ghcr.io/maquina-app/fragua-docker:latest
#   ./build.sh --no-push                # build only, no registry push
#   ./build.sh --no-cache               # force a clean rebuild from scratch
#   ./build.sh --refresh-cli            # re-fetch the latest Claude Code + fragua CLI (skips cache for those layers)
#   ./build.sh --platform linux/amd64,linux/arm64
#                                       # multi-arch via buildx: pushes, then pulls
#                                       # this host's variant back for LOCAL_TAG
#
# Authentication for the push (only needed once per machine):
#   export GITHUB_USER=<your-github-username>
#   export GITHUB_TOKEN=<a PAT with `write:packages` scope>
#   ./build.sh
# If those vars are unset the script assumes you have already run `docker login ghcr.io`.

set -euo pipefail

# ── Configuration (override via env) ──────────────────────────────────────────
REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE="${IMAGE:-maquina-app/fragua-docker}"
TAG="${TAG:-latest}"
ENGINE="${ENGINE:-docker}"

REF="${REGISTRY}/${IMAGE}:${TAG}"

# Local builds are also tagged with the name compose.yaml / fragua-host run, so a
# rebuild is immediately what they use (no manual `docker tag`). Set empty to skip.
LOCAL_TAG="${LOCAL_TAG:-local/fragua:latest}"

# ── Parse args ────────────────────────────────────────────────────────────────
PUSH=1
NO_CACHE=""
PLATFORM=""
REFRESH_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push)        PUSH=0 ;;
    --no-cache)       NO_CACHE="--no-cache" ;;
    --refresh-cli)    REFRESH_ARG="--build-arg CLI_REFRESH=$(date +%s)" ;;
    --platform)       PLATFORM="$2"; shift ;;
    -h|--help)        sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# Always build from this script's directory (where the Dockerfile lives).
cd "$(dirname "$0")"

if ! command -v "$ENGINE" >/dev/null 2>&1; then
  echo "error: '$ENGINE' not found on PATH" >&2
  exit 1
fi

# ── Login (optional, only if credentials are provided) ────────────────────────
maybe_login() {
  if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_USER:-}" ]]; then
    echo "==> Logging in to ${REGISTRY} as ${GITHUB_USER}"
    echo "$GITHUB_TOKEN" | "$ENGINE" login "$REGISTRY" -u "$GITHUB_USER" --password-stdin
  fi
}

# ── Local tag sync (multi-arch path) ──────────────────────────────────────────
# buildx --push writes straight to the registry and never touches the local
# image store, so LOCAL_TAG would still point at whatever was there before. When
# the platform list includes this host, pull that variant back and retag it, so
# compose.yaml / fragua-host run what was just built instead of a stale image.
host_platform() {
  "$ENGINE" version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null
}

sync_local_tag_from_registry() {
  local host plat matched=0
  host="$(host_platform)"
  if [[ -z "$host" ]]; then
    echo "warn: could not detect the host platform; '${LOCAL_TAG}' left as-is." >&2
    echo "      pull ${REF} and retag it manually if you want to run it here." >&2
    return 0
  fi

  # Tolerate variants in either direction (linux/arm64 vs linux/arm64/v8).
  local plats; IFS=',' read -ra plats <<< "$PLATFORM"
  for plat in "${plats[@]}"; do
    plat="${plat// /}"
    if [[ "$plat" == "$host" || "$plat" == "$host"/* || "$host" == "$plat"/* ]]; then
      matched=1; break
    fi
  done

  if [[ "$matched" -eq 0 ]]; then
    echo "==> ${PLATFORM} doesn't include this host (${host}) — nothing to pull."
    echo "    '${LOCAL_TAG}' still points at the previous build."
    return 0
  fi

  echo "==> Pulling the ${host} variant of ${REF}"
  if ! "$ENGINE" pull --platform "$host" "$REF"; then
    echo "warn: pull failed; '${LOCAL_TAG}' left as-is." >&2
    return 0
  fi
  if [[ -n "$LOCAL_TAG" && "$LOCAL_TAG" != "$REF" ]]; then
    echo "==> Tagging ${REF} as ${LOCAL_TAG}"
    "$ENGINE" tag "$REF" "$LOCAL_TAG"
  fi
}

# ── Multi-arch path (buildx builds and pushes in one step) ────────────────────
if [[ -n "$PLATFORM" ]]; then
  if [[ "$PUSH" -eq 0 ]]; then
    echo "error: --platform requires pushing (buildx can't load multi-arch locally)" >&2
    echo "       drop --no-push, or use a single --platform value." >&2
    exit 1
  fi
  maybe_login
  echo "==> Building + pushing ${REF} for ${PLATFORM} via buildx"
  "$ENGINE" buildx build $NO_CACHE $REFRESH_ARG \
    --platform "$PLATFORM" \
    -t "$REF" \
    --push \
    .
  echo "==> Done: ${REF} (${PLATFORM})"
  sync_local_tag_from_registry
  exit 0
fi

# ── Single-arch path ──────────────────────────────────────────────────────────
echo "==> Building ${REF} with '${ENGINE}'"
"$ENGINE" build $NO_CACHE $REFRESH_ARG -t "$REF" .

# Point the local run name at this fresh build (compose.yaml / fragua-host use it).
if [[ -n "$LOCAL_TAG" && "$LOCAL_TAG" != "$REF" ]]; then
  echo "==> Tagging ${REF} as ${LOCAL_TAG}"
  "$ENGINE" tag "$REF" "$LOCAL_TAG"
fi

if [[ "$PUSH" -eq 0 ]]; then
  echo "==> Built ${REF} (push skipped)"
  exit 0
fi

maybe_login
echo "==> Pushing ${REF}"
"$ENGINE" push "$REF"

echo "==> Done: ${REF}"
echo "    First push lands as a PRIVATE package — set it public in"
echo "    github.com/orgs/maquina-app/packages if you want anonymous pulls."
