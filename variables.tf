variable "aws_region" {
  description = "The AWS region to deploy in."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "The EC2 instance type."
  type        = string
  default     = "t2.medium"
}

variable "key_name" {
  description = "The name of the pre-existing SSH key pair in AWS."
  type        = string
  default     = "amithnv"
}


variable "private_key_content" {
  description = "The content of the private key for SSH access."
  type        = string
  sensitive   = true # Marks the variable as sensitive to prevent it from being displayed in logs.
}
