output "instance_public_ip" {
  description = "Public IP address of the created EC2 instance."
  value       = aws_instance.runner_instance.public_ip
}
