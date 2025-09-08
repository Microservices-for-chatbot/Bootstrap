variable "aws_region" {
  description = "The AWS region to deploy in."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "The EC2 instance type."
  type        = string
  default     = "t2.micro"
}

variable "public_key" {
  description = "The public key for SSH access."
  type        = string
}

variable "private_key" {
  description = "The private key for SSH access."
  type        = string
  sensitive   = true
}
