---
name: openclaw-aws-deploy
description: Deploy OpenClaw securely on AWS with a single command. Creates VPC, EC2 (ARM64), Telegram channel, and Gemini Flash model — SSM-only access, no SSH. Use when setting up OpenClaw on AWS, deploying a new agent instance to EC2, or tearing down an existing AWS deployment.
metadata:
  {
    "openclaw":
      {
        "emoji": "☁️",
        "requires": { "bins": ["aws", "jq", "openssl"] },
      },
  }
---

# OpenClaw AWS Deploy

## Deploy

```bash
./scripts/deploy_minimal.sh --name <agent-name> --region us-east-1 \
  --env-dir /path/to/workspace
```

Required env files in `--env-dir` (never in git):
- `.env.aws` — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`
- `.env.starfish` — `TELEGRAM_BOT_TOKEN`, `GEMINI_API_KEY`

Options:
- `--personality <name|path>` — default, sentinel, researcher, coder, companion, or path to custom SOUL.md
- `--instance-type` (default: t4g.medium), `--cleanup-first`, `--dry-run`

Output: `deploy-output.json` with all resource IDs and SSM access commands.

## After Deploy

1. User messages the Telegram bot → gets pairing code
2. Approve pairing via SSM:
   ```bash
   aws ssm start-session --target <INSTANCE_ID> --region us-east-1
   sudo -u openclaw bash -c "export HOME=/home/openclaw; openclaw pairing approve telegram <CODE>"
   ```

## Teardown

```bash
# From deploy output:
./scripts/teardown.sh --from-output ./deploy-output.json --env-dir /path/to/workspace --yes

# By name (tag discovery):
./scripts/teardown.sh --name <agent-name> --region us-east-1 --env-dir /path/to/workspace --yes
```

## Architecture

- **EC2 t4g.medium** (4GB ARM64) — minimum for OpenClaw 2026.x
- **Node.js 22** from official tarball (verified SHA256)
- **Gemini 2.0 Flash** — free tier, 1M context, supports tools
- **No inbound ports** — SSM Session Manager only
- **Secrets sourced from SSM** — sourced at bootstrap, then persisted on-instance in OpenClaw config files
- **Encrypted EBS** (gp3, 20GB) + IMDSv2 enforced
- **Cost:** ~$30/mo

## Troubleshooting

24 documented issues with solutions: see `references/TROUBLESHOOTING.md`

Key gotchas:
- Use `openclaw gateway run` not `start` (start tries systemctl --user, fails)
- Config must be `openclaw.json` not `config.yaml`
- `plugins.entries.telegram.enabled: true` must be explicit
- `dmPolicy: "pairing"` not `"allowlist"` (blocks everyone)
- `openclaw@latest` not bare `openclaw` (placeholder package on npm)
- t4g.small (2GB) OOMs — need t4g.medium (4GB)

## Config Templates

Ready-to-use templates in `references/config-templates/`:
- `gemini-flash.json` — OpenClaw config
- `auth-profiles-gemini.json` — Gemini API auth
- `openclaw.service` — systemd unit
- `startup.sh` — gateway startup script
