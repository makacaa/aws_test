# Reusable recipe — LocalEmu + OpenTofu + GitHub Actions

This is the **portable playbook** behind this repo. It works for any future
project that wants "a tiny vm, an S3 bucket, and a CI job that runs *on that
vm*". Every command below was run and verified in this repo (LocalEmu 1.3.2,
OpenTofu 1.13.2, aws provider 6.70.0, awscli 1.44.49, boto3 1.40.73).

---

## 1. The stack

| piece | what it is | gotcha |
|---|---|---|
| **LocalEmu** | free open-source AWS emulator: `pip install localemu`, gateway `http://localhost:4566`, ~133 services | it is **not** LocalStack (different tool, different quirks) |
| **EC2 backend** | real **Docker containers** on real VPC-derived networks | `docker` is not installed inside the vm — the vm *is* the container |
| **OpenTofu** | Terraform fork (`tofu`); Terraform works identically | pin the aws provider version (see §2) |
| **GitHub Actions** | the CI side; the vm is a **self-hosted runner** | `runs-on: self-hosted`, not the ubuntu image |

```
host (Windows/Linux/macOS)
  ├── tofu apply ────────────────► http://localhost:4566   (LocalEmu gateway)
  │                                     ec2: vpc / subnet / sg / igw / i-… @ 10.0.1.4
  │                                     s3 : buckets + objects
  ▼
docker container  localemu-ec2-<instance-id>          <- the "vm"
  ├── AWS_ENDPOINT_URL=http://host.docker.internal:4566   (baked in by LocalEmu)
  ├── IMDS http://169.254.169.254/…                      (signed, real creds)
  └── aws s3 cp /tmp/outbox/*  ->  s3://bucket/prefix/…  (vm -> S3)
```

---

## 2. Host setup (5 minutes)

```bash
pip install localemu            # also installs the host awscli (aws emu install awscli)
localemu start -d               # detached; gateway http://localhost:4566
localemu status                 # services + backends (ec2 = docker)
localemu list                   # dashboard: mostly S3/FIRE, no EC2 row
```

Windows notes (verified):
* `localemu stop` fails on Windows (`WinError 2`, no `pgrep`) — kill the PID on
  `:4566` instead.
* `localemu start -d` sends the child's stdout/stderr to `DEVNULL`, so a startup
  crash is invisible. For CI, start **foreground + logged**:
  `localemu start --port 4566 > emu.log 2>&1 &`
* `pip install` may need `--no-network` bypasses / a proxy on this machine.

Credentials: LocalEmu accepts the documented dummy pair
the documented dummy pair (see `secrets.env`, gitignored), and the
vm's IMDS hands out **signed** creds, so signed boto3/CLI calls work unchanged.

---

## 3. Terraform / OpenTofu project shape

Put the deployable project in a **subfolder** (`github_runner/` here) so CI
paths are stable:

```
github_runner/
├── main.tf            provider + EC2 graph + buckets + objects
├── terraform.tfvars   region / endpoint / names / AMI / instance_type
├── vm/                scripts that run INSIDE the emulated vm
└── tools/cleanup.py   delete objects + orphan service records
```

### 3.1 Endpoint + provider

```hcl
# endpoint comes from AWS_ENDPOINT_URL (host) or -var gateway_host=… (vm)
locals {
  gateway_host = "localhost"
  endpoint_url = "http://${local.gateway_host}:4566"
}

provider "aws" {
  region       = "us-east-1"
  endpoint_url = "http://${var.gateway_host}:4566"
  # NO creds here: they come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the
  # environment (CI = GitHub secrets, host = source secrets.env, vm = IMDS)
}
```

* **Pin the provider** (`aws = "6.70.0"` in `terraform-version`/`terraform.tfvars`)
  so host and vm resolve the same module. A drift in the aws provider version
  changes attribute sets and breaks `terraform.tfstate`.
* **`exist_ok` does not exist in aws 6.70.0** (it was a 6.69.x feature).
  Re-running `apply` on an existing bucket raises
  `BucketAlreadyExists` — delete the bucket first (`tools/cleanup.py`) or keep
  state (see §5).
* `aws_s3_object` needs a **folder object** to make `aws s3 ls <prefix>/` show
  the folder: `key = "<prefix>/"`.

### 3.2 The EC2 graph (this is the part LocalEmu's dashboard hides)

