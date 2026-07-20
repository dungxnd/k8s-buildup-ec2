# Taste (Continuously Learned by [CommandCode][cmd])

[cmd]: https://commandcode.ai/

# terraform
- Place Terraform files in a /terraform directory. Confidence: 0.65
- Use spot instances (aws_spot_instance_request) instead of on-demand (aws_instance) for EC2 resources. Confidence: 0.60
- Prefer data sources (e.g., data.aws_vpc, data.aws_subnets) to auto-discover AWS resources instead of requiring manual variable input. Confidence: 0.60

