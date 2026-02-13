---
name: openclaw-aws-deploy
description: Deploy OpenClaw securely on AWS using AWS CLI and infrastructure templates. Use when setting up OpenClaw in AWS with VPC, ALB, WAF, EC2/EBS, TLS, auth, smoke tests, and channel/model bootstrap.
---

# OpenClaw AWS Deploy Skill

## Workflow
1. Run `scripts/preflight.sh` to validate AWS credentials, region, required CLIs, and required inputs.
2. Run `scripts/plan.sh` to generate stack names, topology choices, and deployment profile.
3. Run `scripts/deploy_infra.sh` to provision/update AWS infrastructure.
4. Run `scripts/bootstrap_host.sh` to install and start OpenClaw on EC2.
5. Run `scripts/configure_openclaw.sh` to apply model/channel config.
6. Run `scripts/smoke_test.sh` to validate health/auth/end-to-end.
7. Run `scripts/collect_outputs.sh` to produce deployment summary.

## Safety rules
- Never print secrets in logs.
- Never open SSH to the world; use SSM Session Manager.
- Require TLS on ALB.
- Require least-privilege IAM policies.

## Profiles
- `dev-low-cost`
- `prod-baseline`

See references:
- `references/aws-architecture.md`
- `references/security-baseline.md`
- `references/channels.md`
- `references/model-profiles.md`


## Infrastructure engine
- `scripts/deploy_infra.sh` deploys CloudFormation templates in `assets/cloudformation/` (network, app, waf).
- Deployment is idempotent via `aws cloudformation deploy`.