```hcl
resource "aws_vpc"              { name = "runner-vpc" }
resource "aws_subnet"           { vpc_id = aws_vpc… }
resource "aws_security_group"   { egress 0.0.0.0/0 }
resource "aws_internet_gateway" { vpc_id = aws_vpc… }   # <- the egress fix
resource "aws_instance" {
  name              = "github_runner"
  instance_type     = "t2.medium"      # t2.micro = 1 GB docker mem limit
  ami_id            = "ami-ubuntu-22.04"   # -> localemu/ec2-base:v4
  vpc_image_id      = aws_vpc…
  subnet_id         = aws_subnet…
  security_group_id = aws_security_group…
  internet_gateway  = aws_internet_gateway…
}
```

Verified outputs: `i-…` @ `10.0.1.4`, container `localemu-ec2-<instance-id>`,
`vpc-…`, `subnet-…`, `sg-…`, `igw-…`.

**`aws_internet_gateway` is required for a vm that talks to GitHub/S3.**
LocalEmu puts VPC containers on a Docker network created with `--internal`;
`AttachInternetGateway` recreates that network **without** `--internal`, which
is what gives the vm egress. Without it, `curl api.github.com` from the vm
fails with a connect error (not an HTTP error).

### 3.3 Inspecting what exists

### 3.3 What the emulator does and does not show (verified on 1.3.2)

There is **no `localemu list`** command. The CLI is:
`start | status | services | ssh | export | import`.

| way to look | what you actually get |
|---|---|
| `http://localhost:4566/_localemu/dashboard` | a services browser only. `GET /_localemu/api/overview` returns `{version, uptime_seconds, port, features, services}` — **no resource data at all**, so the dashboard can never show "the vm" or "the buckets" |
| `localemu ssh --list` | **the EC2 instances that are actually running** (docker names) — this is the reliable EC2 view |
| `docker ps` | the same containers: `localemu-ec2-i-…` + `localemu-imds-vpc-…` |
| `aws s3 ls` / `aws s3 ls --recursive` (signed) | buckets + objects with byte counts |
| `tools/vm-inspect.py` (signed boto3) | `DescribeInstances` + VPC/IGW/subnet/SG graph + S3 listing — the full picture |
| `localemu export --format json` | `resources: []` — it does **not** track EC2/S3 objects, don't use it as an inventory |
| `aws emu …` | only works with the emulator-patched CLI; the AMI's `aws` is vanilla → `aws: error: argument command: Invalid choice` |

```bash
localemu ssh --list
python tools/vm-inspect.py --bucket <payload-bucket> --prefix <prefix>/ --instance "$IID"
```

---

## 4. GitHub side

### 4.1 The vm is the runner

Register the vm container as a **self-hosted runner** (Settings →
`github.com/settings/runners`), then:

```yaml
runs-on: self-hosted
```

Inside the job, the vm already has:
`AWS_ENDPOINT_URL=http://host.docker.internal:4566`, IMDS creds, `awscli`,
`LOCALEMU_INSTANCE_ID` / `LOCALEMU_INSTANCE_TYPE` env, and (with the IGW)
egress to `github.com` / `api.github.com`.

```bash
curl -sS -m 5 -H 'Accept: text/plain' http://169.254.169.254/latest/meta-data/instance-id
```

Install OpenTofu in the job (no apt on the AMI):

```bash
curl -fsSL -o /tmp/tofu.tgz https://github.com/opentofu/opentofu/releases/download/v1.13.2/tofu_1.13.2_linux_amd64.tar.gz
tar -xzf /tmp/tofu.tgz -C /tmp/tofu-bin && mv "$(find /tmp/tofu-bin -name tofu)" /usr/local/bin/tofu
```

`boto3` is **not** on the AMI — `python3 -m pip install boto3 botocore s3transfer`
before any boto3 tool.

### 4.2 Two stages = two boxes

