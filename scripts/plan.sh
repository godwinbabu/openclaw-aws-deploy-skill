#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --region <aws-region>                 Required
  --environment <name>                  Environment name (default: dev)
  --project <name>                      Project prefix (default: openclaw)
  --channel-profile <telegram|none>     Channel profile (default: telegram)
  --model-profile <cheap|balanced|quality>  Model profile (default: cheap)
  --cost-mode <dev-low-cost|prod-baseline>  Cost mode (default: prod-baseline)
  --output <path>                       Output JSON plan (default: ./deployment-plan.json)
  -h, --help                            Show help
USAGE
}

REGION=""
ENVIRONMENT="dev"
PROJECT="openclaw"
CHANNEL_PROFILE="telegram"
MODEL_PROFILE="cheap"
COST_MODE="prod-baseline"
OUTPUT_PATH="./deployment-plan.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="${2:-}"; shift 2 ;;
    --environment) ENVIRONMENT="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --channel-profile) CHANNEL_PROFILE="${2:-}"; shift 2 ;;
    --model-profile) MODEL_PROFILE="${2:-}"; shift 2 ;;
    --cost-mode) COST_MODE="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "$REGION" ]]; then
  echo "--region is required" >&2
  exit 1
fi

case "$CHANNEL_PROFILE" in telegram|none) ;; *) echo "Invalid channel profile" >&2; exit 1;; esac
case "$MODEL_PROFILE" in cheap|balanced|quality) ;; *) echo "Invalid model profile" >&2; exit 1;; esac
case "$COST_MODE" in dev-low-cost|prod-baseline) ;; *) echo "Invalid cost mode" >&2; exit 1;; esac

stack_prefix="${PROJECT}-${ENVIRONMENT}"
network_stack="${stack_prefix}-network"
app_stack="${stack_prefix}-app"
waf_stack="${stack_prefix}-waf"

if [[ "$COST_MODE" == "dev-low-cost" ]]; then
  nat_mode="none"
  az_count=1
  waf_enabled=false
else
  nat_mode="gateway"
  az_count=2
  waf_enabled=true
fi

instance_type="t3.medium"
if [[ "$COST_MODE" == "dev-low-cost" ]]; then
  instance_type="t3.small"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

jq -n \
  --arg schemaVersion "1.1" \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg region "$REGION" \
  --arg environment "$ENVIRONMENT" \
  --arg project "$PROJECT" \
  --arg channelProfile "$CHANNEL_PROFILE" \
  --arg modelProfile "$MODEL_PROFILE" \
  --arg costMode "$COST_MODE" \
  --arg stackPrefix "$stack_prefix" \
  --arg networkStack "$network_stack" \
  --arg appStack "$app_stack" \
  --arg wafStack "$waf_stack" \
  --arg natMode "$nat_mode" \
  --arg instanceType "$instance_type" \
  --arg healthCheckPath "/health" \
  --argjson azCount "$az_count" \
  --argjson wafEnabled "$waf_enabled" \
  '{
    schemaVersion: $schemaVersion,
    generatedAt: $generatedAt,
    inputs: {
      region: $region,
      environment: $environment,
      project: $project,
      channelProfile: $channelProfile,
      modelProfile: $modelProfile,
      costMode: $costMode
    },
    stacks: {
      prefix: $stackPrefix,
      network: $networkStack,
      app: $appStack,
      waf: $wafStack
    },
    architecture: {
      azCount: $azCount,
      natMode: $natMode,
      wafEnabled: $wafEnabled,
      instanceType: $instanceType,
      persistence: {
        runtime: "EBS",
        backups: "Snapshots + optional S3 archive"
      },
      networking: {
        albListenerPort: 443,
        gatewayPort: 18789,
        healthCheckPath: $healthCheckPath
      }
    }
  }' > "$OUTPUT_PATH"

echo "Plan generated: $OUTPUT_PATH"
