#!/usr/bin/env bash
# ==============================================================================
# vm/verify-in-vm.sh — read the dropped objects back from INSIDE the vm
#
#   docker exec -i "localemu-ec2-<instance-id>" bash -s < vm/verify-in-vm.sh
#
# Proves the round trip: terraform wrote <prefix>/tf-manifest.json, the vm
# wrote <prefix>/from-vm/*, and both are now visible from the vm and from the
# host through the same emulator gateway.
# ==============================================================================
set -euo pipefail

BUCKET="${BUCKET:-localemu-vm-drop}"
PREFIX="${PREFIX:-vm}"
SUBPREFIX="${SUBPREFIX:-from-vm}"

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
  _gw=$(grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}[[:space:]]+host\.docker\.internal$' /etc/hosts | head -1 | cut -f1)
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

echo "-- whole prefix: aws s3 ls --recursive s3://${BUCKET}/${PREFIX}/ --"
aws s3 ls --recursive "s3://${BUCKET}/${PREFIX}/"

echo "-- keys + sizes + etags (aws s3api list-objects-v2) --"
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "${PREFIX}/" \
  --output table --query 'Contents[].[Key,Size,Etag]' | head -30

echo "-- sha256 of the vm's own copy vs the s3 copy --"
for f in vm-hello.txt vm-report.json nested/vm-nested.txt; do
  local_sum=$(sha256sum "/vm-outbox/${f}" 2>/dev/null | cut -d' ' -f1 || echo "-")
  s3_sum=$(aws s3 cp "s3://${BUCKET}/${PREFIX}/${SUBPREFIX}/${f}" - 2>/dev/null | sha256sum | cut -d' ' -f1 || echo "-")
  printf "  %-22s vm=%s s3=%s %s\n" "$f" "$local_sum" "$s3_sum" \
    "$([ "$local_sum" = "$s3_sum" ] && echo MATCH || echo DIFF)"
done
echo "==> verify complete"
