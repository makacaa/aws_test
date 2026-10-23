#!/usr/bin/env bash
# ==============================================================================
# github_runner/vm/install-runner.sh — run INSIDE the tiny vm
#
#   Turns the emulated EC2 vm into a GitHub self-hosted runner. The vm is a real
#   Ubuntu 22.04 Docker container (localemu/ec2-base:v4), so the real runner
#   binary runs in it; it talks to real github.com, while terraform above talks
#   to the local AWS emulator. That is exactly why the subnet is internet-facing
#   (aws_internet_gateway + SG egress 0.0.0.0/0).
#
#   Jump in first (host side):
#       ./vm/jump-in.sh                       # docker exec -it into the vm
#   then, inside the vm:
#       RUNNER_ID=… RUNNER_SECRET=… RUNNER_TOKEN=… bash -s < install-runner.sh
#
#   Values come from GitHub's "Register a new self-hosted runner" page (the
#   export lines it prints) or from POST /runner-sessions + POST /runner/<id>/refreshtoken.
# ==============================================================================
set -euo pipefail

RUNNER_HOME="${RUNNER_HOME:-/runner}"
SERVER="${RUNNER_SERVER:-https://github.com}"
RELEASE="${RUNNER_RELEASE:-latest}"   # latest | v2.338.1 | …

echo "== 0. egress check: the vm must see BOTH github.com and the emulator =="
curl -fsS -o /dev/null -w "github.com  http=%{http_code}\n" -m 25 https://github.com/ \
  || echo "!! no internet egress — the Internet Gateway / SG egress is not open"
curl -s -o /dev/null -w "emulator    http=%{http_code}\n" -m 10 "${AWS_ENDPOINT_URL:-http://localhost:4566}/_health" \
  || echo "!! no emulator egress"

: "${RUNNER_ID:?RUNNER_ID not set (from GitHub's register-runner page)}"
: "${RUNNER_SECRET:?RUNNER_SECRET not set}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN not set (JWT from POST /runner/<id>/refreshtoken)}"

echo "== 1. fetch the runner build =="
if [ "$RELEASE" = latest ]; then
  url="$(curl -fsS -m 25 https://api.github.com/repos/actions/runner/releases/latest \
        | python3 -c "import sys,json;d=json.load(sys.stdin);print(next(a['browser_download_url'] for a in d['assets'] if 'linux-x64' in a['name'] and a['name'].endswith('.tar.gz')))")"
else
  url="https://github.com/actions/runner/releases/download/${RELEASE}/actions-runner-linux-x64-${RELEASE}.tar.gz"
fi
echo "  url: $url"
mkdir -p "$RUNNER_HOME"
curl -fsSL -o /tmp/runner.tar.gz "$url"
tar -xzf /tmp/runner.tar.gz -C "$RUNNER_HOME"

entry=""
for cand in bin/github-runner bin/actions-runner; do
  [ -x "$RUNNER_HOME/$cand" ] && entry="$RUNNER_HOME/$cand" && break
done
[ -n "$entry" ] || { echo "!! no runner entrypoint in the tarball"; exit 1; }
echo "  entrypoint: $entry"

echo "== 2. start the runner (Ctrl-C to stop) =="
mkdir -p "$RUNNER_HOME/logs"
export RUNNER_ID RUNNER_SECRET RUNNER_TOKEN RUNNER_SERVER="$SERVER" \
       RUNNER_HOME="$RUNNER_HOME" RUNNER_LOG_DIR="$RUNNER_HOME/logs" \
       RUNNER_SKIP_VERSION_WARNING=true

"$entry" 2>&1 | tee "$RUNNER_HOME/logs/runner.log"
