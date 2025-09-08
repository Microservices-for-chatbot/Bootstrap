terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_key_pair" "ssh_key" {
  key_name   = "my-runner-key"
  public_key = var.public_key
}

resource "aws_instance" "runner_instance" {
  ami           = "ami-0c55b159cbfafe1f0" # Use a valid Ubuntu AMI ID for your region
  instance_type = var.instance_type
  key_name      = aws_key_pair.ssh_key.key_name

  tags = {
    Name = "Temporary-Kubernetes-Installer"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = var.private_key
    host        = self.public_ip
  }

  provisioner "file" {
    source      = "setup-cluster.sh"
    destination = "/home/ubuntu/setup-cluster.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x /home/ubuntu/setup-cluster.sh",
      "sudo /home/ubuntu/setup-cluster.sh"
    ]
  }
}
