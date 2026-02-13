#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --region <aws-region>               Required
  --project <name>                    Project prefix (default: openclaw)
  --environment <name>                Environment name (default: dev)
  --cost-mode <dev-low-cost|prod-baseline>  Cost mode (default: prod-baseline)
  --vpc-cidr <cidr>                   VPC CIDR (default: 10.50.0.0/16)
  --public-a-cidr <cidr>              Public subnet A CIDR (default: 10.50.0.0/24)
  --public-b-cidr <cidr>              Public subnet B CIDR (default: 10.50.1.0/24)
  --private-a-cidr <cidr>             Private subnet A CIDR (default: 10.50.10.0/24)
  --private-b-cidr <cidr>             Private subnet B CIDR (default: 10.50.11.0/24)
  --hosted-zone-id <id>               Optional Route53 hosted zone id
  --domain-name <name>                Optional domain name for ACM cert
  --output <path>                     Output JSON file (default: ./deploy-infra-output.json)
  -h, --help                          Show help
USAGE
}

REGION=""
PROJECT="openclaw"
ENVIRONMENT="dev"
COST_MODE="prod-baseline"
VPC_CIDR="10.50.0.0/16"
PUBLIC_A_CIDR="10.50.0.0/24"
PUBLIC_B_CIDR="10.50.1.0/24"
PRIVATE_A_CIDR="10.50.10.0/24"
PRIVATE_B_CIDR="10.50.11.0/24"
HOSTED_ZONE_ID=""
DOMAIN_NAME=""
OUTPUT_PATH="./deploy-infra-output.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; shift 2 ;;
    --environment) ENVIRONMENT="${2:-}"; shift 2 ;;
    --cost-mode) COST_MODE="${2:-}"; shift 2 ;;
    --vpc-cidr) VPC_CIDR="${2:-}"; shift 2 ;;
    --public-a-cidr) PUBLIC_A_CIDR="${2:-}"; shift 2 ;;
    --public-b-cidr) PUBLIC_B_CIDR="${2:-}"; shift 2 ;;
    --private-a-cidr) PRIVATE_A_CIDR="${2:-}"; shift 2 ;;
    --private-b-cidr) PRIVATE_B_CIDR="${2:-}"; shift 2 ;;
    --hosted-zone-id) HOSTED_ZONE_ID="${2:-}"; shift 2 ;;
    --domain-name) DOMAIN_NAME="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$REGION" ]] || { echo "--region is required" >&2; exit 1; }
case "$COST_MODE" in dev-low-cost|prod-baseline) ;; *) echo "Invalid --cost-mode" >&2; exit 1;; esac

STACK_PREFIX="${PROJECT}-${ENVIRONMENT}"
NETWORK_STACK="${STACK_PREFIX}-network"
WAF_STACK="${STACK_PREFIX}-waf"
APP_STACK="${STACK_PREFIX}-app"

AZ_COUNT=2
ENABLE_WAF=true
NAT_MODE="gateway"
if [[ "$COST_MODE" == "dev-low-cost" ]]; then
  AZ_COUNT=1
  ENABLE_WAF=false
  NAT_MODE="none"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CFN_DIR="$ROOT_DIR/assets/cloudformation"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$NETWORK_STACK" \
  --template-file "$CFN_DIR/network.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName="$PROJECT" \
    EnvironmentName="$ENVIRONMENT" \
    VpcCidr="$VPC_CIDR" \
    PublicSubnetACidr="$PUBLIC_A_CIDR" \
    PublicSubnetBCidr="$PUBLIC_B_CIDR" \
    PrivateSubnetACidr="$PRIVATE_A_CIDR" \
    PrivateSubnetBCidr="$PRIVATE_B_CIDR" \
    AzCount="$AZ_COUNT" \
    NatMode="$NAT_MODE"

if [[ "$ENABLE_WAF" == "true" ]]; then
  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$WAF_STACK" \
    --template-file "$CFN_DIR/waf.yaml" \
    --parameter-overrides \
      ProjectName="$PROJECT" \
      EnvironmentName="$ENVIRONMENT"
fi

