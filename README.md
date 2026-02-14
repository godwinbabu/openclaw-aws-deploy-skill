# openclaw-aws-deploy

**One-shot OpenClaw deployment to AWS** — VPC, EC2, Telegram, Gemini Flash, all in one command.

[![ClawHub](https://img.shields.io/badge/ClawHub-openclaw--aws--deploy-blue)](https://clawhub.ai)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## What It Does

Deploys a fully working OpenClaw agent to AWS with a single command:

```
┌─────────────────────────────────────────────────────┐
│                    VPC (isolated)                    │
│  ┌───────────────────────────────────────────────┐  │
│  │      EC2 t4g.medium (ARM64, 4GB, encrypted)   │  │
│  │  ┌───────────────────────────────────────────┐│  │
│  │  │         OpenClaw Gateway                  ││  │
│  │  │  • Gemini 2.0 Flash (free tier)           ││  │
│  │  │  • Telegram channel                       ││  │
│  │  │  • Node.js 22 + systemd                   ││  │
│  │  └───────────────────────────────────────────┘│  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
         ↑                              ↓
    SSM only (no SSH)         Outbound HTTPS only
```

**Cost:** ~$30/month (t4g.medium + EBS + public IP). Gemini Flash free tier included.

## Quick Start

### 1. Create credential files

In your OpenClaw workspace (never committed to git):

```bash
# .env.aws
AWS_ACCESS_KEY_ID=your-key
AWS_SECRET_ACCESS_KEY=your-secret
AWS_DEFAULT_REGION=us-east-1

# .env.starfish
TELEGRAM_BOT_TOKEN=from-botfather
GEMINI_API_KEY=from-aistudio.google.com
```

### 2. Deploy

```bash
./scripts/deploy_minimal.sh --name my-agent --region us-east-1 \
  --env-dir /path/to/workspace
```

### 3. Pair Telegram

Message your bot → get pairing code → approve via SSM:

```bash
aws ssm start-session --target <INSTANCE_ID> --region us-east-1
# Then:
sudo -u openclaw bash -c "export HOME=/home/openclaw; openclaw pairing approve telegram <CODE>"
```

### 4. Teardown (when done)

```bash
./scripts/teardown.sh --from-output ./deploy-output.json \
  --env-dir /path/to/workspace --yes
```

## Security

| Feature | Detail |
|---------|--------|
| **No SSH** | SSM Session Manager only — zero inbound ports |
| **No secrets in code** | All credentials in SSM Parameter Store (encrypted) |
| **Encrypted storage** | EBS volumes use AES-256 encryption |
| **IMDSv2 enforced** | Instance metadata requires session tokens |
| **Minimal IAM** | Only SSM + Parameter Store read access |
| **Secure env parsing** | Credential files parsed as key=value, not `source`d |
| **Tagged resources** | All resources tagged for deterministic cleanup |
| **Node integrity** | SHA256 verification on Node.js tarball |
| **Retry with backoff** | Network operations retry on transient failures |
| **Failure cleanup** | Mid-deploy failures print deterministic teardown commands |

### Credential files

`.env.aws` and `.env.starfish` must live **outside** the skill directory and are `.gitignore`d. They are parsed as strict `KEY=VALUE` — no shell execution.

## What Gets Created

| Resource | Purpose | Cost |
|----------|---------|------|
| VPC + subnet + IGW | Isolated network | Free |
| Security group | No inbound rules | Free |
| IAM role + profile | SSM + Parameter Store access | Free |
| SSM parameters (3) | Encrypted secret storage | Free |
| EC2 t4g.medium | OpenClaw host (ARM64, 4GB) | ~$24.53/mo |
| EBS gp3 20GB | Encrypted root volume | ~$1.60/mo |
| Public IP | Outbound connectivity | ~$3.65/mo |
| **Total** | | **~$29.78/mo** |

## Files

```
scripts/
  deploy_minimal.sh    ← One-shot deploy (start here)
  teardown.sh          ← Clean removal of all resources
  preflight.sh         ← Validate AWS credentials
  smoke_test.sh        ← Post-deploy health check

references/
  TROUBLESHOOTING.md   ← 24 documented issues + solutions
  config-templates/    ← OpenClaw config, systemd, auth templates
```

## Requirements

- AWS CLI (`aws`) installed and working
- `jq`, `openssl`, `base64` available
- AWS account with EC2/VPC/IAM/SSM permissions
- Telegram bot token ([create one](https://t.me/BotFather))
- Gemini API key ([get free key](https://aistudio.google.com/apikey))

## Supported Models

The default configuration uses **Gemini 2.0 Flash** (free tier). To use other models, edit the `openclaw.json` config on the instance via SSM. See `references/TROUBLESHOOTING.md` for Bedrock model setup.

## Lessons Learned

This skill encodes **24 documented issues** discovered during real deployments. Every fix is baked into the scripts. See [`references/TROUBLESHOOTING.md`](references/TROUBLESHOOTING.md) for the full list, including:

- Instance sizing (why t4g.medium, not small)
- Node.js installation pitfalls on AL2023 ARM64
- OpenClaw gateway startup modes
- Telegram plugin configuration gotchas
- Systemd service hardening issues

## Contributing

PRs welcome. If you hit a new issue during deployment, please add it to `references/TROUBLESHOOTING.md` with symptom, cause, and solution.

## License

MIT
