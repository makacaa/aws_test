#!/usr/bin/env bash
# ==============================================================================
# vm/drop-to-s3.sh — runs INSIDE the tiny EC2 vm (localemu-ec2-i-…)
#
#   docker exec -i "localemu-ec2-<instance-id>" bash -s < vm/drop-to-s3.sh
#
# What it does, from inside the emulated vm:
#   0. prints the vm's own identity (LOCALEMU_* env + IMDS link-local metadata)
#   1. reads the manifest terraform wrote into <bucket>/<prefix>/ — proof the
#      vm is looking at the same bucket the terraform run created
#   2. writes a few files into /vm-outbox (the vm's own filesystem)
#   3. aws s3 cp them up into <bucket>/<prefix>/from-vm/
#   4. lists + cats them back, from the vm
#
#   The AMI (ami-ubuntu-22.04 -> localemu/ec2-base:v4) ships awscli + curl, and
#   LocalEmu injects AWS_ENDPOINT_URL=http://host.docker.internal:4566 plus
#   AWS_REGION into the container, so the vm needs no configuration of its own.
# ==============================================================================
set -euo pipefail

BUCKET="${BUCKET:-localemu-vm-drop}"
PREFIX="${PREFIX:-vm}"
OUTBOX="${OUTBOX:-/vm-outbox}"
SUBPREFIX="from-vm"

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

echo "=================================================================="
echo " tiny vm: instance=${LOCALEMU_INSTANCE_ID:-?} type=${LOCALEMU_INSTANCE_TYPE:-?} az=${LOCALEMU_AZ:-?}"
echo " gateway seen from inside the vm: ${AWS_ENDPOINT_URL:-<none>}"
echo "=================================================================="

# --- 0. IMDS: the vm's own metadata, via the link-local address -------------
# LocalEmu DNATs 169.254.169.254:80 to the per-VPC IMDS sidecar, so the
# hardcoded link-local IP that every SDK uses works unmodified.
echo "-- IMDS (curl http://169.254.169.254/latest/meta-data/…) --"
for k in instance-id ami-id instance-type local-ipv4; do
  printf "  %-14s = %s\n" "$k" "$(curl -sS -m 5 -H 'Accept: text/plain' "http://169.254.169.254/latest/meta-data/$k" 2>/dev/null || echo '?')"
done

# --- credentials: IMDS role first, else the emulator's dummy pair -----------
if ! aws s3 ls "s3://${BUCKET}/${PREFIX}/" >/dev/null 2>&1; then
  echo "-- no IMDS role on this instance -> using LocalEmu's dummy pair --"
  export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
  export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
fi
export AWS_PAGER=""

# --- 1. read what terraform wrote, from inside the vm ----------------------
echo "-- GET <bucket>/<prefix>/tf-manifest.json from inside the vm --"
aws s3 cp "s3://${BUCKET}/${PREFIX}/tf-manifest.json" - 2>/dev/null | head -c 400 || echo "  (manifest missing)"
echo

# --- 2. write files on the vm's own filesystem ------------------------------
mkdir -p "${OUTBOX}/nested"
{
  echo "hello from the tiny vm"
  echo "instance_id = ${LOCALEMU_INSTANCE_ID:-?}"
  echo "instance_type = ${LOCALEMU_INSTANCE_TYPE:-?}"
  echo "region = ${LOCALEMU_REGION:-?}"
  echo "endpoint = ${AWS_ENDPOINT_URL:-?}"
  echo "written_at = $(date -u +%FT%TZ)"
  echo "sha256_of_me = $(sha256sum /etc/hostname | cut -d' ' -f1)"
} > "${OUTBOX}/vm-hello.txt"

VM_IP=$(curl -sS -m 5 -H 'Accept: text/plain' http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo "?")
printf '{"instance":"%s","ip":"%s","gateway":"%s","files":2,"ok":true}\n' \
  "${LOCALEMU_INSTANCE_ID:-?}" "$VM_IP" "${AWS_ENDPOINT_URL:-?}" \
  > "${OUTBOX}/vm-report.json"

echo "vm drop #2 — nested path, uploaded from inside the vm" \
  > "${OUTBOX}/nested/vm-nested.txt"

echo "-- files written inside the vm (${OUTBOX}) --"
find "${OUTBOX}" -type f | sort | while read -r f; do
  printf "  %s  %s\n" "$(wc -c < "$f")" "$f"
done

# --- 3. copy them UP to s3 --------------------------------------------------
echo "-- aws s3 cp  ->  s3://${BUCKET}/${PREFIX}/${SUBPREFIX}/ --"
upload() {
  local src="$1" dst="$2"
  aws s3 cp "$src" "s3://${BUCKET}/${PREFIX}/${SUBPREFIX}/${dst}"
}
upload "${OUTBOX}/vm-hello.txt"    "vm-hello.txt"
upload "${OUTBOX}/vm-report.json"  "vm-report.json"
upload "${OUTBOX}/nested/vm-nested.txt" "nested/vm-nested.txt"

# folder marker for the sub-prefix (S3 has no directories: a "folder" is a
# zero-byte key ending in /). `aws s3 cp` needs a real file, so use put-object.
aws s3api put-object --bucket "$BUCKET" --key "${PREFIX}/${SUBPREFIX}/" >/dev/null

# --- 4. read them back, from the vm -----------------------------------------
echo "-- aws s3 ls s3://${BUCKET}/${PREFIX}/${SUBPREFIX}/ --"
aws s3 ls "s3://${BUCKET}/${PREFIX}/${SUBPREFIX}/"
echo "-- aws s3 cat (cp to -) vm-hello.txt --"
aws s3 cp "s3://${BUCKET}/${PREFIX}/${SUBPREFIX}/vm-hello.txt" - 2>/dev/null | head -20
echo "==> vm drop complete"
