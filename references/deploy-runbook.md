# Deploy Runbook (Sandbox First)

## Prerequisites
- AWS CLI authenticated to target account/role
- SSM-managed EC2 instance id available for host bootstrap
- SecureString SSM parameters created:
  - gateway token (required)
  - telegram bot token (optional)

## Recommended first run
```bash
scripts/run_e2e.sh \
  --region us-east-1 \
  --host i-xxxxxxxx \
  --project openclaw \
  --environment sandbox \
  --cost-mode prod-baseline \
  --model-profile cheap \
  --gateway-token-ssm /openclaw/sandbox/gateway-token \
  --telegram-bot-token-ssm /openclaw/sandbox/telegram-token \
  --output-dir out/sandbox
```

## Outputs
- `preflight-report.json`
- `deployment-plan.json`
- `deploy-infra-output.json`
- `smoke-test-report.json`
- `deployment-summary.json`

## Failure handling
- Fix preflight issues first, never skip.
- For CloudFormation failures, inspect stack events.
- For bootstrap/config failures, inspect SSM command output.
- Re-run only from the failed stage when practical.
