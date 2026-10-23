#!/usr/bin/env python3
"""tools/vm-inspect.py — the signed, region-correct view of the emulated vm.

boto3 signs and uses the region the terraform run used, so DescribeInstances
returns the instance. (An unsigned curl lands in LocalEmu's default region
bucket and can come back empty — the same trap that bit the LocalStack setup
in ../aws-local-test.)

Prints: the EC2 records, the docker container that is actually running, the
S3 objects under the prefix, and the manifest the vm reads from inside.
"""
import json
import subprocess
import sys

import boto3
from botocore.exceptions import ClientError

GATEWAY = "http://localhost:4566"
REGION = "us-east-1"


def arg(name, default):
    for i, a in enumerate(sys.argv):
        if a == f"--{name}":
            return sys.argv[i + 1]
    return default


BUCKET = arg("bucket", "localemu-vm-drop")
PREFIX = arg("prefix", "vm/")
CURRENT = arg("instance", "")

_kw = dict(
    region_name=REGION,
    endpoint_url=GATEWAY,
    aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
    aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
)
ec2 = boto3.client("ec2", **_kw)
s3 = boto3.client("s3", **_kw)

print("== EC2: DescribeInstances (signed, region=%s) ==" % REGION)
rows = [i for r in ec2.describe_instances()["Reservations"] for i in r.get("Instances", [])]
if not rows:
    print("  (no instances in this region)")
for i in sorted(rows, key=lambda x: x["InstanceId"]):
    tags = {t["Key"]: t["Value"] for t in i.get("Tags", [])}
    state = i.get("State", {}).get("Name", "?")
    mark = "current" if i["InstanceId"] == CURRENT else "orphan"
    print(
        "  %-22s %-8s %-9s %-10s %-8s %s"
        % (i["InstanceId"], state, i.get("InstanceType", "?"),
           i.get("PrivateIpAddress", "?"), tags.get("Name", "-"), mark)
    )
print("  orphans are API records left by a previous `tofu destroy`: LocalEmu")
print("  stops the container, but the persisted instance record stays until")
print("  the emulator restarts (same shape as real AWS's DescribeInstances).")

print("\n== docker: the instance containers LocalEmu actually launched ==")
out = subprocess.run(["docker", "ps", "-a"], capture_output=True, text=True)
for line in (out.stdout or "").splitlines():
    if "localemu-ec2" in line or "localemu-imds" in line:
        print("  " + line.strip())

print("\n== S3: list_objects_v2 under %s/%s ==" % (BUCKET, PREFIX))
try:
    listing = s3.list_objects_v2(Bucket=BUCKET, Prefix=PREFIX)
    for o in listing.get("Contents", []):
        print("  %-46s %8d  %s" % (o["Key"], o["Size"], o["LastModified"]))
    print("  total: %s objects" % listing.get("KeyCount", 0))
except ClientError as e:
    print("  %s" % e)

print("\n== manifest the vm reads (s3://%s/%stf-manifest.json) ==" % (BUCKET, PREFIX))
try:
    m = s3.get_object(Bucket=BUCKET, Key=PREFIX + "tf-manifest.json")
    print("  " + json.dumps(json.loads(m["Body"].read()), indent=2).replace("\n", "\n  "))
except ClientError as e:
    print("  %s" % e)
