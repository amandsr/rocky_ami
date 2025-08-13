packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

variable "aws_region" {
  default = "us-east-1"
}

variable "ami_name" {
  default = "rocky-custom-ami"
}

source "amazon-ebs" "rocky" {
  region                  = var.aws_region
  instance_type           = "t3.micro"
  ssh_username            = "rocky"
  #key_pair_name           = "ubuntu"
  #ssh_private_key_file    = "~/.ssh/ubuntu.pem"
  ami_name                = "${var.ami_name}-${formatdate("20060102-150405", timestamp())}"
  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "Rocky-9-EC2-Base-9.5-20241118.0.x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["792107900819"]
    most_recent = true
  }
}

build {
  name    = "rocky-linux-ami"
  sources = ["source.amazon-ebs.rocky"]

  provisioner "ansible" {
    playbook_file = "playbook.yml"
    extra_arguments = ["--extra-vars", "ansible_user=ec2-user"]
  }
}
