variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "k8s"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3a.medium"
}

variable "node_count" {
  description = "Number of EC2 instances"
  type        = number
  default     = 3
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "admin_cidr" {
  description = "CIDR block allowed to SSH and access kube-apiserver"
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key for Ansible"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "root_volume_size" {
  description = "Root EBS volume size (GB)"
  type        = number
  default     = 20
}
