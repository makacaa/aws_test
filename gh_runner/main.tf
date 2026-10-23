# ==============================================================================
# gh_runner/main.tf — the CI-tuned twin of ../main.tf
#
#   Same shape (VPC + subnet + SG + tiny vm + bucket) but built so it also
#   works on a GitHub Actions runner, where the vm's network is a plain Linux
#   Docker network instead of Docker Desktop's:
#
#     1. an Internet Gateway is attached to the VPC. LocalEmu creates VPC
#        Docker networks as --internal (no host egress); AttachInternetGateway
#        recreates it WITHOUT --internal, which is what gives the vm a route
#        out to the emulator gateway on a Linux daemon.
#     2. the security group admits egress everywhere (internet-facing subnet),
#        because LocalEmu compiles SG rules to real iptables chains inside the
#        instance container and a tight egress rule shows up as a connection
#        timeout from inside the vm.
#     3. its own bucket (localemu-gh-runner) so a CI deploy never fights the
#        local ../aws_test deploy.
#
#   Deployed by .github/workflows/deploy.yml against LocalEmu on the runner.
#   Nothing here touches real AWS: no account, no token, endpoint is
#   localhost:4566 on the runner.
# ==============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "gateway_host" {
  description = "LocalEmu gateway host on the runner (localhost:4566)"
  type        = string
  default     = "localhost"
}

variable "gateway_port" {
  description = "LocalEmu gateway port"
  default     = 4566
}

variable "bucket_name" {
  type    = string
  default = "localemu-gh-runner"
}

variable "vm_prefix" {
  type    = string
  default = "vm"
}

variable "ami" {
  description = "AMI -> docker image (localemu/ec2-base:v4: sshd, iptables, curl, awscli)"
  type        = string
  default     = "ami-ubuntu-22.04"
}

variable "instance_type" {
  description = "t2.nano = 512 MB, t2.micro = 1 GB docker memory limit"
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
  description = "egress/ingress outside the VPC: the emulator host gateway"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

locals {
  gateway         = "http://${var.gateway_host}:${var.gateway_port}"
  bucket_path_url = "${local.gateway}/${var.bucket_name}/"
  s3_root         = "s3://${var.bucket_name}/${var.vm_prefix}/"
  folder_key      = "${var.vm_prefix}/"
  manifest_key    = "${var.vm_prefix}/tf-manifest.json"
  vm_container    = "localemu-ec2-${aws_instance.vm.id}"
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
# 0. the tiny vm: VPC + Internet Gateway (egress) + subnet + SG + instance
# ------------------------------------------------------------------------------
resource "aws_vpc" "runner" {
  cidr_block = var.vpc_cidr
  tags       = { Name = "${var.bucket_name}-vpc" }
}

# The internet gateway is what makes the VPC's Docker network non-internal,
# i.e. what lets the vm's packets leave the VPC at all.
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.runner.id
  tags   = { Name = "${var.bucket_name}-igw" }
}

resource "aws_subnet" "runner" {
  vpc_id            = aws_vpc.runner.id
  cidr_block        = var.subnet_cidr
  availability_zone = "${var.region}a"
  tags              = { Name = "${var.bucket_name}-subnet" }
}

resource "aws_security_group" "vm" {
  name        = "${var.bucket_name}-ec2-sg"
  description = "internet-facing egress for the tiny runner vm"
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
  vpc_security_group_ids = [aws_security_group.vm.id]

  # the internet gateway has to exist before the container is launched, so the
  # VPC network is already non-internal when the vm boots
  depends_on = [aws_internet_gateway.igw]

  tags = {
    Name    = "tiny-runner-vm"
    region  = var.region
    gateway = local.gateway
  }
}

# ------------------------------------------------------------------------------
# 1. the bucket + 2. the vm folder + 3. the manifest the vm reads
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "dropbox" {
  bucket = var.bucket_name
}

resource "aws_s3_object" "folder" {
  bucket  = aws_s3_bucket.dropbox.bucket
  key     = local.folder_key
  content = ""
}

resource "aws_s3_object" "tf_manifest" {
  bucket = aws_s3_bucket.dropbox.bucket
  key    = local.manifest_key
  content = jsonencode({
    region          = var.region
    gateway         = local.gateway
    bucket          = var.bucket_name
    prefix          = var.vm_prefix
    s3_root         = local.s3_root
    ec2_instance_id = aws_instance.vm.id
    private_ip      = aws_instance.vm.private_ip
    vm_container    = local.vm_container
    igw_id          = aws_internet_gateway.igw.id
    subnet_id       = aws_subnet.runner.id
    vpc_id          = aws_vpc.runner.id
    security_group  = aws_security_group.vm.id
    ami             = var.ami
    instance_type   = var.instance_type
    ci              = true
  })
}

output "gateway" {
  value = local.gateway
}

output "s3_root" {
  value = local.s3_root
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
