---
name: openclaw-aws-deploy
description: Deploy OpenClaw securely on AWS using AWS CLI and infrastructure templates. Use when setting up OpenClaw in AWS with VPC, EC2, SSM-only access, and channel/model bootstrap.
---

# OpenClaw AWS Deploy Skill

## Quick Start (Minimal Deployment ~$15-20/mo)

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
- Docker installed (for sandboxed AWS access) OR `aws` CLI on host
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
5. Launches t4g.small ARM64 instance with user-data bootstrap
6. User-data installs Node.js 20 + OpenClaw + configures everything
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
./scripts/teardown.sh --from-output ./deploy-output.json --env-dir /path/to/workspace

# Or by name (discovers via tags):
./scripts/teardown.sh --name starfish --region us-east-1 --env-dir /path/to/workspace
```

## Architecture (Minimal)

```
┌─────────────────────────────────────────────────────┐
│                      VPC (10.50.0.0/16)             │
│  ┌───────────────────────────────────────────────┐  │
│  │           Public Subnet (10.50.0.0/24)        │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │      EC2 t4g.small (ARM64, 2GB)         │  │  │
│  │  │  ┌───────────────────────────────────┐  │  │  │
│  │  │  │       OpenClaw Gateway             │  │  │  │
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

## Critical Lessons Learned (18 Issues)

These are baked into the deploy script. See `references/TROUBLESHOOTING.md` for full details.

### Instance
- **t4g.small (2GB) minimum** — t4g.micro (1GB) causes OOM heap allocation failure
- **ARM64** — better price/performance than x86

### Gateway Startup
- **Use `openclaw gateway run --allow-unconfigured`** — NOT `gateway start` (which tries `systemctl --user` and fails)
- **Config file must be `openclaw.json`** — not `config.yaml`
- **`gateway.mode: "local"`** — required or you get "Missing config" error
- **`gateway.auth.mode: "token"`** — `"none"` is invalid
- **Kill stale processes** — `pkill -f openclaw-gateway` before restart

### Telegram
- **`plugins.entries.telegram.enabled: true`** — must be explicit
- **`dmPolicy: "pairing"`** — not `"allowlist"` (blocks everyone without user list)
- **`streamMode: "partial"`** — some models don't support streaming tools, use `"off"` as fallback

### Model
- **Gemini 2.0 Flash** — recommended (free tier: 15 RPM, 1M tokens/day, supports tools)
- **Auth profiles required** — create `auth-profiles.json` in agent dir
- **Bedrock format** — `amazon-bedrock/MODEL_ID` (not `bedrock/`)
- **Bedrock models need console enablement** — Anthropic requires use case form

### Security
- **No inbound ports** — SSM Session Manager only
- **Secrets in SSM Parameter Store** — never in config files or git
- **Encrypted EBS** — enabled by default in deploy script
- **IMDSv2 required** — `HttpTokens=required`
- **Node heap limit** — `NODE_OPTIONS="--max-old-space-size=512"`

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
  TROUBLESHOOTING.md   # All 18 issues + solutions
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
Includes security hardening: `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`

## Cost Breakdown (~$15-20/mo)
| Resource | Cost |
|----------|------|
| t4g.small (2GB ARM64) | ~$12.26/mo |
| EBS gp3 20GB | ~$1.60/mo |
| Public IP | ~$3.65/mo |
| Gemini Flash | Free tier / ~$0.30/1M tokens |
| **Total** | **~$17.51/mo** |

## Safety Rules
- Never print secrets in logs
- Never open SSH/inbound ports; use SSM Session Manager only
- Use least-privilege IAM policies
- All resources tagged with `Project=<name>` for easy teardown
- Kill old gateway process before restart
- Encrypted EBS volumes always