NETWORK_OUTPUTS=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$NETWORK_STACK" --query 'Stacks[0].Outputs' --output json)
VPC_ID=$(jq -r '.[] | select(.OutputKey=="VpcId") | .OutputValue' <<<"$NETWORK_OUTPUTS")
PUBLIC_SUBNET_A=$(jq -r '.[] | select(.OutputKey=="PublicSubnetAId") | .OutputValue' <<<"$NETWORK_OUTPUTS")
PUBLIC_SUBNET_B=$(jq -r '.[] | select(.OutputKey=="PublicSubnetBId") | .OutputValue' <<<"$NETWORK_OUTPUTS")
PRIVATE_SUBNET_A=$(jq -r '.[] | select(.OutputKey=="PrivateSubnetAId") | .OutputValue' <<<"$NETWORK_OUTPUTS")
PRIVATE_SUBNET_B=$(jq -r '.[] | select(.OutputKey=="PrivateSubnetBId") | .OutputValue' <<<"$NETWORK_OUTPUTS")
ALB_SG_ID=$(jq -r '.[] | select(.OutputKey=="AlbSecurityGroupId") | .OutputValue' <<<"$NETWORK_OUTPUTS")
APP_SG_ID=$(jq -r '.[] | select(.OutputKey=="AppSecurityGroupId") | .OutputValue' <<<"$NETWORK_OUTPUTS")

CERT_ARN=""
if [[ -n "$DOMAIN_NAME" && -n "$HOSTED_ZONE_ID" ]]; then
  CERT_ARN=$(aws acm request-certificate --region "$REGION" --domain-name "$DOMAIN_NAME" --validation-method DNS --query 'CertificateArn' --output text)
fi

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$APP_STACK" \
  --template-file "$CFN_DIR/app.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ProjectName="$PROJECT" \
    EnvironmentName="$ENVIRONMENT" \
    VpcId="$VPC_ID" \
    PublicSubnetAId="$PUBLIC_SUBNET_A" \
    PublicSubnetBId="$PUBLIC_SUBNET_B" \
    PrivateSubnetAId="$PRIVATE_SUBNET_A" \
    PrivateSubnetBId="$PRIVATE_SUBNET_B" \
    AlbSecurityGroupId="$ALB_SG_ID" \
    AppSecurityGroupId="$APP_SG_ID" \
    CertificateArn="$CERT_ARN"

APP_OUTPUTS=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$APP_STACK" --query 'Stacks[0].Outputs' --output json)
ALB_DNS=$(jq -r '.[] | select(.OutputKey=="AlbDnsName") | .OutputValue' <<<"$APP_OUTPUTS")
TARGET_GROUP_ARN=$(jq -r '.[] | select(.OutputKey=="TargetGroupArn") | .OutputValue' <<<"$APP_OUTPUTS")

if [[ "$ENABLE_WAF" == "true" ]]; then
  WAF_OUTPUTS=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$WAF_STACK" --query 'Stacks[0].Outputs' --output json)
  WEB_ACL_ARN=$(jq -r '.[] | select(.OutputKey=="WebAclArn") | .OutputValue' <<<"$WAF_OUTPUTS")
  LISTENER_ARN=$(jq -r '.[] | select(.OutputKey=="HttpsListenerArn") | .OutputValue' <<<"$APP_OUTPUTS")
  aws wafv2 associate-web-acl --region "$REGION" --web-acl-arn "$WEB_ACL_ARN" --resource-arn "$LISTENER_ARN"
else
  WEB_ACL_ARN=""
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
jq -n \
  --arg schemaVersion "1.0" \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg region "$REGION" \
  --arg networkStack "$NETWORK_STACK" \
  --arg appStack "$APP_STACK" \
  --arg wafStack "$WAF_STACK" \
  --argjson wafEnabled "$ENABLE_WAF" \
  --arg albDnsName "$ALB_DNS" \
  --arg targetGroupArn "$TARGET_GROUP_ARN" \
  --arg webAclArn "$WEB_ACL_ARN" \
  '{
    schemaVersion: $schemaVersion,
    generatedAt: $generatedAt,
    status: "ok",
    stacks: {
      network: $networkStack,
      app: $appStack,
      waf: $wafStack
    },
    deploy: {
      region: $region,
      wafEnabled: $wafEnabled
    },
    outputs: {
      albDnsName: $albDnsName,
      targetGroupArn: $targetGroupArn,
      webAclArn: (if $webAclArn == "" then null else $webAclArn end)
    }
  }' > "$OUTPUT_PATH"

echo "Infrastructure deployed. Output: $OUTPUT_PATH"
