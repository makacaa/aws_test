#!/usr/bin/env python3
"""github_runner/tools/cleanup.py — keep ONLY the runner's EC2 graph.

LocalEmu implements a subset of the EC2 delete surface, so this uses getattr
probes and does what the emulator actually supports:

  instances            StopInstances   (no DeleteInstances op -> the record
                                        stays, State.Name = terminated)
  internet gateways    DeleteInternetGateway
  security groups      DeleteSecurityGroup
  vpcs / subnets       NO delete op implemented -> they persist until the
                       emulator restarts (documented, not silently ignored)

The keep-set is read from the manifest terraform wrote into the bucket, so it
always matches what the terraform deploy owns right now.
"""
import json
import sys

import boto3

GATEWAY = "http://localhost:4566"
REGION = "us-east-1"
BUCKET = "localemu-runner-logs"
PREFIX = "runner/"

_kw = dict(
    region_name=REGION,
    endpoint_url=GATEWAY,
    aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
    aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
)
ec2 = boto3.client("ec2", **_kw)
s3 = boto3.client("s3", **_kw)


def attempt(label, op_name, **kw):
    fn = getattr(ec2, op_name, None)
    if fn is None:
        print("  NO SUCH OP %-22s (%s)" % (label, op_name))
        return
    try:
        fn(**kw)
        print("  done   %-22s %s" % (label, op_name))
    except Exception as e:
        print("  failed %-22s %s" % (label, str(e).split("\n")[0][:110]))


keep = set()
try:
    m = json.loads(s3.get_object(Bucket=BUCKET, Key=PREFIX + "runner-manifest.json")["Body"].read())
    keep = {v for v in m.values() if isinstance(v, str) and v.startswith(("vpc-", "subnet-", "sg-", "igw-", "i-"))}
    print("keep set:", sorted(keep))
except Exception as e:
    print("!! manifest unread, nothing will be kept:", e)

print("\n-- instances --")
for i in [x for r in ec2.describe_instances()["Reservations"] for x in r.get("Instances", [])]:
    iid = i["InstanceId"]
    if iid in keep:
        print("  KEEP instance %-22s %s" % (iid, i.get("State", {}).get("Name", "?")))
        continue
    attempt(iid, "stop_instances", InstanceIds=[iid])

print("\n-- internet gateways --")
for g in ec2.describe_internet_gateways()["InternetGateways"]:
    gid = g["InternetGatewayId"]
    if gid in keep:
        print("  KEEP igw", gid)
        continue
    attempt(gid, "detach_internet_gateway", InternetGatewayId=gid, VpcId="")
    attempt(gid, "delete_internet_gateway", InternetGatewayId=gid)

print("\n-- security groups --")
for s in ec2.describe_security_groups()["SecurityGroups"]:
    sgid = s["GroupId"]
    if sgid in keep:
        print("  KEEP sg", sgid)
        continue
    attempt(sgid, "delete_security_group", GroupId=sgid)

print("\n-- vpcs / subnets (no delete op in LocalEmu) --")
def pick(resp, *keys):
    for k in keys:
        if k in resp:
            return resp[k]
    return []


for v in pick(ec2.describe_vpcs(), "VPCs", "Vpcs", "VpcList"):
    print("  %s %s" % (v["VpcId"], "KEEP" if v["VpcId"] in keep else "orphan (no DeleteVpcs op)"))
for sn in pick(ec2.describe_subnets(), "Subnets", "SubnetList"):
    print("  %s %s" % (sn["SubnetId"], "KEEP" if sn["SubnetId"] in keep else "orphan (no DeleteSubnets op)"))

print("\n== after cleanup ==")
print("buckets ", [b["Name"] for b in s3.list_buckets()["Buckets"]])
print("insts   ", [(i["InstanceId"], i.get("State", {}).get("Name")) for r in ec2.describe_instances()["Reservations"] for i in r.get("Instances", [])])
print("sgs     ", [g["GroupId"] for g in ec2.describe_security_groups()["SecurityGroups"]])
print("igws    ", [g["InternetGatewayId"] for g in ec2.describe_internet_gateways()["InternetGateways"]])
