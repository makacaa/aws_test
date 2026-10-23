# github_runner — the tiny vm that becomes a GitHub self-hosted runner

Terraform creates the vm against **LocalEmu** (local AWS, `localhost:4566`);
the vm itself is a **real Ubuntu 22.04 container** (`localemu/ec2-base:v4`), so
the real `github-runner` binary runs in it and talks to real `github.com`.

| | |
|---|---|
| vm name | `github_runner` (tag `Name`) |
| instance | `aws_instance.vm` → `i-…` @ `10.0.1.4` |
| instance type | `t2.medium` = 4 GB docker memory limit (runner wants ≥ 2 GB) |
| AMI | `ami-ubuntu-22.04` → `localemu/ec2-base:v4` (curl, awscli, sshd, iptables) |
| container | `localemu-ec2-<instance-id>` |
| VPC | `aws_vpc` + **`aws_internet_gateway`** + subnet + SG (egress `0.0.0.0/0`) |
| bucket | `localemu-runner-logs` → `runner/` (the vm posts its job logs there) |

The Internet Gateway is what makes the vm internet-facing: LocalEmu creates a
VPC's Docker network as `--internal` (no host egress), and
`AttachInternetGateway` recreates it **without** `--internal`. Verified from
inside the vm:

```
github.com  http=200      api.github http=200      (internet egress)
AWS_ENDPOINT_URL=http://host.docker.internal:4566  (local AWS)
aws s3 cp /tmp/from-vm.txt s3://localemu-runner-logs/runner/from-vm/…  -> upload ok
```

## 1. Jump into the vm

```bash
cd github_runner
tofu output --raw vm_container            # localemu-ec2-i-…
localemu ssh "$(tofu output --raw ec2_instance_id)"   # LocalEmu's docker-exec shim
# or
docker exec -it "$(tofu output --raw vm_container)" bash
```

## 2. Register it as a self-hosted runner (browser path)

Open one of these **in your browser**, click through the registration, and
GitHub prints the three `export` lines:

```
repo level : https://github.com/makacaa/aws_test/settings/actions/runners/new
user level : https://github.com/settings/runners/new
org  level : https://github.com/organizations/<ORG>/settings/actions/runners/new
```

Copy the values (`RUNNER_SECRET`, `RUNNER_ID`, `RUNNER_TOKEN`) — they are good
for ~10 minutes. Name the runner **`github_runner`** so
`.github/workflows/vm-s3-deploy.yml` (`run.target: github_runner`) matches.

Browser-free alternative: `POST /runner-sessions` with GitHub's public OAuth
client pair (`client_id`/`client_secret`, `service=github`,
`auto_install=true`) returns `runner_id` + `runner_secret`; then
`POST /runner/<runner_id>/refreshtoken` (`service=github`) returns the JWT for
`RUNNER_TOKEN`.

## 3. Start the runner inside the vm

```bash
# host side, one shot (values from the page above)
docker exec -i \
  -e RUNNER_ID=… -e RUNNER_SECRET=… -e RUNNER_TOKEN=… \
  "$(tofu output --raw vm_container)" bash -s \
  < vm/install-runner.sh
```

`vm/install-runner.sh` checks both egress paths first (github.com and the
emulator), downloads the latest `actions-runner-linux-x64` build from
`actions/runner` releases, extracts it to `/runner`, and starts
`bin/github-runner` with `RUNNER_ID`/`RUNNER_SECRET`/`RUNNER_TOKEN`/
`RUNNER_HOME`/`RUNNER_LOG_DIR`. Logs land in `/runner/logs`.

The runner stays up only while that exec is attached. To keep it alive across
Actions runs, start it with `nohup … &` inside the vm (the container has no
systemd) and re-register when the token expires.

## 4. The Action that runs ON the vm

`.github/workflows/vm-s3-deploy.yml` has `run.target: github_runner`, so every
step executes inside the vm: it installs OpenTofu through the vm's internet
egress, runs `tofu apply -var gateway_host=host.docker.internal` against the
local emulator, then `aws s3 cp`s files from the vm's own `/tmp/vm-outbox` into
`s3://localemu-runner-logs/runner/from-vm/` and sha256-compares them.

## Cleanup notes (what LocalEmu can and cannot delete)

`tools/cleanup.py` keeps only the runner's graph (read from the manifest in the
bucket) and deletes the rest. What actually works:

| object | op | result |
|---|---|---|
| instances | `StopInstances` | container stopped; **record stays** (`State.Name = stopped`) — no `DeleteInstances` op |
| security groups | `DeleteSecurityGroup` | deleted ✓ |
| internet gateways | `DeleteInternetGateway` | only if attached to a deletable VPC; orphan IGWs hit `DependencyViolation` |
| VPCs / subnets | — | **no delete op implemented** → they persist until the emulator restarts |
| buckets | `DeleteBucket` | works once emptied (`BucketNotEmpty` otherwise) |
