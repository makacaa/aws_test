vm_name        = "github_runner"
region         = "us-east-1"
gateway_host   = "localhost"
gateway_port   = 4566
bucket_name    = "localemu-runner-logs"
log_prefix     = "runner"
ami            = "ami-ubuntu-22.04" # -> localemu/ec2-base:v4 (curl + awscli baked in)
instance_type  = "t2.medium"        # 4 GB docker memory limit (runner wants >= 2 GB)
vpc_cidr       = "10.0.0.0/16"
subnet_cidr    = "10.0.1.0/24"
host_cidrs     = ["0.0.0.0/0"]      # internet-facing: github.com + the emulator
