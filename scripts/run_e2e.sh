#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [options]

Required:
  --region <aws-region>
  --host <ssm-instance-id>
  --gateway-token-ssm <ssm-param-name>

Optional:
  --project <name>                     Default: openclaw
  --environment <name>                 Default: dev
  --cost-mode <dev-low-cost|prod-baseline>  Default: prod-baseline
  --model-profile <cheap|balanced|quality>  Default: cheap
  --telegram-bot-token-ssm <ssm-param-name>
  --domain-name <fqdn>
  --hosted-zone-id <route53-zone-id>
  --output-dir <dir>                   Default: ./out
USAGE
}

REGION=""
HOST=""
PROJECT="openclaw"
ENVIRONMENT="dev"
COST_MODE="prod-baseline"
MODEL_PROFILE="cheap"
GATEWAY_TOKEN_SSM=""
TELEGRAM_BOT_TOKEN_SSM=""
DOMAIN_NAME=""
HOSTED_ZONE_ID=""
OUTPUT_DIR="./out"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="${2:-}"; shift 2 ;;
    --host) HOST="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --environment) ENVIRONMENT="${2:-}"; shift 2 ;;
    --cost-mode) COST_MODE="${2:-}"; shift 2 ;;
    --model-profile) MODEL_PROFILE="${2:-}"; shift 2 ;;
    --gateway-token-ssm) GATEWAY_TOKEN_SSM="${2:-}"; shift 2 ;;
    --telegram-bot-token-ssm) TELEGRAM_BOT_TOKEN_SSM="${2:-}"; shift 2 ;;
    --domain-name) DOMAIN_NAME="${2:-}"; shift 2 ;;
    --hosted-zone-id) HOSTED_ZONE_ID="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$REGION" ]] || { echo "--region required" >&2; exit 1; }
[[ -n "$HOST" ]] || { echo "--host required" >&2; exit 1; }
[[ -n "$GATEWAY_TOKEN_SSM" ]] || { echo "--gateway-token-ssm required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUTPUT_DIR"

PRE="${OUTPUT_DIR}/preflight-report.json"
PLAN="${OUTPUT_DIR}/deployment-plan.json"
INFRA="${OUTPUT_DIR}/deploy-infra-output.json"
SMOKE="${OUTPUT_DIR}/smoke-test-report.json"
SUMMARY="${OUTPUT_DIR}/deployment-summary.json"

log() { echo "[run_e2e] $*"; }

log "1/7 preflight"
"$SCRIPT_DIR/preflight.sh" \
  --region "$REGION" \
  --auth-mode role \
  --channel-profile "$( [[ -n "$TELEGRAM_BOT_TOKEN_SSM" ]] && echo telegram || echo none )" \
  --model-profile "$MODEL_PROFILE" \
  --cost-mode "$COST_MODE" \
  --output "$PRE"

log "2/7 plan"
if [[ -x "$SCRIPT_DIR/plan.sh" ]]; then
  "$SCRIPT_DIR/plan.sh" --region "$REGION" --environment "$ENVIRONMENT" --project "$PROJECT" --channel-profile "$( [[ -n "$TELEGRAM_BOT_TOKEN_SSM" ]] && echo telegram || echo none )" --model-profile "$MODEL_PROFILE" --cost-mode "$COST_MODE" --output "$PLAN"
else
  echo '{"note":"plan.sh not present"}' > "$PLAN"
fi

log "3/7 deploy infra"
DEPLOY_ARGS=(--region "$REGION" --project "$PROJECT" --environment "$ENVIRONMENT" --cost-mode "$COST_MODE" --output "$INFRA")
if [[ -n "$DOMAIN_NAME" && -n "$HOSTED_ZONE_ID" ]]; then
  DEPLOY_ARGS+=(--domain-name "$DOMAIN_NAME" --hosted-zone-id "$HOSTED_ZONE_ID")
fi
"$SCRIPT_DIR/deploy_infra.sh" "${DEPLOY_ARGS[@]}"

ALB_DNS=$(jq -r '.outputs.albDnsName // empty' "$INFRA")
[[ -n "$ALB_DNS" ]] || { echo "ALB DNS missing from infra output" >&2; exit 1; }

log "4/7 bootstrap host"
"$SCRIPT_DIR/bootstrap_host.sh" --host "$HOST" --region "$REGION"

log "5/7 configure openclaw"
CFG_ARGS=(--host "$HOST" --region "$REGION" --model-profile "$MODEL_PROFILE" --gateway-token-ssm "$GATEWAY_TOKEN_SSM")
if [[ -n "$TELEGRAM_BOT_TOKEN_SSM" ]]; then
  CFG_ARGS+=(--telegram-bot-token-ssm "$TELEGRAM_BOT_TOKEN_SSM")
fi
"$SCRIPT_DIR/configure_openclaw.sh" "${CFG_ARGS[@]}"

log "6/7 smoke test"
GW_TOKEN=$(aws ssm get-parameter --region "$REGION" --name "$GATEWAY_TOKEN_SSM" --with-decryption --query 'Parameter.Value' --output text)
"$SCRIPT_DIR/smoke_test.sh" --endpoint "https://${ALB_DNS}" --gateway-token "$GW_TOKEN" --output "$SMOKE"

log "7/7 collect outputs"
"$SCRIPT_DIR/collect_outputs.sh" --infra "$INFRA" --smoke "$SMOKE" --output "$SUMMARY"

log "E2E complete: $SUMMARY"
