#!/usr/bin/env bash
#
# Build the Fragua agent image and (optionally) push it to GHCR.
#
# Usage:
#   ./build.sh                 # build + push  ghcr.io/maquina-app/fragua-container:latest
#   ./build.sh --no-push       # build only, no registry push
#   ./build.sh --no-cache      # force a clean rebuild from scratch
#   ./build.sh --engine docker # use `docker` instead of Apple `container`
#
# Authentication for the push (only needed once per machine):
#   export GITHUB_USER=<your-github-username>
#   export GITHUB_TOKEN=<a PAT with `write:packages` scope>
#   ./build.sh
# If those vars are unset the script assumes you have already logged in
# (`container registry login ghcr.io` / `docker login ghcr.io`).

set -euo pipefail

# ── Configuration (override via env) ──────────────────────────────────────────
REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE="${IMAGE:-maquina-app/fragua-container}"
TAG="${TAG:-latest}"
ENGINE="${ENGINE:-container}"   # `container` (Apple) or `docker`

REF="${REGISTRY}/${IMAGE}:${TAG}"

# ── Parse args ────────────────────────────────────────────────────────────────
PUSH=1
NO_CACHE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push)  PUSH=0 ;;
    --no-cache) NO_CACHE="--no-cache" ;;
    --engine)   ENGINE="$2"; shift ;;
    -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
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

# ── Build ─────────────────────────────────────────────────────────────────────
echo "==> Building ${REF} with '${ENGINE}'"
"$ENGINE" build $NO_CACHE -t "$REF" .

if [[ "$PUSH" -eq 0 ]]; then
  echo "==> Built ${REF} (push skipped)"
  exit 0
fi

# ── Login (optional, only if credentials are provided) ────────────────────────
if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_USER:-}" ]]; then
  echo "==> Logging in to ${REGISTRY} as ${GITHUB_USER}"
  echo "$GITHUB_TOKEN" | "$ENGINE" registry login "$REGISTRY" -u "$GITHUB_USER" --password-stdin 2>/dev/null \
    || echo "$GITHUB_TOKEN" | "$ENGINE" login "$REGISTRY" -u "$GITHUB_USER" --password-stdin
fi

# ── Push ──────────────────────────────────────────────────────────────────────
echo "==> Pushing ${REF}"
case "$ENGINE" in
  container) "$ENGINE" image push "$REF" ;;
  *)         "$ENGINE" push "$REF" ;;
esac

echo "==> Done: ${REF}"
echo "    First push lands as a PRIVATE package — set it public in"
echo "    github.com/orgs/maquina-app/packages if you want anonymous pulls."
