---
name: openclaw-aws-deploy
description: Deploy OpenClaw securely on AWS using AWS CLI and infrastructure templates. Use when setting up OpenClaw in AWS with VPC, EC2, SSM-only access, and channel/model bootstrap.
---

# OpenClaw AWS Deploy Skill

## Quick Start (Minimal Deployment ~$25/mo)

### Prerequisites
- `.env.aws` in workspace root:
  ```
  AWS_ACCESS_KEY_ID=...
  AWS_SECRET_ACCESS_KEY=...
  AWS_DEFAULT_REGION=us-east-1
  ```
- `.env.starfish` in workspace root:
  ```
  TELEGRAM_BOT_TOKEN=...     # from @BotFather
  GEMINI_API_KEY=...         # from aistudio.google.com (free)
  ```
- `aws` CLI installed OR Docker for sandboxed access
- `jq`, `openssl` available

### One-Shot Deploy

```bash
# From the skill directory:
./scripts/deploy_minimal.sh --name starfish --region us-east-1 \
  --env-dir /path/to/workspace

# Or with cleanup of previous deployment first:
./scripts/deploy_minimal.sh --name starfish --region us-east-1 \
  --env-dir /path/to/workspace --cleanup-first
```

This single command:
1. Creates VPC + subnet + IGW + route table
2. Creates security group (NO inbound ports — SSM only)
3. Creates IAM role with minimal permissions (SSM + Parameter Store)
4. Stores secrets in SSM Parameter Store
5. Launches **t4g.medium** ARM64 instance with user-data bootstrap
6. User-data installs Node.js 22 + OpenClaw + configures everything
7. Runs smoke test via SSM
8. Saves all resource IDs to `deploy-output.json`

### After Deploy

1. **Message the Telegram bot** — you'll get a pairing code
2. **Approve pairing** via SSM:
   ```bash
   aws ssm start-session --target <INSTANCE_ID> --region us-east-1
   sudo -u openclaw bash
   export HOME=/home/openclaw
   openclaw pairing approve telegram <CODE>
   ```
3. Bot is live! ✅

### Teardown

```bash
# Using saved output:
./scripts/teardown.sh --from-output ./deploy-output.json --env-dir /path/to/workspace --yes

# Or by name (discovers via tags):
./scripts/teardown.sh --name starfish --region us-east-1 --env-dir /path/to/workspace --yes
```

## Architecture (Minimal)

```
┌─────────────────────────────────────────────────────┐
│                      VPC (10.50.0.0/16)             │
│  ┌───────────────────────────────────────────────┐  │
│  │           Public Subnet (10.50.0.0/24)        │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │      EC2 t4g.medium (ARM64, 4GB)        │  │  │
│  │  │  ┌───────────────────────────────────┐  │  │  │
│  │  │  │       OpenClaw Gateway             │  │  │  │
│  │  │  │  • Node.js 22.14.0                 │  │  │  │
│  │  │  │  • Gemini 2.0 Flash (google API)   │  │  │  │
│  │  │  │  • Telegram channel                │  │  │  │
│  │  │  │  • Encrypted EBS (gp3, 20GB)       │  │  │  │
│  │  │  └───────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
         ↑                              ↓
    SSM (no SSH/inbound)      Outbound HTTPS only
```

## Critical Lessons Learned (24 Issues)

These are baked into the deploy script. See `references/TROUBLESHOOTING.md` for full details.

### Instance Sizing
- **t4g.medium (4GB) required** — t4g.small (2GB) OOMs during npm install + gateway startup
- **ARM64** — better price/performance than x86

### Node.js
- **Node 22+ required** — OpenClaw 2026.x requires Node ≥22.12.0
- **Official tarball install** — NodeSource setup_22.x unreliable on AL2023 ARM64
- **git required** — OpenClaw npm install has git-based dependencies

### npm
- **Use `openclaw@latest`** — bare `openclaw` may resolve to placeholder package (0.0.1)

### Gateway Startup
- **Use `openclaw gateway run --allow-unconfigured`** — NOT `gateway start` (which tries `systemctl --user` and fails)
- **Config file must be `openclaw.json`** — not `config.yaml`
- **`gateway.mode: "local"`** — required or you get "Missing config" error
- **`gateway.auth.mode: "token"`** — `"none"` is invalid

### Telegram
- **`plugins.entries.telegram.enabled: true`** — must be explicit
- **`dmPolicy: "pairing"`** — not `"allowlist"` (blocks everyone without user list)
- **`streamMode: "partial"`** — some models don't support streaming tools, use `"off"` as fallback

### Model
- **Gemini 2.0 Flash** — recommended (free tier: 15 RPM, 1M tokens/day, supports tools)
- **Auth profiles required** — create `auth-profiles.json` in agent dir
- **Bedrock format** — `amazon-bedrock/MODEL_ID` (not `bedrock/`)
- **Bedrock models need console enablement** — Anthropic requires use case form

### Systemd Service
- **Simplified service file** — removed `ProtectHome`, `ReadWritePaths=/tmp/openclaw`, `PrivateTmp` due to namespace issues
- **Use `NODE_OPTIONS="--max-old-space-size=1024"`** — helps prevent OOM

### Security
- **No inbound ports** — SSM Session Manager only
- **Secrets in SSM Parameter Store** — never in config files or git
- **Encrypted EBS** — enabled by default in deploy script
- **IMDSv2 required** — `HttpTokens=required`

## File Layout

```
scripts/
  deploy_minimal.sh    # One-shot deploy (VPC + EC2 + OpenClaw)
  teardown.sh          # Clean teardown of all resources
  preflight.sh         # Validate AWS creds + prerequisites
  smoke_test.sh        # Post-deploy validation
  deploy_infra.sh      # CloudFormation-based (advanced)
  bootstrap_host.sh    # SSM-based host bootstrap (advanced)
  configure_openclaw.sh # SSM-based config push (advanced)

references/
  TROUBLESHOOTING.md   # All 24 issues + solutions
  config-templates/    # Ready-to-use config files
    gemini-flash.json  # OpenClaw config for Gemini Flash
    auth-profiles-gemini.json  # Auth profile template
    openclaw.service   # Systemd unit file
    startup.sh         # Startup script template
```

## Config Templates

### OpenClaw Config (gemini-flash.json)
See `references/config-templates/gemini-flash.json` — includes all required fields.

### Auth Profiles (auth-profiles-gemini.json)
Create at `~/.openclaw/agents/main/agent/auth-profiles.json`

### Systemd Service (openclaw.service)
Simplified for reliability — security hardening removed due to namespace issues.

## Cost Breakdown (~$25/mo)
| Resource | Cost |
|----------|------|
| t4g.medium (4GB ARM64) | ~$24.53/mo |
| EBS gp3 20GB | ~$1.60/mo |
| Public IP | ~$3.65/mo |
| Gemini Flash | Free tier / ~$0.30/1M tokens |
| **Total** | **~$29.78/mo** |

## Safety Rules
- Never print secrets in logs
- Never open SSH/inbound ports; use SSM Session Manager only
- Use least-privilege IAM policies
- All resources tagged with `Project=<name>` for easy teardown
- Encrypted EBS volumes always
