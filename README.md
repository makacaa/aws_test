# localemu-vm-s3

Tiny-vm → S3 test project. The sibling project on the same machine
(`C:/DEV/DSH/aws-local-test`) targets **LocalStack**; this one targets
**LocalEmu** — the free, open-source AWS emulator (`pip install localemu`,
<https://github.com/localemu/localemu>, `localemu.cloud`).

It creates a **tiny EC2 vm** (a real Docker container on a real VPC network) plus an
**S3 bucket**, then **copies files from inside the vm up into `s3://…/vm/from-vm/`**
and verifies the round trip byte-for-byte.

```
host (Windows: OpenTofu 1.12.6 + awscli 1.44 + LocalEmu 1.3.2)
  └── tofu apply ─────────────┐   ec2: vpc-…, subnet-…, sg-…, i-… @ 10.0.1.4
                              ▼
        http://localhost:4566            <- LocalEmu gateway (133 services)
                              │
docker container localemu-ec2-i-…  (the vm; AMI = localemu/ec2-base:v4)
  └── aws s3 cp /vm-outbox/*  ---->  s3://localemu-vm-drop/vm/from-vm/…
```

| knob | value |
|---|---|
| emulator | LocalEmu 1.3.2, `localemu start -d`, port `4566` |
| region | `us-east-1` |
| endpoint | `http://localhost:4566` (host) / `http://host.docker.internal:4566` (inside the vm) |
| bucket | `localemu-vm-drop` |
| folder | `vm/` (terraform-written) + `vm/from-vm/` (written **by** the vm) |
| ec2 vm | `aws_instance.vm` → `i-…` @ `10.0.1.4`, `t2.micro` = 1 GB docker mem limit |
| AMI | `ami-ubuntu-22.04` → `localemu/ec2-base:v4` (sshd, iptables, curl, **awscli** baked in) |
| vm container | `localemu-ec2-<instance-id>` |

## Layout

```
localemu-vm-s3/
├── main.tf              provider + VPC/subnet/SG + tiny vm + bucket + manifest
├── terraform.tfvars     region / endpoint / bucket / prefix / AMI / instance_type
├── deploy.sh            host entrypoint: tofu + docker exec into the vm + verify
├── vm/                  scripts that run INSIDE the emulated vm
│   ├── drop-to-s3.sh    identity + IMDS + write /vm-outbox + aws s3 cp up
│   ├── verify-in-vm.sh  list, etags, sha256 vm-copy vs s3-copy
│   └── pull-from-s3.sh  reverse: aws s3 cp --recursive -> /vm-inbox + sha256
└── tools/
    └── vm-inspect.py    signed boto3 DescribeInstances + S3 listing (host side)
```

## Run

```bash
pip install localemu            # once; also installs the host awscli
localemu start -d               # detached; http://localhost:4566
localemu status                 # 133 services, ec2 backend = docker

cd aws_test                     # repo root
./deploy.sh                     # tofu init/plan/apply + vm drop + verify + pull + inspect
./deploy.sh plan                # plan only
./deploy.sh vm                  # re-run the vm drop against the existing deploy
./deploy.sh pull                # s3 -> vm download only
TF=terraform ./deploy.sh        # terraform works identically (tofu is the fork)

# talk to the vm directly
localemu ssh i-…                # LocalEmu's docker-exec shortcut

# s3 -> vm (one file / whole prefix) — see vm/pull-from-s3.sh
CID=localemu-ec2-$(tofu output --raw ec2_instance_id)
docker exec -i -e BUCKET=localemu-vm-drop -e PREFIX=vm "$CID" bash -s \
  < vm/pull-from-s3.sh
# single file instead of the whole prefix: pass KEY=
docker exec -i -e BUCKET=localemu-vm-drop -e PREFIX=vm -e KEY=tf-manifest.json "$CID" bash -s \
  < vm/pull-from-s3.sh

# host (C:) -> vm, no s3 involved
docker cp data/from-host.txt "$CID:/vm-outbox/from-host.txt"
docker exec -i localemu-ec2-i-… bash -s < vm/verify-in-vm.sh
awsemu s3 ls --recursive s3://localemu-vm-drop/vm/   # host side, zero config
```

## What the run proved

```
tiny vm: instance=i-b264d8e480c2e64f4 type=t2.micro az=us-east-1a
gateway seen from inside the vm: http://host.docker.internal:4566
IMDS: instance-id=i-b264d8e480c2e64f4  ami-id=ami-ubuntu-22.04  local-ipv4=10.0.1.4
upload: vm-outbox/vm-hello.txt  -> s3://localemu-vm-drop/vm/from-vm/vm-hello.txt
        vm-outbox/vm-report.json -> s3://localemu-vm-drop/vm/from-vm/vm-report.json
        vm-outbox/nested/vm-nested.txt -> …/from-vm/nested/vm-nested.txt
sha256 vm-copy vs s3-copy:  vm-hello.txt MATCH  vm-report.json MATCH  nested/vm-nested.txt MATCH
```

The vm reads the manifest terraform wrote (`vm/tf-manifest.json`) through the
same gateway, so the terraform side and the vm side are provably the **same**
bucket, and the vm knows its own instance id via IMDS.

## Provider wiring (what worked, aws module 6.70.0 from the OpenTofu registry)

```hcl
provider "aws" {
  region      = "us-east-1"
  # creds from the environment - never hardcode them here

  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints { ec2 = "http://localhost:4566", s3 = "http://localhost:4566", sts = "http://localhost:4566" }
}
```

## `gh_runner/` — the CI-tuned twin (this is what the Action deploys)

```
gh_runner/
├── main.tf              same resources + an aws_internet_gateway (igw-…)
├── terraform.tfvars     bucket localemu-gh-runner (its own bucket, so CI never
│                        fights the local deploy above)
├── bootstrap.sh         the runner bootstrap: docker guard, localemu start in
│                        the FOREGROUND as a background job, log kept, gateway
│                        polled, log dumped if it never binds
├── vm/                  drop-to-s3.sh · verify-in-vm.sh · pull-from-s3.sh
└── tools/vm-inspect.py  signed boto3 view (region-correct)
```

The Internet Gateway is the Linux-Docker half of the egress problem: LocalEmu
creates a VPC's Docker network as `--internal` (no host egress), and
`AttachInternetGateway` recreates it **without** `--internal` — that is what
gives the vm a route to the emulator gateway on a plain Linux daemon, where
Docker Desktop's `host.docker.internal` mapping cannot be relied on. Verified
locally first: the IGW vm writes `/vm-outbox`, `aws s3 cp` up to
`s3://localemu-gh-runner/vm/from-vm/`, and the sha256 round trip MATCHes.

## GitHub Action (`deploy.yml`)

`.github/workflows/deploy.yml` deploys the **`gh_runner/`** project on every push
to `main` (and on demand via **Actions → deploy → Run workflow**):

```
docker daemon check (docker info)
  → install OpenTofu 1.13.2 (linux_amd64 release tarball)
  → pip install localemu                 (the emulator itself + host awscli)
  → gh_runner/bootstrap.sh               (foreground start + log + gateway poll)
  → cd gh_runner && tofu init/plan/apply (VPC + IGW + subnet + SG + vm + bucket)
  → docker exec into localemu-ec2-i-… : vm/drop-to-s3.sh + vm/verify-in-vm.sh
  → awsemu s3 ls --recursive + gh_runner/tools/vm-inspect.py
  → summary (vm id, IGW id, container, bucket listing)
  → localemu stop
```

No AWS account, no token: the runner talks only to `localhost:4566`, i.e. the
emulator *is* the AWS it deploys against — "local AWS on the runner".

Why `bootstrap.sh` instead of `localemu start -d`: detached mode re-execs
`python -m localemu.runtime.main` with **stdout and stderr sent to DEVNULL**
(`localemu/cli/main.py`), so a startup failure is invisible — the first CI run
printed `LocalEmu started (PID: 2340)` then `gateway http=000` and died with no
explanation. The bootstrap keeps the log, polls, and dumps the log if the
port never binds, so the real error is in the Actions output.

## Gotchas (all hit live in this run)

- **The vm's egress is real packet filtering.** LocalEmu compiles the security
  group into iptables chains *inside* the instance container
  (`SG_OUT` → `ACCEPT` per rule, then a final `DROP`). With
  `egress { cidr_blocks = [vpc_cidr] }` every packet to the emulator gateway
  (Docker's host gateway IP) is dropped, and from the vm it looks like a
  **connection timeout**, not an HTTP error. Fix: admit the host —
  `cidr_blocks = concat([var.vpc_cidr], ["0.0.0.0/0"])`, i.e. an
  internet-facing/public subnet. Narrow it to the gateway CIDR for the stricter
  NAT-only shape.
- **Changing the SG after the vm exists fails.** tofu updates
  `vpc_security_group_ids` with `ModifyNetworkInterfaceAttribute`; LocalEmu has
  no ENI for the classic `aws_instance` → `InvalidNetworkInterfaceID.NotFound`.
  Destroy + re-apply instead of mutating (`tofu destroy --auto-approve` then
  `tofu apply`).
- **`aws_instance`, not `aws_ec2_instance`** — same as the LocalStack project;
  `aws_ec2_instance` is not a resource type in terraform-provider-aws v6.
- **`aws_s3_object` payload arg is `content`** in the v6 provider (v7+ renamed it).
- **`type = int` is rejected** by OpenTofu 1.12 in a `variable` block
  ("The keyword "int" is not a valid type specification") — leave the type off.
- **`tofu destroy` on a non-empty bucket fails** with `BucketNotEmpty` — that is
  real AWS semantics. Empty it first: `awsemu s3 rm s3://<bucket>/<key>` per
  object (there is no `s3 rmdir` in this awscli build).
- **Destroyed instances leave a record.** LocalEmu stops the container
  (`docker ps` shows only the live one) but the persisted EC2 record stays, so
  `DescribeInstances` lists orphans with `State.Name = terminated`. `localemu
  stop` + restart clears them.
- **No credentials from IMDS by default.** The IMDS tree is served
  (link-local `169.254.169.254` is DNAT'd to a per-VPC sidecar container), but
  `/latest/meta-data/iam/security-credentials/` is empty unless the instance
  carries an IAM role, and classic `aws_instance` cannot attach one. The vm
  scripts therefore fall back to LocalEmu's documented dummy pair — the
  emulator accepts any credentials.
- **Inside the vm, `AWS_ENDPOINT_URL` is already injected**
  (`http://host.docker.internal:4566`) together with `AWS_REGION` and the
  `LOCALEMU_*` identity vars — the vm scripts configure nothing.
- **awscli v1 in the vm:** `--recursive` on both `s3 ls` and `s3 cp` (there is
  no `-R`/`-r` short form), `aws s3 cp <key> -` to cat, and a folder marker needs
  `aws s3api put-object --key "prefix/"` (`aws s3 cp /dev/null` is skipped by the
  CLI, and `cp -` names the key `-`).
  to cat, and a folder marker needs `aws s3api put-object --key "prefix/"`
  (`aws s3 cp /dev/null` is skipped by the CLI, and `cp -` names the key `-`).
- **Do not name a helper script `inspect.py`** — it shadows stdlib `inspect`
  and botocore then dies with a circular import (`boto3 has no attribute client`).
- **`aws_instance` takes ~15 s** because the provider polls until the instance
  reports `running` — normal, not a hang.
- **`localemu ssh <instance-id>`** is a `docker exec` shortcut into the
  instance container; SSH itself needs a key pair and same-VPC-network
  reachability (the bastion pattern), which this test does not need.
