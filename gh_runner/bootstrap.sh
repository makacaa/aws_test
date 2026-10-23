#!/usr/bin/env bash
# ==============================================================================
# gh_runner/bootstrap.sh — make LocalEmu real on the GitHub runner
#
#   The naive `localemu start -d` is NOT usable in CI: detached mode re-execs
#   `python -m localemu.runtime.main` with stdout AND stderr sent to DEVNULL
#   (localemu/cli/main.py), so a startup crash is invisible and the gateway
#   just sits connection-refused. Start in the FOREGROUND as a background job,
#   keep the log, poll the gateway, and dump the log if it never binds.
#
#   Also guards the docker daemon: LocalEmu's EC2 backend (EC2_VM_MANAGER=docker,
#   the default) needs it to launch the vm container.
# ==============================================================================
set -euo pipefail

PORT="${PORT:-4566}"
LOG="${LOG:-/tmp/localemu.log}"
HOST="${HOST:-0.0.0.0}"

echo "-- docker daemon (LocalEmu launches the vm container through it) --"
docker version | head -6
docker info | grep -E "^ Containers|^ Server| Cgroup" || true

echo "-- start LocalEmu in the foreground, backgrounded, with a log --"
nohup localemu start --host "$HOST" --port "$PORT" > "$LOG" 2>&1 &
LE_PID=$!
echo "localemu pid: $LE_PID"

up=0
for i in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 5 "http://localhost:${PORT}/"; then
    up=1
    echo "gateway up after ~$((i * 2))s"
    break
  fi
  if ! kill -0 "$LE_PID" 2>/dev/null; then
    echo "!! the localemu process exited before binding the gateway"
    break
  fi
  sleep 2
done

if [ "$up" != 1 ]; then
  echo "!! gateway never came up on http://localhost:${PORT}"
  echo "-- localemu log (this is where the real error is) --"
  tail -80 "$LOG" || true
  echo "-- python version the emulator is running on --"
  python3 --version
  exit 1
fi

echo "-- services --"
localemu status | tail -6
curl -s -o /dev/null -w "gateway http=%{http_code}\n" "http://localhost:${PORT}/" || true
