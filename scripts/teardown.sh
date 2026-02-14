#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# teardown.sh — Clean up all AWS resources for a named OpenClaw deployment
#
# Usage:
#   ./scripts/teardown.sh --name starfish --region us-east-1
#   ./scripts/teardown.sh --name starfish --region us-east-1 --env-dir /path/to/envs
#   ./scripts/teardown.sh --from-output ./deploy-output.json --env-dir /path/to/envs
###############################################################################

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --name <name>           Agent/project name (default: starfish)
  --region <region>       AWS region (default: us-east-1)
  --env-dir <path>        Directory containing .env.aws
  --from-output <path>    Read resource IDs from deploy-output.json
  --yes                   Skip confirmation
  -h, --help              Show help
USAGE
}

NAME="starfish"
REGION="us-east-1"
ENV_DIR=""
FROM_OUTPUT=""
YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --env-dir) ENV_DIR="${2:-}"; shift 2 ;;
    --from-output) FROM_OUTPUT="${2:-}"; shift 2 ;;
    --yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "$ENV_DIR" ]]; then
  if [[ -f "$SKILL_DIR/../.env.aws" ]]; then
    ENV_DIR="$SKILL_DIR/.."
  elif [[ -f "$SKILL_DIR/.env.aws" ]]; then
    ENV_DIR="$SKILL_DIR"
  else
    echo "ERROR: Cannot find .env.aws" >&2; exit 1
  fi
fi

source "$(cd "$ENV_DIR" && pwd)/.env.aws"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$REGION"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
aws_cmd() { aws --region "$REGION" --output text "$@" 2>/dev/null || echo ""; }

TAG_KEY="Project"
TAG_VALUE="$NAME"

log "=========================================="
log "  OpenClaw Teardown: $NAME"
log "=========================================="

# If we have a deploy output, use those IDs
if [[ -n "$FROM_OUTPUT" && -f "$FROM_OUTPUT" ]]; then
  INSTANCE_ID=$(jq -r '.instance.instanceId // empty' "$FROM_OUTPUT")
  VPC_ID=$(jq -r '.infrastructure.vpcId // empty' "$FROM_OUTPUT")
  SG_ID=$(jq -r '.infrastructure.securityGroupId // empty' "$FROM_OUTPUT")
  SUBNET_ID=$(jq -r '.infrastructure.subnetId // empty' "$FROM_OUTPUT")
  IGW_ID=$(jq -r '.infrastructure.igwId // empty' "$FROM_OUTPUT")
  RTB_ID=$(jq -r '.infrastructure.routeTableId // empty' "$FROM_OUTPUT")
else
  # Discover by tag
  log "Discovering resources by tag: $TAG_KEY=$TAG_VALUE"
  INSTANCE_ID=$(aws_cmd ec2 describe-instances \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" "Name=instance-state-name,Values=running,stopped,pending" \
    --query 'Reservations[0].Instances[0].InstanceId')
  VPC_ID=$(aws_cmd ec2 describe-vpcs \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
    --query 'Vpcs[0].VpcId')
  SG_ID=$(aws_cmd ec2 describe-security-groups \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
    --query 'SecurityGroups[0].GroupId')
  SUBNET_ID=$(aws_cmd ec2 describe-subnets \
    --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
    --query 'Subnets[0].SubnetId')
fi

log "Resources found:"
log "  Instance:  ${INSTANCE_ID:-none}"
log "  VPC:       ${VPC_ID:-none}"
log "  SG:        ${SG_ID:-none}"
log "  Subnet:    ${SUBNET_ID:-none}"

if [[ "$YES" != "true" ]]; then
  read -p "Delete all these resources? Type 'yes': " confirm
  [[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

# 1. Terminate instance
if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
  log "Terminating instance $INSTANCE_ID..."
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null 2>&1 || true
  log "Waiting for termination..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID" 2>/dev/null || sleep 60
fi

# 2. Delete SSM parameters
log "Deleting SSM parameters..."
for param in "/${NAME}/telegram/bot_token" "/${NAME}/gemini/api_key" "/${NAME}/gateway/token" "/${NAME}/openrouter/api_key"; do
  aws ssm delete-parameter --region "$REGION" --name "$param" 2>/dev/null && log "  Deleted: $param" || true
done

# 3. Clean up IAM
log "Cleaning up IAM..."
aws iam remove-role-from-instance-profile \
  --instance-profile-name "${NAME}-instance-profile" \
  --role-name "${NAME}-role" 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name "${NAME}-instance-profile" 2>/dev/null || true

# Delete inline policies
for policy in SSMParameterAccess SSMAccess BedrockFullAccess; do
  aws iam delete-role-policy --role-name "${NAME}-role" --policy-name "$policy" 2>/dev/null || true
done

# Detach managed policies
aws iam detach-role-policy --role-name "${NAME}-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true

aws iam delete-role --role-name "${NAME}-role" 2>/dev/null && log "  Deleted IAM role" || true

# 4. Delete SG
if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  sleep 5
  aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null && log "  Deleted SG" || log "  SG delete failed (retry later)"
fi

# 5. Delete subnet
if [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]]; then
  aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_ID" 2>/dev/null && log "  Deleted subnet" || true
fi

# 6. Delete IGW
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  IGW_ID=$(aws_cmd ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId')
  if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
    aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
    aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" 2>/dev/null && log "  Deleted IGW" || true
  fi
fi

# 7. Delete route tables (non-main)
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  for rtb in $(aws_cmd ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId'); do
    # Disassociate first
    for assoc in $(aws_cmd ec2 describe-route-tables \
      --route-table-ids "$rtb" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId'); do
      aws ec2 disassociate-route-table --region "$REGION" --association-id "$assoc" 2>/dev/null || true
    done
    aws ec2 delete-route-table --region "$REGION" --route-table-id "$rtb" 2>/dev/null && log "  Deleted route table $rtb" || true
  done
fi

# 8. Delete VPC
if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID" 2>/dev/null && log "  Deleted VPC" || log "  VPC delete failed (check dependencies)"
fi

log ""
log "=========================================="
log "  ✅ Teardown Complete!"
log "=========================================="
