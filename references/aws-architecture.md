# AWS Architecture (v1)

- VPC across 2 AZs
- Public subnets: ALB
- Private subnet: EC2 running OpenClaw
- EBS for runtime persistence
- WAF attached to ALB
- ACM TLS certificate
