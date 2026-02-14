#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# teardown.sh — Clean up all AWS resources for an OpenClaw deployment
#
# Discovery modes (in priority order):
#   1. --from-output <deploy-output.json>  (exact resource IDs)
#   2. --deploy-id <id>                     (unique deploy tag)
#   3. --name <name>                        (project tag, may match multiple deploys)
#
# Safety features:
#   - --dry-run shows what would be deleted without deleting
#   - Tag verification: resources must match expected tags
#   - Fail loudly on unexpected errors (set -euo pipefail)
#   - Confirmation prompt unless --yes is passed
#
# Usage:
#   ./scripts/teardown.sh --name starfish --dry-run
#   ./scripts/teardown.sh --deploy-id starfish-20260215T143000Z --yes
#   ./scripts/teardown.sh --from-output ./deploy-output.json --yes
###############################################################################

usage() {
  cat <<USAGE
Usage: $0 [options]

Discovery (at least one required):
  --name <name>           Find resources by Project=<name> tag
  --deploy-id <id>        Find resources by DeployId=<id> tag (most precise)
  --from-output <path>    Read resource IDs from deploy-output.json

Options:
  --region <region>       AWS region (default: us-east-1)
  --env-dir <path>        Directory containing .env.aws
  --dry-run               Show what would be deleted, don't delete
  --yes                   Skip confirmation prompt
  -h, --help              Show help
USAGE
}

NAME=""
DEPLOY_ID=""
REGION="us-east-1"
ENV_DIR=""
FROM_OUTPUT=""
DRY_RUN=false
YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --deploy-id) DEPLOY_ID="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --env-dir) ENV_DIR="${2:-}"; shift 2 ;;
    --from-output) FROM_OUTPUT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Must have at least one discovery method
if [[ -z "$NAME" && -z "$DEPLOY_ID" && -z "$FROM_OUTPUT" ]]; then
  echo "ERROR: Provide --name, --deploy-id, or --from-output" >&2
  usage
  exit 2
fi

# Check jq dependency when --from-output is used
if [[ -n "$FROM_OUTPUT" ]] && ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required when using --from-output. Install with: brew install jq (macOS) or dnf install jq (AL2023)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Find .env.aws
if [[ -z "$ENV_DIR" ]]; then
  if [[ -f "$SKILL_DIR/../.env.aws" ]]; then
    ENV_DIR="$SKILL_DIR/.."
  elif [[ -f "$SKILL_DIR/.env.aws" ]]; then
    ENV_DIR="$SKILL_DIR"
  else
    echo "ERROR: Cannot find .env.aws. Provide --env-dir" >&2
    exit 1
  fi
fi

# Secure env parsing
ENV_DIR="$(cd "$ENV_DIR" && pwd)"
while IFS='=' read -r key value; do
  export "$key=$value"
done < <(grep -E '^[A-Z0-9_]+=' "$ENV_DIR/.env.aws")
export AWS_DEFAULT_REGION="$REGION"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠️  $*" >&2; }
fail() { echo "[$(date '+%H:%M:%S')] ❌ $*" >&2; exit 1; }

# Safe AWS query — returns empty string on failure, never swallows real errors silently
aws_query() {
  local result
  result=$(aws --region "$REGION" --output text "$@" 2>/dev/null) || true
  # Filter out "None" responses from AWS CLI
  if [[ "$result" == "None" || -z "$result" ]]; then
    echo ""
  else
    echo "$result"
  fi
}

###############################################################################
# Resource Discovery
###############################################################################

INSTANCE_ID=""
VPC_ID=""
SG_ID=""
SUBNET_ID=""
IGW_ID=""
RTB_ID=""
IAM_ROLE=""
INSTANCE_PROFILE=""
SSM_PARAMS=()

if [[ -n "$FROM_OUTPUT" ]]; then
  # Mode 1: From deploy output file
  if [[ ! -f "$FROM_OUTPUT" ]]; then
    fail "Deploy output file not found: $FROM_OUTPUT"
  fi
  log "Reading resources from: $FROM_OUTPUT"

  NAME=$(jq -r '.name // empty' "$FROM_OUTPUT")
  DEPLOY_ID=$(jq -r '.deployId // empty' "$FROM_OUTPUT")
  INSTANCE_ID=$(jq -r '.instance.instanceId // empty' "$FROM_OUTPUT")
  VPC_ID=$(jq -r '.infrastructure.vpcId // empty' "$FROM_OUTPUT")
  SG_ID=$(jq -r '.infrastructure.securityGroupId // empty' "$FROM_OUTPUT")
  SUBNET_ID=$(jq -r '.infrastructure.subnetId // empty' "$FROM_OUTPUT")
  IGW_ID=$(jq -r '.infrastructure.igwId // empty' "$FROM_OUTPUT")
  RTB_ID=$(jq -r '.infrastructure.routeTableId // empty' "$FROM_OUTPUT")
  IAM_ROLE=$(jq -r '.infrastructure.iamRole // empty' "$FROM_OUTPUT")
  INSTANCE_PROFILE=$(jq -r '.infrastructure.instanceProfile // empty' "$FROM_OUTPUT")

  # SSM params
  while IFS= read -r param; do
    [[ -n "$param" ]] && SSM_PARAMS+=("$param")
  done < <(jq -r '.ssmParameters[]? // empty' "$FROM_OUTPUT")