A single Actions run **cannot pause and wait for a human** (no "hold this job
until approved" primitive). Two jobs in one file render as one box, the gated
one showing `Skipped`. So the supported shape is **two workflow files**:

```
.github/workflows/1-plan.yml    stage 1: plan, ends, writes nothing
.github/workflows/2-deploy.yml  stage 2: separate box, only exists when you dispatch it
```

```yaml
# 1-plan.yml
on: workflow_dispatch: {}

# 2-deploy.yml
on:
  workflow_dispatch:
    inputs:
      approve: { type: string, required: true }
jobs:
  deploy:
    steps:
      - name: Approval gate
        run: |
          if [ "${{ github.event.inputs.approve }}" != "DEPLOY" ]; then
            echo "not approved — nothing touched."; exit 1; fi
```

```bash
gh workflow run 1-plan.yml   -R <owner>/<repo>
gh workflow run 2-deploy.yml -R <owner>/<repo> -f approve=DEPLOY
```

**Do not add a `push:` trigger** — it fires a second, confusing run.

### 4.3 Credentials: secrets, never inline `export`

```yaml
env:
  AWS_ACCESS_KEY_ID:     ${{ secrets.AWS_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```
```bash
gh secret set AWS_ACCESS_KEY_ID < <(grep AWS_ACCESS_KEY_ID secrets.env | cut -d= -f2)
```
GitHub prints `***` for secret values in the log. Inline `export AWS_…=…` in a
script body **is** echoed into the log (the log shows the script text and each
step's `env:` block).

### 4.4 Log hygiene (the "messed up font")

OpenTofu emits ANSI even when not a tty; the log then shows `?[32m` garbage.

```yaml
env: { NO_COLOR: "1", TOFU_DISABLE_COLOR: "1" }
```
```bash
tofu plan … | sed -r 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tee /tmp/plan.txt
```
Print the **whole** plan (`cat /tmp/plan.txt`), not `tail -40` — GitHub shows
the full step output in the job log. `tofu 1.13.2` has no `--summary` flag;
write markdown to `$GITHUB_STEP_SUMMARY` yourself.

Fetch a job log locally (the web UI needs JS):

```bash
RID=$(gh api "repos/<owner>/<repo>/actions/runs" --jq '.total_count')
J=$(gh api "repos/<owner>/<repo>/actions/runs/<id>/jobs" --jq '.jobs[0].id')
curl -sSL -H "Authorization: Bearer $(gh auth token)" \
  "https://api.github.com/repos/<owner>/<repo>/actions/jobs/$J/logs"
```

---

## 5. Persistent state in an S3 bucket (not in git)

```hcl
resource "aws_s3_bucket" state_store { name = "localemu-tf-state" }
resource "aws_s3_object" state_marker { bucket_expression = …, key = "state/README.txt" }
```

CI order:
```bash
aws s3 cp s3://localemu-tf-state/state/aws_test.tfstate terraform.tfstate || echo "fresh"
tofu plan  …            # or tofu apply
tofu apply …
aws s3 cp terraform.tfstate       s3://localemu-tf-state/state/aws_test.tfstate
aws s3 cp terraform.tfstate.backup s3://localemu-tf-state/state/aws_test.tfstate.backup
```
`.gitignore` keeps `*.tfstate*` out of the repo. This also makes re-`apply`
idempotent (no `BucketAlreadyExists`) and survives a wiped emulator.

---

## 6. vm → S3 copy (the actual payload path)

```bash
mkdir -p /tmp/vm-outbox
{ echo "hello from the runner vm"; echo "instance_id=${LOCALEMU_INSTANCE_ID}"; } > /tmp/vm-outbox/from-action.txt
aws s3 cp /tmp/vm-outbox/from-action.txt s3://localemu-runner-logs/runner/from-vm/from-action.txt
aws s3api put-object --bucket localemu-runner-logs --key "runner/from-vm/"   # folder object
# verify byte-for-byte
sha256sum /tmp/vm-outbox/x.txt
aws s3 cp s3://localemu-runner-logs/runner/from-vm/x.txt - | sha256sum
```

---

## 7. Gotchas (all hit in this repo)

| symptom | cause / fix |
|---|---|
| `BucketAlreadyExists` | no `exist_ok` in aws 6.70.0 — clean up or keep state |
| `flag provided but not defined: -summary` | tofu 1.13.2 has no `--summary`; use `$GITHUB_STEP_SUMMARY` |
| `?[32m` garbage in logs | strip ANSI (`NO_COLOR`, `TOFU_DISABLE_COLOR`, `sed`) |
| creds visible in log | inline `export` is echoed; use `env:` + `gh secret set` |
| `cd github_runner: No such file or directory` | missing `actions/checkout@v4` step |
| `cp: cannot stat '../data/…'` | workspace root is the repo root; use `data/…` |
| `python3 tools/vm-inspect.py` traceback | no `boto3` on the AMI → pip install it; guard `docker ps` (no docker client in vm) |
| vm cannot reach `api.github.com` | add `aws_internet_gateway` (drops `--internal` on the net) |
| `run: {target: …}` → HTTP 422 | that feature is not available on this account; use `runs-on: self-hosted` |
| two runs per change | a `push:` trigger plus a manual one — keep `workflow_dispatch` only |
| stopped `i-…` records never disappear | LocalEmu has **no** `DeleteInstances`/`DeleteVpcs`/`DeleteSubnets`; orphan `igw-…` hit `DependencyViolation`. Restart the emulator for a clean slate |
| `gh` 403 "denied … denied to mpkac" | stale git creds; re-auth (`gh auth login`, device flow) |
| folder typo `Gtihub_repo` | rename hit a `Permission denied` busy dir — cosmetic, path kept |

---

## 8. Verification loop (paste this at the end of every stage)

```bash
aws s3 ls --recursive s3://localemu-runner-logs/runner/
aws s3 ls s3://localemu-tf-state/state/
python3 tools/vm-inspect.py --bucket localemu-runner-logs --prefix runner/ --instance "$IID"
gh api "repos/<owner>/<repo>/actions/runs" --jq '.workflow_runs[:3][]|"run \(.number) \(.status) \(.conclusion)"'
gh api "repos/<owner>/<repo>/actions/runs/<id>/jobs" --jq '.jobs[]|"\(.name) \(.conclusion)"'
```

Expect: buckets present, objects with real byte counts, one `running` instance
(the runner), plan/apply jobs `completed success`, secrets `***` in logs.

---

## 9. Restarting the emulator (cold start) — what survives and what does not

Verified on this repo (2026-10-23): stopping LocalEmu + `docker stop` on the vm
container took the GitHub runner **offline**, and a fresh emulator starts with
**no buckets, no EC2 records, no tfstate**. Nothing "re-registers" itself.

```bash
# 1. stop the emulator (localemu stop is broken on Windows)
PID=$(netstat -ano | grep LISTENING | grep 4566 | awk '{print $NF}' | head -1)
taskkill //PID $PID //F
docker stop <localemu-ec2-i-…>            # the vm container = the runner
# → gh api repos/<o>/<r>/actions/runners  ⇒  status: offline   (jobs can no longer run)

# 2. start it again — UTF-8 is REQUIRED on a Windows console (Unicode banner crash)
PYTHONUTF8=1 PYTHONIOENCODING=utf-8 localemu start --port 4566 > emu.log 2>&1 &
curl -s http://localhost:4566/_health     # fresh gateway (S3 says NoSuchBucket = clean)

# 3. rebuild the vm from the HOST (no runner exists to run CI)
set -a; source secrets.env; set +a
export AWS_ENDPOINT_URL=http://localhost:4566
cd github_runner && rm -f terraform.tfstate* .terraform.lock.hcl
tofu init && tofu apply --auto-approve -var gateway_host=localhost
aws s3 cp terraform.tfstate s3://<state-bucket>/state/<project>.tfstate

# 4. re-register the new container as a self-hosted runner
CID=$(docker ps --filter name=localemu-ec2 --format "{{.ID}}" | head -1)
TOK=$(gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token)
docker exec -d $CID bash -c "cd /runner
  curl -fsSL -o /tmp/r.tgz https://github.com/actions/runner/releases/download/v2.338.0/actions-runner-linux-x64-2.338.0.tar.gz
  tar -xzf /tmp/r.tgz -C /runner
  export RUNNER_ALLOW_RUNASROOT=1          # the AMI runs the vm as root
  ./config.sh --url https://github.com/<owner>/<repo> --token $TOK
  nohup ./run.sh > /runner/runner.log 2>&1 &"
# → gh api repos/<o>/<r>/actions/runners ⇒ <CID> online ; "Listening for Jobs"
```

Rules learned:
* `bin/Runner.Listener` alone says *"Not configured"* — you must run **`config.sh`
  first** (`--url … --token …`), then **`run.sh`** with no args.
* `run.sh`/`config.sh` refuse to run as root unless **`RUNNER_ALLOW_RUNASROOT=1`**.
* Git-Bash mangles `/runner/…` paths inside `docker exec` → prefix with
  `MSYS_NO_PATHCONV=1`.
* After a cold start the inventory shows **one** instance (`current`), all the
  old orphan `i-…`/`vpc-…` records are gone — that is the only way to get a tidy
  graph.
* The state bucket is wiped with the emulator: re-push `terraform.tfstate` right
  after the fresh `apply`, otherwise the next plan re-creates everything.
