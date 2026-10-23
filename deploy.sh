#!/usr/bin/env bash
# ==============================================================================
# deploy.sh — host entrypoint (git-bash on Windows / bash on linux-mac)
#
#   ./deploy.sh            tofu init + plan + apply + vm drop + verify + pull + inspect
#   ./deploy.sh plan       stop after the plan
#   ./deploy.sh vm         skip terraform: vm -> s3 drop + verify
#   ./deploy.sh pull       skip terraform: s3 -> vm download only
#
#   Requires: LocalEmu running (localemu start -d), Docker daemon, tofu/terraform.
# ==============================================================================
set -euo pipefail

TF="${TF:-tofu}"                 # terraform works identically: TF=terraform
PY="${PY:-python3}"              # python3 exists on both git-bash and CI linux
BUCKET="${BUCKET:-localemu-vm-drop}"
PREFIX="${PREFIX:-vm}"
STAGE="${1:-all}"

cd "$(dirname "$0")"

if [ "$STAGE" != "vm" ] && [ "$STAGE" != "pull" ]; then
  echo "==> 1/5 terraform ($TF) init/plan/apply"
  "$TF" init
  "$TF" plan
  if [ "$STAGE" = "plan" ]; then exit 0; fi
  "$TF" apply --auto-approve
fi

IID="$("$TF" output --raw ec2_instance_id)"
PIP="$("$TF" output --raw ec2_private_ip)"
CID="localemu-ec2-${IID}"
echo "    tiny vm: $IID @ $PIP   docker container: $CID"

if [ "$STAGE" = "vm" ] || [ "$STAGE" = "all" ]; then
  echo "==> 2/5 drop files INTO s3 FROM the vm"
  docker exec -i -e BUCKET="$BUCKET" -e PREFIX="$PREFIX" "$CID" bash -s \
    < vm/drop-to-s3.sh

  echo "==> 3/5 read them back FROM the vm"
  docker exec -i -e BUCKET="$BUCKET" -e PREFIX="$PREFIX" "$CID" bash -s \
    < vm/verify-in-vm.sh
fi

if [ "$STAGE" = "pull" ] || [ "$STAGE" = "all" ]; then
  echo "==> 4/5 pull files FROM s3 INTO the vm (reverse direction)"
  docker exec -i -e BUCKET="$BUCKET" -e PREFIX="$PREFIX" "$CID" bash -s \
    < vm/pull-from-s3.sh
fi

echo "==> 5/5 host-side view of the same bucket + the emulated EC2 vm"
awsemu s3 ls --recursive "s3://${BUCKET}/${PREFIX}/"
"$PY" tools/vm-inspect.py --instance "$IID" --bucket "$BUCKET" --prefix "$PREFIX/"

echo "==> done: s3://${BUCKET}/${PREFIX}/"
