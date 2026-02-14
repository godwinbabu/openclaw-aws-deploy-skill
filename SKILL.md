---
name: openclaw-aws-deploy
description: Deploy OpenClaw securely on AWS using AWS CLI and infrastructure templates. Use when setting up OpenClaw in AWS with VPC, EC2, SSM-only access, and channel/model bootstrap.
---

# OpenClaw AWS Deploy Skill

## Quick Start (Minimal Deployment)

For a budget-friendly single-instance deployment (~$15-20/mo):

1. **Prerequisites**
   - AWS account with credentials configured
   - Telegram bot token (from @BotFather)
   - Gemini API key (from aistudio.google.com - free)

2. **Deploy Infrastructure**
   ```bash
   ./scripts/deploy_minimal.sh --name starfish --region us-east-1
   ```

3. **Configure OpenClaw**
   ```bash
   ./scripts/configure_openclaw.sh --telegram-token $TOKEN --gemini-key $KEY
   ```

4. **Smoke Test**
   ```bash
   ./scripts/smoke_test.sh
   ```

## Workflow (Full)
1. Run `scripts/preflight.sh` to validate AWS credentials, region, required CLIs
2. Run `scripts/plan.sh` to generate stack names and deployment profile
3. Run `scripts/deploy_infra.sh` to provision AWS infrastructure
4. Run `scripts/bootstrap_host.sh` to install OpenClaw on EC2
5. Run `scripts/configure_openclaw.sh` to apply model/channel config
6. Run `scripts/smoke_test.sh` to validate health and end-to-end
7. Run `scripts/collect_outputs.sh` to produce deployment summary

## Architecture (Minimal)

```
┌─────────────────────────────────────────────────────┐
│                      VPC                            │
│  ┌───────────────────────────────────────────────┐  │
│  │              Public Subnet                     │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │         EC2 (t4g.small)                 │  │  │
│  │  │  ┌───────────────────────────────────┐  │  │  │
│  │  │  │         OpenClaw Gateway          │  │  │  │
│  │  │  │  • Gemini Flash (google API)      │  │  │  │
│  │  │  │  • Telegram channel               │  │  │  │
│  │  │  └───────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
         ↑                              ↓
    SSM (no SSH)              Outbound HTTPS only
```

## Key Design Decisions

### Security
- **No inbound ports** - SSM Session Manager only (no SSH)
- **Public IP + no inbound rules** - Cheaper than NAT (~$3/mo vs $25/mo)
- **Secrets in SSM Parameter Store** - Not in code or config files
- **Minimal IAM** - Only SSM + model provider permissions

### Instance Sizing
- **t4g.small (2GB)** - Minimum for OpenClaw. t4g.micro (1GB) causes OOM
- **ARM64** - Better price/performance than x86

### Model Selection
- **Gemini Flash** (recommended) - Free tier, 1M context, supports tools
- **Mistral Large** (Bedrock) - Good fallback, no form required
- **Claude** (Bedrock) - Requires Anthropic use case form

## Critical Configuration Notes

### OpenClaw Config (openclaw.json)
```json
{
  "gateway": {
    "mode": "local",           // Required!
    "auth": { "mode": "token", "token": "..." }  // Required!
  },
  "plugins": {
    "entries": {
      "telegram": { "enabled": true }  // Must be explicit!
    }
  },
  "channels": {
    "telegram": {
      "dmPolicy": "pairing"    // Not "allowlist" without users
    }
  }
}
```

### Startup Script
Use `openclaw gateway run --allow-unconfigured` (not `gateway start`!)
The `start` command tries to create a user-level systemd service which fails.

### Auth Profiles (for Gemini)
Create `/home/openclaw/.openclaw/agents/main/agent/auth-profiles.json`:
```json
{
  "version": 1,
  "profiles": {
    "google:default": {
      "type": "token",
      "provider": "google", 
      "token": "YOUR_GEMINI_API_KEY"
    }
  }
}
```

## Safety Rules
- Never print secrets in logs
- Never open SSH to the world; use SSM Session Manager
- Use least-privilege IAM policies
- Kill old gateway process before restart (`pkill -f openclaw-gateway`)

## Deployment Profiles
- `minimal` - Single t4g.small, ~$15-20/mo
- `dev-low-cost` - With monitoring, ~$25-30/mo  
- `prod-baseline` - ALB, WAF, multi-AZ, ~$100+/mo

## References
- `references/TROUBLESHOOTING.md` - Common issues and fixes
- `references/aws-architecture.md` - Full architecture details
- `references/security-baseline.md` - Security requirements
- `references/config-templates/` - Ready-to-use config files

## Config Templates
- `gemini-flash.json` - OpenClaw config for Gemini Flash
- `auth-profiles-gemini.json` - Auth profile for Google API
- `startup.sh` - Systemd-compatible startup script
- `openclaw.service` - Systemd unit file
