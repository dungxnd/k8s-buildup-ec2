output "instance_ids" {
  description = "List of EC2 instance IDs"
  value       = aws_instance.k8s[*].id
}

output "instance_public_ips" {
  description = "List of public IPs"
  value       = aws_instance.k8s[*].public_ip
}

output "instance_private_ips" {
  description = "List of private IPs"
  value       = aws_instance.k8s[*].private_ip
}

output "security_group_id" {
  description = "Security Group ID"
  value       = aws_security_group.k8s.id
}

output "master_ip" {
  description = "Master node public IP (first instance)"
  value       = aws_instance.k8s[0].public_ip
}
