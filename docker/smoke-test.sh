#!/usr/bin/env bash
#
# Smoke-test a built image: toolchains, CLIs, native gem load, TypeScript and a
# real browser. build.sh runs this before anything reaches `latest`.
#
# Usage: ./smoke-test.sh [image]     (default local/fragua:latest)

set -euo pipefail

IMAGE="${1:-local/fragua:latest}"
ENGINE="${ENGINE:-docker}"

echo "==> Smoke-testing ${IMAGE}"
"$ENGINE" run --rm -i "$IMAGE" bash -s <<'SMOKE'
set -u
fail=0
check() { # name command...
  local name="$1"; shift
  if out="$("$@" 2>&1)"; then
    printf '  ok    %-16s %s\n' "$name" "$(printf '%s' "$out" | head -n1 | cut -c1-60)"
  else
    printf '  FAIL  %-16s %s\n' "$name" "$(printf '%s' "$out" | tail -n1 | cut -c1-100)"; fail=1
  fi
}

check ruby          ruby -v
check rails         rails -v
check node          node -v
check tsc           tsc -v
check pnpm          pnpm -v
check yarn          yarn -v
check fragua        fragua --version
check recuerd0      recuerd0 version
check equipr        equipr --version
check claude        claude --version
check codex         codex --version
check gh            gh --version
check gh-signoff    test -d /root/.local/share/gh/extensions/gh-signoff
check chrome        google-chrome-stable --version
check vips          vips --version
check magick        magick -version
check ffmpeg        ffmpeg -version
check reaper        test "$(cat /proc/1/comm)" = tini

mkdir -p /tmp/smoke && cd /tmp/smoke
check ruby-stdlib   ruby -ropenssl -rzlib -rpsych -rreadline -e 'puts OpenSSL::OPENSSL_LIBRARY_VERSION'
printf 'const m: string = "ts ok"; console.log(m);\n' > a.ts
check tsx           tsx a.ts
check node-ts       node a.ts

check agent-browser agent-browser open 'data:text/html,<h1>ok</h1>'
check screenshot    agent-browser screenshot /tmp/smoke/s.png
agent-browser close >/dev/null 2>&1 || true

cat > pw.cjs <<JS
const { chromium } = require("$(NPM_CONFIG_PREFIX= npm root -g)/playwright");
(async () => {
  const b = await chromium.launch({ channel: "chrome" });
  console.log("chrome", b.version());
  await b.close();
})().catch((e) => { console.error(e.message); process.exit(1); });
JS
check playwright    node pw.cjs

exit "$fail"
SMOKE
echo "==> Smoke test passed"
