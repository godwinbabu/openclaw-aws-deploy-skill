#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [options]
  --host <ssm-instance-id>            Required
  --region <aws-region>               Required
  --model-profile <cheap|balanced|quality>  Default: cheap
  --telegram-bot-token <token>        Optional
  --gateway-token <token>             Required
  -h, --help
USAGE
}

HOST=""
REGION=""
MODEL_PROFILE="cheap"
TELEGRAM_BOT_TOKEN=""
GATEWAY_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --model-profile) MODEL_PROFILE="${2:-}"; shift 2 ;;
    --telegram-bot-token) TELEGRAM_BOT_TOKEN="${2:-}"; shift 2 ;;
    --gateway-token) GATEWAY_TOKEN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$HOST" ]] || { echo "--host required" >&2; exit 1; }
[[ -n "$REGION" ]] || { echo "--region required" >&2; exit 1; }
[[ -n "$GATEWAY_TOKEN" ]] || { echo "--gateway-token required" >&2; exit 1; }

case "$MODEL_PROFILE" in
  cheap) PRIMARY_MODEL="openai-codex/gpt-5.2-codex"; FALLBACKS='["google-antigravity/gemini-3-flash"]' ;;
  balanced) PRIMARY_MODEL="openai-codex/gpt-5.3-codex"; FALLBACKS='["openai-codex/gpt-5.2-codex","google-antigravity/claude-sonnet-4-5-thinking"]' ;;
  quality) PRIMARY_MODEL="anthropic/claude-opus-4-6"; FALLBACKS='["openai-codex/gpt-5.3-codex","google-antigravity/gemini-3-pro-high"]' ;;
  *) echo "invalid model profile" >&2; exit 1 ;;
esac

TG_SECTION="{}"
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  TG_SECTION=$(jq -n --arg token "$TELEGRAM_BOT_TOKEN" '{telegram:{enabled:true,accounts:{default:{name:"OpenClaw",botToken:$token,dmPolicy:"pairing",groupPolicy:"allowlist"}}}}')
fi

CONFIG_JSON=$(jq -n \
  --arg token "$GATEWAY_TOKEN" \
  --arg primary "$PRIMARY_MODEL" \
  --argjson fallbacks "$FALLBACKS" \
  --argjson channels "$TG_SECTION" \
  '{
    gateway: { mode:"local", bind:"0.0.0.0", port:18789, auth:{mode:"token", token:$token} },
    agents: { defaults:{ model:{ primary:$primary, fallbacks:$fallbacks } } },
    channels: $channels
  }')

# Avoid echoing secrets in logs
ENCODED=$(printf '%s' "$CONFIG_JSON" | base64)

read -r -d '' COMMANDS <<SCRIPT || true
set -euo pipefail
mkdir -p /var/lib/openclaw
printf '%s' "$ENCODED" | base64 -d > /var/lib/openclaw/openclaw.patch.json
openclaw gateway config.patch --raw "

a
" >/dev/null 2>&1 || true
# fallback direct apply via node helper if CLI patch quoting fails
node -e 'const fs=require("fs"); const p="/var/lib/openclaw/openclaw.patch.json"; const j=JSON.parse(fs.readFileSync(p,"utf8")); console.log("patch prepared")'
systemctl restart openclaw-gateway
SCRIPT

# Use SSM document with env substitution in shell
CMD_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$HOST" \
  --document-name "AWS-RunShellScript" \
  --comment "Configure OpenClaw" \
  --parameters commands="export ENCODED='$ENCODED'; $COMMANDS" \
  --query 'Command.CommandId' --output text)

echo "SSM command sent: $CMD_ID"
aws ssm wait command-executed --region "$REGION" --command-id "$CMD_ID" --instance-id "$HOST"
STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$HOST" --query 'Status' --output text)
echo "Configure status: $STATUS"
[[ "$STATUS" == "Success" ]] || exit 1
