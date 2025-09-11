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

# EC2 instance resource
resource "aws_instance" "runner_instance" {
  ami           = "ami-04f59c565deeb2199" 
  instance_type = var.instance_type
  key_name      = var.key_name

  tags = {
    Name = "Amith_instance"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = var.private_key_content
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

# S3 bucket for Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = var.s3_bucket_name
  acl    = "private"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "cleanup-old-versions"
    enabled = true

    noncurrent_version_expiration {
      days = 30
    }
  }

  tags = {
    Name        = "Terraform State Bucket"
    Environment = "Production"
  }
}

# DynamoDB table for state locking
resource "aws_dynamodb_table" "terraform_locks" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "Terraform Locks Table"
    Environment = "Production"
  }
}

output "instance_public_ip" {
  value       = aws_instance.runner_instance.public_ip
  description = "The public IP address of the EC2 instance."
}
