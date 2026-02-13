#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [options]
  --host <ssm-instance-id>                  Required
  --region <aws-region>                     Required
  --model-profile <cheap|balanced|quality>  Default: cheap
  --telegram-bot-token-ssm <param-name>     Optional SecureString parameter name
  --gateway-token-ssm <param-name>          Required SecureString parameter name
  -h, --help
USAGE
}

HOST=""
REGION=""
MODEL_PROFILE="cheap"
TELEGRAM_BOT_TOKEN_SSM=""
GATEWAY_TOKEN_SSM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --model-profile) MODEL_PROFILE="${2:-}"; shift 2 ;;
    --telegram-bot-token-ssm) TELEGRAM_BOT_TOKEN_SSM="${2:-}"; shift 2 ;;
    --gateway-token-ssm) GATEWAY_TOKEN_SSM="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$HOST" ]] || { echo "--host required" >&2; exit 1; }
[[ -n "$REGION" ]] || { echo "--region required" >&2; exit 1; }
[[ -n "$GATEWAY_TOKEN_SSM" ]] || { echo "--gateway-token-ssm required" >&2; exit 1; }

case "$MODEL_PROFILE" in
  cheap)
    PRIMARY_MODEL="openai-codex/gpt-5.2-codex"
    FALLBACKS='["google-antigravity/gemini-3-flash"]'
    ;;
  balanced)
    PRIMARY_MODEL="openai-codex/gpt-5.3-codex"
    FALLBACKS='["openai-codex/gpt-5.2-codex","google-antigravity/claude-sonnet-4-5-thinking"]'
    ;;
  quality)
    PRIMARY_MODEL="anthropic/claude-opus-4-6"
    FALLBACKS='["openai-codex/gpt-5.3-codex","google-antigravity/gemini-3-pro-high"]'
    ;;
  *) echo "invalid model profile" >&2; exit 1 ;;
esac

read -r -d '' COMMANDS <<'SCRIPT' || true
set -euo pipefail

GATEWAY_TOKEN=$(aws ssm get-parameter --region "$REGION" --name "$GATEWAY_TOKEN_SSM" --with-decryption --query 'Parameter.Value' --output text)
TG_TOKEN=""
if [[ -n "${TELEGRAM_BOT_TOKEN_SSM:-}" ]]; then
  TG_TOKEN=$(aws ssm get-parameter --region "$REGION" --name "$TELEGRAM_BOT_TOKEN_SSM" --with-decryption --query 'Parameter.Value' --output text)
fi

TG_SECTION='{}'
if [[ -n "$TG_TOKEN" ]]; then
  TG_SECTION=$(jq -n --arg token "$TG_TOKEN" '{telegram:{enabled:true,accounts:{default:{name:"OpenClaw",botToken:$token,dmPolicy:"pairing",groupPolicy:"allowlist"}}}}')
fi

CONFIG_PATCH=$(jq -n \
  --arg token "$GATEWAY_TOKEN" \
  --arg primary "$PRIMARY_MODEL" \
  --argjson fallbacks "$FALLBACKS" \
  --argjson channels "$TG_SECTION" \
  '{
    gateway: { mode:"local", bind:"0.0.0.0", port:18789, auth:{mode:"token", token:$token} },
    agents: { defaults:{ model:{ primary:$primary, fallbacks:$fallbacks } } },
    channels: $channels
  }')

openclaw gateway config.patch --raw "$CONFIG_PATCH" >/dev/null
systemctl restart openclaw-gateway
systemctl is-active openclaw-gateway
SCRIPT

CMD_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$HOST" \
  --document-name "AWS-RunShellScript" \
  --comment "Configure OpenClaw" \
  --parameters commands="export REGION='$REGION' GATEWAY_TOKEN_SSM='$GATEWAY_TOKEN_SSM' TELEGRAM_BOT_TOKEN_SSM='$TELEGRAM_BOT_TOKEN_SSM' PRIMARY_MODEL='$PRIMARY_MODEL' FALLBACKS='$FALLBACKS'; $COMMANDS" \
  --query 'Command.CommandId' --output text)

echo "SSM command sent: $CMD_ID"
aws ssm wait command-executed --region "$REGION" --command-id "$CMD_ID" --instance-id "$HOST" || true
STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$HOST" --query 'Status' --output text)
echo "Configure status: $STATUS"

if [[ "$STATUS" != "Success" ]]; then
  aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$HOST" \
    --query '{Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}' --output json
  exit 1
fi
