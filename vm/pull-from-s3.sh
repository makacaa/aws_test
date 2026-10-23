#!/usr/bin/env bash
# ==============================================================================
# vm/pull-from-s3.sh — copy files DOWN from s3 into the tiny vm
#
#   docker exec -i -e BUCKET=… -e PREFIX=… localemu-ec2-<instance-id> bash -s \
#     < vm/pull-from-s3.sh
#
#   Reverse of drop-to-s3.sh: the vm downloads <prefix>/* into /vm-inbox with
#   the awscli baked into the AMI, using the AWS_ENDPOINT_URL LocalEmu already
#   injected. Proves the bucket is reachable in both directions.
#
#   Optional env:
#     KEY=<key under the prefix>   single file (default: whole prefix, -r)
# ==============================================================================
set -euo pipefail

BUCKET="${BUCKET:-localemu-vm-drop}"
PREFIX="${PREFIX:-vm}"
INBOX="${INBOX:-/vm-inbox}"
KEY="${KEY:-}"

# --- gateway resolution: works on Docker Desktop AND plain Linux -----------
# The AMI ships AWS_ENDPOINT_URL=http://host.docker.internal:4566, which only
# resolves when Docker maps the host into the container. Probe it; if the probe
# fails, take the dotted-quad host.docker.internal record out of /etc/hosts
# (Docker Desktop writes a second, non-dotted record that curl cannot use).
_gateway_ok() {
  [ -n "${AWS_ENDPOINT_URL:-}" ] || return 1
  curl -sS -m 5 -o /dev/null "${AWS_ENDPOINT_URL%/}/_health" 2>/dev/null || return 1
}
if !_gateway_ok; then
  _gw=$(grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}[[:space:]]+host\.docker\.internal$' /etc/hosts | sed -n '1,2p' | cut -f1)
  [ -n "$_gw" ] && export AWS_ENDPOINT_URL="http://${_gw}:4566"
fi
if !_gateway_ok; then
  echo "!! the vm cannot reach the LocalEmu gateway from inside its network"
  echo "   AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL:-<unset>}"
  echo "   /etc/hosts host.docker.internal: $(getent hosts host.docker.internal 2>/dev/null || echo none)"
  echo "   fix: give the subnet an Internet Gateway (aws_internet_gateway), or"
  echo "   run the emulator with EC2_VM_MANAGER=none for metadata-only instances"
  exit 1
fi

if ! aws s3 ls "s3://${BUCKET}/${PREFIX}/" >/dev/null 2>&1; then
  export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
  export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
fi
export AWS_PAGER=""

mkdir -p "$INBOX"

echo "-- aws s3 ls s3://${BUCKET}/${PREFIX}/ --"
aws s3 ls "s3://${BUCKET}/${PREFIX}/"

if [ -n "$KEY" ]; then
  echo "-- aws s3 cp s3://${BUCKET}/${PREFIX}/${KEY} -> ${INBOX}/${KEY} --"
  aws s3 cp "s3://${BUCKET}/${PREFIX}/${KEY}" "${INBOX}/${KEY}"
else
  echo "-- aws s3 cp --recursive s3://${BUCKET}/${PREFIX}/ -> ${INBOX}/ --"
  aws s3 cp --recursive "s3://${BUCKET}/${PREFIX}/" "${INBOX}/"
fi

echo "-- files now inside the vm (${INBOX}) --"
find "$INBOX" -type f | sort | while read -r f; do
  printf "  %6s  %s\n" "$(wc -c < "$f")" "$f"
done

echo "-- sha256 of the s3 copy vs the vm copy --"
for f in tf-manifest.json from-vm/vm-hello.txt from-vm/vm-report.json from-vm/nested/vm-nested.txt; do
  s3_sum=$(aws s3 cp "s3://${BUCKET}/${PREFIX}/${f}" - 2>/dev/null | sha256sum | cut -d' ' -f1 || echo -)
  vm_sum=$(sha256sum "${INBOX}/${f}" 2>/dev/null | cut -d' ' -f1 || echo -)
  printf "  %-30s s3=%s vm=%s %s\n" "$f" "$s3_sum" "$vm_sum" \
    "$([ "$s3_sum" = "$vm_sum" ] && echo MATCH || echo DIFF)"
done
echo "==> pull complete"
