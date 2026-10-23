region        = "us-east-1"
gateway_host  = "localhost"
gateway_port  = 4566
bucket_name   = "localemu-vm-drop"
vm_prefix     = "vm"
ami           = "ami-ubuntu-22.04" # -> localemu/ec2-base:v4 (awscli + sshd baked in)
instance_type = "t2.micro"         # 1 GB docker memory limit (t2.nano = 512 MB)
vpc_cidr      = "10.0.0.0/16"
subnet_cidr   = "10.0.1.0/24"
