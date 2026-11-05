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
#   ./build.sh --skip-smoke             # don't run smoke-test.sh first
#
# Pushing `latest` also pushes a dated tag (e.g. :20261104-1530) to roll back to.
# `latest` only moves once smoke-test.sh passes on this host's variant.
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

# Immutable tag for rollback. A custom TAG is already explicit, so it gets none.
DATED_REF=""
if [[ "$TAG" == "latest" ]]; then
  DATED_REF="${REGISTRY}/${IMAGE}:$(date -u +%Y%m%d-%H%M)"
fi

# Local builds are also tagged with the name compose.yaml / fragua-host run, so a
# rebuild is immediately what they use (no manual `docker tag`). Set empty to skip.
LOCAL_TAG="${LOCAL_TAG:-local/fragua:latest}"

# ── Parse args ────────────────────────────────────────────────────────────────
PUSH=1
NO_CACHE=""
PLATFORM=""
REFRESH_ARG=""
SMOKE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push)        PUSH=0 ;;
    --no-cache)       NO_CACHE="--no-cache" ;;
    --refresh-cli)    REFRESH_ARG="--build-arg CLI_REFRESH=$(date +%s)" ;;
    --platform)       PLATFORM="$2"; shift ;;
    --skip-smoke)     SMOKE=0 ;;
    -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
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
smoke_test() { # image
  if [[ "$SMOKE" -eq 1 ]]; then
    ENGINE="$ENGINE" ./smoke-test.sh "$1"
  fi
}

host_platform() {
  "$ENGINE" version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null
}

sync_local_tag_from_registry() { # ref — returns 1 if this host's variant was not pulled
  local ref="$1" host plat matched=0
  host="$(host_platform)"
  if [[ -z "$host" ]]; then
    echo "warn: could not detect the host platform; '${LOCAL_TAG}' left as-is." >&2
    echo "      pull ${ref} and retag it manually if you want to run it here." >&2
    return 1
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
    return 1
  fi

  echo "==> Pulling the ${host} variant of ${ref}"
  if ! "$ENGINE" pull --platform "$host" "$ref"; then
    echo "warn: pull failed; '${LOCAL_TAG}' left as-is." >&2
    return 1
  fi
  if [[ -n "$LOCAL_TAG" && "$LOCAL_TAG" != "$ref" ]]; then
    echo "==> Tagging ${ref} as ${LOCAL_TAG}"
    "$ENGINE" tag "$ref" "$LOCAL_TAG"
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
  # Push under the dated tag first, so a build that fails its smoke test never
  # reaches `latest`. A custom TAG has no dated tag and is pushed directly.
  PUSH_REF="${DATED_REF:-$REF}"
  echo "==> Building + pushing ${PUSH_REF} for ${PLATFORM} via buildx"
  "$ENGINE" buildx build --pull $NO_CACHE $REFRESH_ARG \
    --platform "$PLATFORM" \
    --sbom=true --provenance=mode=max \
    -t "$PUSH_REF" \
    --push \
    .
  if sync_local_tag_from_registry "$PUSH_REF"; then
    smoke_test "$PUSH_REF"
  elif [[ "$SMOKE" -eq 1 && -n "$DATED_REF" ]]; then
    echo "error: can't smoke-test ${PUSH_REF} on this host, so '${REF}' was not moved." >&2
    echo "       re-run with --skip-smoke to publish it untested." >&2
    exit 1
  fi
  if [[ -n "$DATED_REF" ]]; then
    echo "==> Promoting ${DATED_REF} to ${REF}"
    "$ENGINE" buildx imagetools create -t "$REF" "$DATED_REF"
  fi
  echo "==> Done: ${REF} (${PLATFORM})"
  exit 0
fi

# ── Single-arch path ──────────────────────────────────────────────────────────
echo "==> Building ${REF} with '${ENGINE}'"
"$ENGINE" build --pull $NO_CACHE $REFRESH_ARG -t "$REF" .

# Point the local run name at this fresh build (compose.yaml / fragua-host use it).
if [[ -n "$LOCAL_TAG" && "$LOCAL_TAG" != "$REF" ]]; then
  echo "==> Tagging ${REF} as ${LOCAL_TAG}"
  "$ENGINE" tag "$REF" "$LOCAL_TAG"
fi

smoke_test "$REF"

if [[ "$PUSH" -eq 0 ]]; then
  echo "==> Built ${REF} (push skipped)"
  exit 0
fi

maybe_login
echo "==> Pushing ${REF}"
"$ENGINE" push "$REF"
if [[ -n "$DATED_REF" ]]; then
  "$ENGINE" tag "$REF" "$DATED_REF"
  "$ENGINE" push "$DATED_REF"
fi

echo "==> Done: ${REF}${DATED_REF:+ + ${DATED_REF}}"
echo "    First push lands as a PRIVATE package — set it public in"
echo "    github.com/orgs/maquina-app/packages if you want anonymous pulls."
