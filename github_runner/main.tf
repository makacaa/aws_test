# ==============================================================================
# github_runner/main.tf — the tiny vm that becomes a GitHub SELF-HOSTED RUNNER
#
#   LocalEmu's EC2 backend launches a REAL Docker container for aws_instance, so
#   the "vm" is a real Ubuntu 22.04 box on this machine. Terraform talks to the
#   local AWS emulator (localhost:4566); the runner inside the vm talks to real
#   github.com over the internet — that is the whole point of an internet-facing
#   (public) subnet: egress is admitted, so the vm can reach both.
#
#   Jump in with:   localemu ssh <instance-id>     (LocalEmu's docker-exec shim)
#                   or  ./vm/jump-in.sh
#   Then install/start the runner with vm/install-runner.sh (see README-runner.md)
#
#   Name tag = github_runner  →  docker container localemu-ec2-<i-…>
# ==============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

variable "vm_name" {
  description = "name of the tiny vm (becomes the runner host)"
  type        = string
  default     = "github_runner"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "gateway_host" {
  type    = string
  default     = "localhost"
}

variable "gateway_port" {
  description = "LocalEmu gateway port"
  default = 4566
}

variable "bucket_name" {
  description = "bucket the runner writes its job logs into (local AWS)"
  type        = string
  default     = "localemu-runner-logs"
}

variable "log_prefix" {
  type    = string
  default = "runner"
}

variable "ami" {
  description = "ami-ubuntu-22.04 -> localemu/ec2-base:v4 (curl, awscli, sshd, iptables)"
  type        = string
  default     = "ami-ubuntu-22.04"
}

variable "instance_type" {
  description = "runner wants >= 2 GB; t2.medium = 4 GB docker memory limit"
  type        = string
  default     = "t2.medium"
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
  description = "internet-facing egress: the vm must reach github.com AND the local emulator"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

locals {
  gateway         = "http://${var.gateway_host}:${var.gateway_port}"
  bucket_path_url = "${local.gateway}/${var.bucket_name}/"
  s3_root         = "s3://${var.bucket_name}/${var.log_prefix}/"
  folder_key      = "${var.log_prefix}/"
  manifest_key    = "${var.log_prefix}/runner-manifest.json"
  vm_container    = "localemu-ec2-${aws_instance.vm.id}"
  runner_home     = "/runner"
}

provider "aws" {
  region      = var.region
  access_key  = "AKIAIOSFODNN7EXAMPLE"
  secret_key  = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

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
# 0. the vm: VPC + Internet Gateway (egress to the internet) + subnet + SG
# ------------------------------------------------------------------------------
resource "aws_vpc" "runner" {
  cidr_block = var.vpc_cidr
  tags       = { Name = "${var.vm_name}-vpc" }
}

# without this the VPC's Docker network is --internal and the vm cannot reach
# github.com (or the emulator host) at all
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.runner.id
  tags   = { Name = "${var.vm_name}-igw" }
}

resource "aws_subnet" "runner" {
  vpc_id            = aws_vpc.runner.id
  cidr_block        = var.subnet_cidr
  availability_zone = "${var.region}a"
  tags              = { Name = "${var.vm_name}-subnet" }
}

resource "aws_security_group" "runner" {
  name        = "${var.vm_name}-sg"
  description = "internet-facing: https to github.com + egress to the emulator"
  vpc_id      = aws_vpc.runner.id

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
  subnet_id              = aws_subnet.runner.id
  vpc_security_group_ids = [aws_security_group.runner.id]

  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name    = var.vm_name
    role    = "github-self-hosted-runner"
    region  = var.region
    gateway = local.gateway
  }
}

# ------------------------------------------------------------------------------
# 1. the local-AWS bucket the runner posts its job logs to
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "runner_logs" {
  bucket = var.bucket_name
}

resource "aws_s3_object" "folder" {
  bucket  = aws_s3_bucket.runner_logs.bucket
  key     = local.folder_key
  content = ""
}

resource "aws_s3_object" "runner_manifest" {
  bucket = aws_s3_bucket.runner_logs.bucket
  key    = local.manifest_key
  content = jsonencode({
    vm_name         = var.vm_name
    ec2_instance_id = aws_instance.vm.id
    private_ip      = aws_instance.vm.private_ip
    vm_container    = local.vm_container
    runner_home     = local.runner_home
    igw_id          = aws_internet_gateway.igw.id
    subnet_id       = aws_subnet.runner.id
    vpc_id          = aws_vpc.runner.id
    security_group  = aws_security_group.runner.id
    gateway         = local.gateway
    bucket          = var.bucket_name
    log_prefix      = var.log_prefix
    ami             = var.ami
    instance_type   = var.instance_type
  })
}

output "vm_name" {
  value = var.vm_name
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

output "igw_id" {
  value = aws_internet_gateway.igw.id
}

output "s3_root" {
  value = local.s3_root
}