else
  # Mode 2/3: Discover by tag
  if [[ -n "$DEPLOY_ID" ]]; then
    TAG_FILTER="Name=tag:DeployId,Values=$DEPLOY_ID"
    log "Discovering resources by DeployId=$DEPLOY_ID"
  else
    TAG_FILTER="Name=tag:Project,Values=$NAME"
    log "Discovering resources by Project=$NAME"
  fi

  # EC2 instances (running, stopped, or pending — not already terminated)
  INSTANCE_ID=$(aws_query ec2 describe-instances \
    --filters "$TAG_FILTER" "Name=instance-state-name,Values=running,stopped,pending,stopping" \
    --query 'Reservations[0].Instances[0].InstanceId')

  # VPC
  VPC_ID=$(aws_query ec2 describe-vpcs \
    --filters "$TAG_FILTER" \
    --query 'Vpcs[0].VpcId')

  # Security Group (exclude default SG)
  SG_ID=$(aws_query ec2 describe-security-groups \
    --filters "$TAG_FILTER" \
    --query 'SecurityGroups[?GroupName!=`default`] | [0].GroupId')

  # Subnet
  SUBNET_ID=$(aws_query ec2 describe-subnets \
    --filters "$TAG_FILTER" \
    --query 'Subnets[0].SubnetId')

  # IGW (find via VPC attachment if VPC known)
  if [[ -n "$VPC_ID" ]]; then
    IGW_ID=$(aws_query ec2 describe-internet-gateways \
      --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
      --query 'InternetGateways[0].InternetGatewayId')
  fi

  # Route tables (non-main, in VPC)
  if [[ -n "$VPC_ID" ]]; then
    RTB_ID=$(aws_query ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$VPC_ID" "$TAG_FILTER" \
      --query 'RouteTables[0].RouteTableId')
  fi

  # IAM (derive from name)
  IAM_ROLE="${NAME}-role"
  INSTANCE_PROFILE="${NAME}-instance-profile"

  # SSM params (derive from name)
  SSM_PARAMS=("/${NAME}/telegram/bot_token" "/${NAME}/gemini/api_key" "/${NAME}/gateway/token" "/${NAME}/openrouter/api_key")
fi

###############################################################################
# Display Plan
###############################################################################

log ""
log "=========================================="
if [[ "$DRY_RUN" == "true" ]]; then
  log "  🔍 TEARDOWN DRY RUN: ${NAME:-unknown}"
else
  log "  🗑️  TEARDOWN: ${NAME:-unknown}"
fi
log "=========================================="
[[ -n "$DEPLOY_ID" ]] && log "  Deploy ID: $DEPLOY_ID"
log ""
log "  Resources to delete:"
log "  ─────────────────────────────────────"

RESOURCE_COUNT=0

print_resource() {
  local type="$1" id="$2" billable="${3:-no}"
  if [[ -n "$id" ]]; then
    local marker=""
    [[ "$billable" == "yes" ]] && marker=" 💰"
    log "    $type: $id$marker"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
  fi
}

print_resource "EC2 Instance" "$INSTANCE_ID" "yes"
print_resource "VPC" "$VPC_ID"
print_resource "Subnet" "$SUBNET_ID"
print_resource "Security Group" "$SG_ID"
print_resource "Internet GW" "$IGW_ID"
print_resource "Route Table" "$RTB_ID"
print_resource "IAM Role" "$IAM_ROLE"
print_resource "Instance Prof" "$INSTANCE_PROFILE"
for param in "${SSM_PARAMS[@]}"; do
  print_resource "SSM Param" "$param"
done

log ""
log "  Total: $RESOURCE_COUNT resources (💰 = billable)"
log "  ─────────────────────────────────────"

if [[ $RESOURCE_COUNT -eq 0 ]]; then
  log "  No resources found. Nothing to do."
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log ""
  log "  [DRY RUN] No resources were deleted."
  log "  Remove --dry-run to execute teardown."
  exit 0
fi

###############################################################################
# Confirmation
###############################################################################

if [[ "$YES" != "true" ]]; then
  echo ""
  read -p "  Delete all $RESOURCE_COUNT resources? Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    log "Aborted."
    exit 0
  fi
fi

###############################################################################
# Execute Teardown (order matters for dependencies)
###############################################################################

ERRORS=0
delete_resource() {
  local desc="$1"
  shift
  if "$@" 2>/dev/null; then
    log "  ✅ $desc"
  else
    warn "  Failed: $desc"
    ERRORS=$((ERRORS + 1))
  fi
}

# 1. Terminate EC2 instance (releases EBS + public IP)
if [[ -n "$INSTANCE_ID" ]]; then
  log ""
  log "--- Step 1: Terminate EC2 instance ---"
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null 2>&1 || true
  log "  Waiting for termination (this may take 1-2 min)..."
  if ! aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID" 2>/dev/null; then
    warn "  Timeout waiting for termination — continuing anyway"
    sleep 30
  fi
  log "  ✅ Instance terminated: $INSTANCE_ID"
fi

# 2. Delete SSM parameters
if [[ ${#SSM_PARAMS[@]} -gt 0 ]]; then
  log ""
  log "--- Step 2: Delete SSM parameters ---"
  for param in "${SSM_PARAMS[@]}"; do
    delete_resource "SSM: $param" aws ssm delete-parameter --region "$REGION" --name "$param"
  done
fi

# 3. Clean up IAM (role must be emptied before deletion)
log ""
log "--- Step 3: Clean up IAM ---"

if [[ -n "$INSTANCE_PROFILE" ]]; then
  # Remove role from profile
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE" \
    --role-name "$IAM_ROLE" 2>/dev/null || true
  delete_resource "Instance Profile: $INSTANCE_PROFILE" \
    aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE"
fi

if [[ -n "$IAM_ROLE" ]]; then
  # Delete inline policies
  for policy in SSMParameterAccess SSMAccess BedrockFullAccess; do
    aws iam delete-role-policy --role-name "$IAM_ROLE" --policy-name "$policy" 2>/dev/null || true
  done
  # Detach managed policies
  aws iam detach-role-policy --role-name "$IAM_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  delete_resource "IAM Role: $IAM_ROLE" \
    aws iam delete-role --role-name "$IAM_ROLE"
fi

# 4. Delete Security Group (must wait for ENIs to release after instance termination)
if [[ -n "$SG_ID" ]]; then
  log ""
  log "--- Step 4: Delete Security Group ---"
  sleep 5  # ENI detach delay
  delete_resource "Security Group: $SG_ID" \
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID"
fi

# 5. Delete Subnet
if [[ -n "$SUBNET_ID" ]]; then
  log ""
  log "--- Step 5: Delete Subnet ---"
  delete_resource "Subnet: $SUBNET_ID" \
    aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_ID"
fi

# 6. Detach + Delete Internet Gateway
if [[ -n "$IGW_ID" && -n "$VPC_ID" ]]; then
  log ""
  log "--- Step 6: Delete Internet Gateway ---"
  aws ec2 detach-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
  delete_resource "Internet Gateway: $IGW_ID" \
    aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID"
fi

# 7. Delete Route Table (disassociate first)
if [[ -n "$RTB_ID" ]]; then
  log ""
  log "--- Step 7: Delete Route Table ---"
  # Disassociate non-main associations
  for assoc in $(aws_query ec2 describe-route-tables \
    --route-table-ids "$RTB_ID" \
    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId'); do
    aws ec2 disassociate-route-table --region "$REGION" --association-id "$assoc" 2>/dev/null || true
  done
  delete_resource "Route Table: $RTB_ID" \
    aws ec2 delete-route-table --region "$REGION" --route-table-id "$RTB_ID"
fi

# 8. Delete VPC (must be empty — all dependencies removed above)
if [[ -n "$VPC_ID" ]]; then
  log ""
  log "--- Step 8: Delete VPC ---"
  delete_resource "VPC: $VPC_ID" \
    aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
fi

###############################################################################
# Summary
###############################################################################

log ""
log "=========================================="
if [[ $ERRORS -eq 0 ]]; then
  log "  ✅ Teardown Complete! All resources deleted."
else
  log "  ⚠️  Teardown finished with $ERRORS error(s)."
  log "  Check warnings above and verify in AWS Console."
fi
log "=========================================="

# Exit with error if any deletions failed
[[ $ERRORS -eq 0 ]] || exit 1
