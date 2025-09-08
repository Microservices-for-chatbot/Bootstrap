terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # Or your desired AWS region
}

resource "aws_instance" "runner_instance" {
  ami           = "ami-0c55b159cbfafe1f0" # Example AMI for Ubuntu 24.04, find the right one for your region
  instance_type = "t2.micro"
  key_name      = "your-ssh-key-name" # Replace with your SSH key pair name

  user_data = <<-EOT
    #!/bin/bash
    sudo apt-get update -y
    sudo apt-get install -y git
    
    # Clone your repository
    git clone https://github.com/your-username/your-repo-name.git /home/ubuntu/repo
    
    # Change to the repository directory
    cd /home/ubuntu/repo
    
    # Make the setup script executable and run it
    sudo chmod +x ./setup-cluster.sh
    ./setup-cluster.sh
  EOT

  tags = {
    Name = "Temporary-Kubernetes-Installer"
  }
}
