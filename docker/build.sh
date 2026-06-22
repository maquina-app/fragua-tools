#!/usr/bin/env bash
#
# Build the Fragua agent image and (optionally) push it to GHCR.
# For Docker / OrbStack.
#
# Usage:
#   ./build.sh                          # build + push  ghcr.io/maquina-app/fragua-docker:latest
#   ./build.sh --no-push                # build only, no registry push
#   ./build.sh --no-cache               # force a clean rebuild from scratch
#   ./build.sh --platform linux/amd64,linux/arm64
#                                       # multi-arch build via buildx (pushes directly)
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

# ── Parse args ────────────────────────────────────────────────────────────────
PUSH=1
NO_CACHE=""
PLATFORM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push)  PUSH=0 ;;
    --no-cache) NO_CACHE="--no-cache" ;;
    --platform) PLATFORM="$2"; shift ;;
    -h|--help)  sed -n '2,21p' "$0"; exit 0 ;;
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

# ── Multi-arch path (buildx builds and pushes in one step) ────────────────────
if [[ -n "$PLATFORM" ]]; then
  if [[ "$PUSH" -eq 0 ]]; then
    echo "error: --platform requires pushing (buildx can't load multi-arch locally)" >&2
    echo "       drop --no-push, or use a single --platform value." >&2
    exit 1
  fi
  maybe_login
  echo "==> Building + pushing ${REF} for ${PLATFORM} via buildx"
  "$ENGINE" buildx build $NO_CACHE \
    --platform "$PLATFORM" \
    -t "$REF" \
    --push \
    .
  echo "==> Done: ${REF} (${PLATFORM})"
  exit 0
fi

# ── Single-arch path ──────────────────────────────────────────────────────────
echo "==> Building ${REF} with '${ENGINE}'"
"$ENGINE" build $NO_CACHE -t "$REF" .

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
