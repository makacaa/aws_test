# ==============================================================================
# localemu-vm-s3 — Terraform / OpenTofu project
#
#   Target    : LocalEmu (free, open-source AWS emulator, pip install localemu)
#               running on this machine at http://localhost:4566
#   Services  : EC2 (a real, docker-backed "tiny vm") + S3 bucket
#   Test      : write files INSIDE the vm, then copy them UP to s3://…/vm/
#
#   Unlike the LocalStack project next door (aws-local-test), LocalEmu's EC2
#   emulator is real by default (EC2_VM_MANAGER=docker): aws_instance launches
#   a real Docker container on a real VPC network, so the vm scripts below are
#   plain `docker exec` into that container and the awscli baked into the AMI
#   does a real `aws s3 cp` against the emulator gateway.
#
#   Run from the host :  ./deploy.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# Provider pin — keeps the aws module version identical on every machine (the
# OpenTofu registry serves different versions to different tofu releases).
# ------------------------------------------------------------------------------
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

# ------------------------------------------------------------------------------
# Knobs (values live in terraform.tfvars, auto-loaded by tofu/terraform)
# ------------------------------------------------------------------------------
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "gateway_host" {
  description = "LocalEmu gateway host (all 133 services share one port)"
  type        = string
  default     = "localhost"
}

variable "gateway_port" {
  description = "LocalEmu gateway port"
  default     = 4566
}

variable "bucket_name" {
  type    = string
  default = "localemu-vm-drop"
}

variable "vm_prefix" {
  description = "S3 folder (prefix) the vm drops its files into"
  type        = string
  default     = "vm"
}

variable "ami" {
  description = <<-EOT
    AMI id -> docker image, per LocalEmu's built-in ami_mapping.py.
    ami-ubuntu-22.04 = localemu/ec2-base:v4: sshd + iptables + curl + awscli
    baked in, which is what the vm scripts need. Unknown ids fall back to it.
  EOT
  type        = string
  default     = "ami-ubuntu-22.04"
}

variable "instance_type" {
  description = "t2.nano = 512 MB, t2.micro = 1 GB (docker memory limit)"
  type        = string
  default     = "t2.micro"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "host_cidrs" {
  description = <<-EOT
    Extra egress/ingress targets outside the VPC. LocalEmu's gateway lives on
    the emulated host, reached from the vm through Docker's host gateway
    (host.docker.internal), so a public/internet-facing vm needs it admitted.
    0.0.0.0/0 = "internet-facing" in AWS terms; narrow it to the host gateway
    CIDR if you want the stricter NAT-only shape.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ------------------------------------------------------------------------------
# Derived coordinates
# ------------------------------------------------------------------------------
locals {
  gateway = "http://${var.gateway_host}:${var.gateway_port}"

  # path style: the bucket name lives in the URL path, not a subdomain
  bucket_path_url = "${local.gateway}/${var.bucket_name}/"
  s3_root         = "s3://${var.bucket_name}/${var.vm_prefix}/"

  folder_key    = "${var.vm_prefix}/"
  manifest_key  = "${var.vm_prefix}/tf-manifest.json"
  vm_outbox     = "/vm-outbox" # where the vm writes its files before uploading

  # LocalEmu names the instance's docker container localemu-ec2-<instance-id>
  vm_container = "localemu-ec2-${aws_instance.vm.id}"
}

# ------------------------------------------------------------------------------
# Provider -> LocalEmu gateway
# ------------------------------------------------------------------------------
provider "aws" {
  region      = var.region
  # credentials come from the environment (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY):
  #   CI  -> GitHub secrets (see .github/workflows/1-plan.yml)
  #   host-> source secrets.env (see secrets.example.env)

  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = local.gateway
    s3  = local.gateway
    sts = local.gateway
  }
}

# ------------------------------------------------------------------------------
# 0. the tiny vm: real VPC + subnet + security group + docker-backed instance
# ------------------------------------------------------------------------------
resource "aws_vpc" "emu" {
  cidr_block = var.vpc_cidr
  tags       = { Name = "${var.bucket_name}-vpc" }
}

resource "aws_subnet" "emu" {
  vpc_id            = aws_vpc.emu.id
  cidr_block        = var.subnet_cidr
  availability_zone = "${var.region}a"
  tags              = { Name = "${var.bucket_name}-subnet" }
}

# internet-facing (public) subnet: egress is what lets the vm's packets reach
# the emulator gateway. LocalEmu compiles these rules to real iptables chains
# inside the instance container, so a too-tight egress rule shows up as a
# connection timeout from inside the vm, not a silent pass.
resource "aws_security_group" "vm" {
  name        = "${var.bucket_name}-ec2-sg"
  description = "public subnet egress for the tiny local vm"
  vpc_id      = aws_vpc.emu.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = concat([var.vpc_cidr], var.host_cidrs)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = concat([var.vpc_cidr], var.host_cidrs)
  }
}

resource "aws_instance" "vm" {
  ami                    = var.ami
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.emu.id
  vpc_security_group_ids = [aws_security_group.vm.id]

  tags = {
    Name   = "tiny-vm"
    region = var.region
    gateway = local.gateway
  }
}

# ------------------------------------------------------------------------------
# 1. the S3 bucket the vm copies its files into
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "dropbox" {
  bucket = var.bucket_name
}

# ------------------------------------------------------------------------------
# 2. the vm folder (S3 has no directories: a folder = zero-byte key "vm/")
# ------------------------------------------------------------------------------
resource "aws_s3_object" "folder" {
  bucket  = aws_s3_bucket.dropbox.bucket
  key     = local.folder_key
  content = ""
}

# ------------------------------------------------------------------------------
# 3. what the vm is, as seen by terraform (the vm then reads this from inside)
# ------------------------------------------------------------------------------
resource "aws_s3_object" "tf_manifest" {
  bucket = aws_s3_bucket.dropbox.bucket
  key    = local.manifest_key
  content = jsonencode({
    gateway         = local.gateway
    bucket          = var.bucket_name
    prefix          = var.vm_prefix
    s3_root         = local.s3_root
    region          = var.region
    ec2_instance_id = aws_instance.vm.id
    private_ip      = aws_instance.vm.private_ip
    vm_container    = local.vm_container
    ami             = var.ami
    instance_type   = var.instance_type
    subnet_id       = aws_subnet.emu.id
    vpc_id          = aws_vpc.emu.id
    security_group  = aws_security_group.vm.id
  })
}

# ------------------------------------------------------------------------------
# Echo the coordinates so deploy.sh / the vm scripts can consume them
# ------------------------------------------------------------------------------
output "gateway" {
  value = local.gateway
}

output "s3_root" {
  value = local.s3_root
}

output "bucket_path_url" {
  value = local.bucket_path_url
}

output "ec2_instance_id" {
  value = aws_instance.vm.id
}

output "ec2_private_ip" {
  value = aws_instance.vm.private_ip
}

output "vm_container" {
  value = local.vm_container
}
