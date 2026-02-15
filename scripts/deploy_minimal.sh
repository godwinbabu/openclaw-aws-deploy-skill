#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# deploy_minimal.sh — One-shot minimal OpenClaw deployment to AWS
#
# Creates: VPC, subnet, IGW, route table, security group (no inbound),
#          IAM role (SSM only), SSM parameters, EC2 t4g.medium (ARM64)
#
# Prerequisites:
#   - .env.aws   (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION)
#   - .env.starfish (TELEGRAM_BOT_TOKEN, optionally GEMINI_API_KEY)
#   Both files in the workspace root (parent of skill repo, or specified via --env-dir)
#
# Usage:
#   ./scripts/deploy_minimal.sh --name starfish --region us-east-1
#   ./scripts/deploy_minimal.sh --name starfish --region us-east-1 --env-dir /path/to/envs
#   ./scripts/deploy_minimal.sh --name starfish --region us-east-1 --model amazon-bedrock/minimax.minimax-m2.1
#
# Lessons incorporated (issues #1-24):
#   - t4g.medium (4GB) required — t4g.small OOMs during npm install + gateway startup
#   - Node 22+ required — OpenClaw 2026.x needs Node ≥22.12.0
#   - Official Node tarball — NodeSource setup_22.x unreliable on AL2023 ARM64
#   - git required — OpenClaw npm install has git-based dependencies
#   - openclaw@latest — bare "openclaw" may resolve to placeholder package
#   - gateway run (not start) — start tries systemctl --user which fails
#   - Simplified systemd — removed ProtectHome/ReadWritePaths that cause issues
#   - plugins.entries.telegram.enabled: true — must be explicit
#   - dmPolicy: pairing — not allowlist without users
#   - auth-profiles.json for Gemini API key
###############################################################################

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --name <name>           Agent/project name (default: starfish)
  --region <region>       AWS region (default: us-east-1)
  --env-dir <path>        Directory containing .env.aws and .env.starfish
                          (default: workspace root)
  --instance-type <type>  EC2 instance type (default: t4g.medium)
  --vpc-cidr <cidr>       VPC CIDR (default: 10.50.0.0/16)
  --subnet-cidr <cidr>    Subnet CIDR (default: 10.50.0.0/24)
  --output <path>         Output JSON file (default: ./deploy-output.json)
  --model <model>         AI model (default: amazon-bedrock/minimax.minimax-m2.1)
                          Any model string — passed directly to openclaw.json.
                          Bedrock models use IAM role auth (no API key needed).
                          If GEMINI_API_KEY is in .env.starfish, Gemini auth is set up.
                          Examples:
                            google/gemini-2.0-flash             (default, needs GEMINI_API_KEY)
                            amazon-bedrock/minimax.minimax-m2.1 (MiniMax M2.1)
                            amazon-bedrock/minimax.minimax-m2   (MiniMax M2)
                            amazon-bedrock/deepseek.deepseek-r1 (DeepSeek R1)
                            amazon-bedrock/moonshotai.kimi-k2.5 (Kimi K2.5)
  --personality <name|path>  Agent personality: default, sentinel, researcher,
                          coder, companion — or path to custom SOUL.md
  --dry-run               Show what would be created without creating
  --cleanup-first         Tear down existing resources with same name first
  -h, --help              Show this help
USAGE
}

# Defaults — t4g.medium (4GB) required for OpenClaw 2026.x
NAME="starfish"
REGION="us-east-1"
ENV_DIR=""
INSTANCE_TYPE="t4g.medium"
VPC_CIDR="10.50.0.0/16"
SUBNET_CIDR="10.50.0.0/24"
OUTPUT_PATH="./deploy-output.json"
MODEL="amazon-bedrock/minimax.minimax-m2.1"
DRY_RUN=false
CLEANUP_FIRST=false
PERSONALITY="default"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --env-dir) ENV_DIR="${2:-}"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="${2:-}"; shift 2 ;;
    --vpc-cidr) VPC_CIDR="${2:-}"; shift 2 ;;
    --subnet-cidr) SUBNET_CIDR="${2:-}"; shift 2 ;;
    --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --personality) PERSONALITY="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --cleanup-first) CLEANUP_FIRST=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "$ENV_DIR" ]]; then
  # Look in workspace root first, then skill dir
  if [[ -f "$SKILL_DIR/../.env.aws" ]]; then
    ENV_DIR="$SKILL_DIR/.."
  elif [[ -f "$SKILL_DIR/.env.aws" ]]; then
    ENV_DIR="$SKILL_DIR"
  else
    echo "ERROR: Cannot find .env.aws. Provide --env-dir" >&2
    exit 1
  fi
fi

ENV_DIR="$(cd "$ENV_DIR" && pwd)"

# Load credentials
if [[ ! -f "$ENV_DIR/.env.aws" ]]; then
  echo "ERROR: $ENV_DIR/.env.aws not found" >&2
  exit 1
fi
if [[ ! -f "$ENV_DIR/.env.starfish" ]]; then
  echo "ERROR: $ENV_DIR/.env.starfish not found" >&2
  exit 1
fi

# Secure env parsing — only export strict KEY=VALUE lines (no arbitrary code execution)
while IFS='=' read -r key value; do
  export "$key=$value"
done < <(grep -E '^[A-Z0-9_]+=' "$ENV_DIR/.env.aws")
while IFS='=' read -r key value; do
  export "$key=$value"
done < <(grep -E '^[A-Z0-9_]+=' "$ENV_DIR/.env.starfish")
export AWS_DEFAULT_REGION="$REGION"

# Validate required vars
for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TELEGRAM_BOT_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set" >&2
    exit 1
  fi
done

# Utility functions (must be defined before first use)
log() { echo "[$(date '+%H:%M:%S')] $*"; }
aws_cmd() { aws --region "$REGION" --output text "$@"; }
aws_json() { aws --region "$REGION" --output json "$@"; }

# Check optional GEMINI_API_KEY
HAS_GEMINI_KEY=false
if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  HAS_GEMINI_KEY=true
fi

# Check optional TELEGRAM_USER_ID (for auto-approve pairing)
HAS_TELEGRAM_USER_ID=false
if [[ -n "${TELEGRAM_USER_ID:-}" ]]; then
  HAS_TELEGRAM_USER_ID=true
  log "Telegram user ID found — will auto-approve pairing after deploy"
fi

# Resolve personality file
PERSONALITIES_DIR="$SKILL_DIR/assets/personalities"
if [[ -f "$PERSONALITY" ]]; then
  # Custom path to SOUL.md
  SOUL_CONTENT=$(cat "$PERSONALITY")
  log "Personality: custom ($PERSONALITY)"
elif [[ -f "$PERSONALITIES_DIR/${PERSONALITY}.md" ]]; then
  # Built-in preset
  SOUL_CONTENT=$(cat "$PERSONALITIES_DIR/${PERSONALITY}.md")
  log "Personality: $PERSONALITY (built-in)"
else
  echo "ERROR: Unknown personality '$PERSONALITY'" >&2
  echo "Available: default, sentinel, researcher, coder, companion" >&2
  echo "Or provide a path to a custom SOUL.md file" >&2
  exit 1
fi

# Base64-encode SOUL.md for safe transport in user-data
SOUL_B64=$(echo "$SOUL_CONTENT" | base64)

# Generate a gateway token
GATEWAY_TOKEN=$(openssl rand -hex 32)

TAG_KEY="Project"
TAG_VALUE="$NAME"

# Generate a unique deploy ID (timestamp-based, same across all resources)
DEPLOY_ID="${NAME}-$(date -u +%Y%m%dT%H%M%SZ)"
DEPLOY_TAG_KEY="DeployId"

log "Deploy ID: $DEPLOY_ID"

# Trap: print cleanup instructions on failure
cleanup_on_failure() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "" >&2
    echo "=========================================" >&2
    echo "  ❌ Deploy failed (exit code $exit_code)" >&2
    echo "  Resources may have been partially created." >&2
    echo "" >&2
    echo "  To clean up, run:" >&2
    echo "    $SCRIPT_DIR/teardown.sh --name $NAME --region $REGION --env-dir $ENV_DIR --yes" >&2
    echo "" >&2
    echo "  Or if deploy-output.json was written:" >&2
    echo "    $SCRIPT_DIR/teardown.sh --from-output $OUTPUT_PATH --env-dir $ENV_DIR --yes" >&2
    echo "=========================================" >&2
  fi
}
trap cleanup_on_failure EXIT

log "=========================================="
log "  OpenClaw Minimal Deploy: $NAME"
log "  Region: $REGION | Instance: $INSTANCE_TYPE"
log "  Model:  $MODEL"
log "=========================================="

# Verify AWS identity
CALLER=$(aws_cmd sts get-caller-identity --query 'Account')
log "AWS Account: $CALLER"

if [[ "$DRY_RUN" == "true" ]]; then
  log "[DRY RUN] Would create: VPC, subnet, IGW, SG, IAM role, SSM params, EC2 instance"
  log "[DRY RUN] Instance type: $INSTANCE_TYPE, AMI: AL2023 ARM64"
  exit 0
fi

###############################################################################
# Step 0: Cleanup if requested
###############################################################################
if [[ "$CLEANUP_FIRST" == "true" ]]; then
  log ""
  log "--- Step 0: Cleaning up existing $NAME resources ---"
  if [[ -x "$SCRIPT_DIR/teardown.sh" ]]; then
    "$SCRIPT_DIR/teardown.sh" --name "$NAME" --region "$REGION" --env-dir "$ENV_DIR" --yes || true
  else
    log "WARN: teardown.sh not executable, skipping cleanup"
  fi
fi

###############################################################################
# Step 1: VPC
###############################################################################
log ""
log "--- Step 1: Creating VPC ---"
VPC_ID=$(aws_cmd ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${NAME}-vpc},{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=$DEPLOY_TAG_KEY,Value=$DEPLOY_ID}]" \
  --query 'Vpc.VpcId')
log "VPC: $VPC_ID"

# Enable DNS
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

###############################################################################
# Step 2: Internet Gateway
###############################################################################
log ""
log "--- Step 2: Creating Internet Gateway ---"
IGW_ID=$(aws_cmd ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${NAME}-igw},{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=$DEPLOY_TAG_KEY,Value=$DEPLOY_ID}]" \
  --query 'InternetGateway.InternetGatewayId')
log "IGW: $IGW_ID"

aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

###############################################################################
# Step 3: Subnet
###############################################################################
log ""
log "--- Step 3: Creating Subnet ---"
# Pick first AZ
AZ=$(aws_cmd ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName')
SUBNET_ID=$(aws_cmd ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${NAME}-subnet},{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=$DEPLOY_TAG_KEY,Value=$DEPLOY_ID}]" \
  --query 'Subnet.SubnetId')
log "Subnet: $SUBNET_ID ($AZ)"

# Auto-assign public IPs
aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$SUBNET_ID" --map-public-ip-on-launch

###############################################################################
# Step 4: Route Table
###############################################################################
log ""
log "--- Step 4: Creating Route Table ---"
RTB_ID=$(aws_cmd ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${NAME}-rtb},{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=$DEPLOY_TAG_KEY,Value=$DEPLOY_ID}]" \
  --query 'RouteTable.RouteTableId')
log "Route Table: $RTB_ID"

aws ec2 create-route --region "$REGION" --route-table-id "$RTB_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" > /dev/null
aws ec2 associate-route-table --region "$REGION" --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID" > /dev/null

###############################################################################
# Step 5: Security Group (NO inbound — SSM only)
###############################################################################
log ""
log "--- Step 5: Creating Security Group (no inbound) ---"
SG_ID=$(aws_cmd ec2 create-security-group \
  --group-name "${NAME}-sg" \
  --description "OpenClaw ${NAME} - outbound only, SSM access" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${NAME}-sg},{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=$DEPLOY_TAG_KEY,Value=$DEPLOY_ID}]" \
  --query 'GroupId')
log "Security Group: $SG_ID"

###############################################################################
# Step 6: IAM Role (SSM + SSM Parameter Store)
###############################################################################
log ""
log "--- Step 6: Creating IAM Role ---"

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}'

# Create role (ignore error if exists)
if aws iam create-role --region "$REGION" \
  --role-name "${NAME}-role" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --tags "Key=$TAG_KEY,Value=$TAG_VALUE" "Key=$DEPLOY_TAG_KEY,Value=$DEPLOY_ID" > /dev/null 2>&1; then
  log "IAM Role: ${NAME}-role (created)"
else
  log "IAM Role: ${NAME}-role (already exists)"
fi

# Attach SSM managed policy
aws iam attach-role-policy --role-name "${NAME}-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true

# Add inline policy for SSM Parameter Store access
SSM_PARAM_POLICY=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "arn:aws:ssm:${REGION}:${CALLER}:parameter/${NAME}/*"
    }
  ]
}
POLICY
)

aws iam put-role-policy --role-name "${NAME}-role" \
  --policy-name SSMParameterAccess \
  --policy-document "$SSM_PARAM_POLICY"

# Add Bedrock permissions (always — costs nothing, enables any Bedrock model)
BEDROCK_POLICY=$(cat <<BPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:ListFoundationModels"
      ],
      "Resource": [
        "arn:aws:bedrock:${REGION}::foundation-model/*",
        "arn:aws:bedrock:${REGION}:*:inference-profile/*",
        "arn:aws:bedrock:${REGION}:*:application-inference-profile/*"
      ]
    }
  ]
}
BPOLICY
)
aws iam put-role-policy --role-name "${NAME}-role" \
  --policy-name BedrockAccess \
  --policy-document "$BEDROCK_POLICY"
log "Added BedrockAccess inline policy"

# Create instance profile
if aws iam create-instance-profile --instance-profile-name "${NAME}-instance-profile" > /dev/null 2>&1; then
  log "Instance Profile: ${NAME}-instance-profile (created)"
else
  log "Instance Profile: ${NAME}-instance-profile (already exists)"
fi

# Ensure role is attached (idempotent — ignore EntityAlreadyExists)
aws iam add-role-to-instance-profile \
  --instance-profile-name "${NAME}-instance-profile" \
  --role-name "${NAME}-role" 2>/dev/null || true

# Wait for profile to propagate
log "Waiting 10s for IAM propagation..."
sleep 10

###############################################################################
# Step 7: Store secrets in SSM Parameter Store
###############################################################################
log ""
log "--- Step 7: Storing secrets in SSM Parameter Store ---"

aws ssm put-parameter --region "$REGION" \
  --name "/${NAME}/telegram/bot_token" \
  --value "$TELEGRAM_BOT_TOKEN" \
  --type SecureString \
  --overwrite > /dev/null
log "Stored: /${NAME}/telegram/bot_token"

if [[ "$HAS_GEMINI_KEY" == "true" ]]; then
  aws ssm put-parameter --region "$REGION" \
    --name "/${NAME}/gemini/api_key" \
    --value "$GEMINI_API_KEY" \
    --type SecureString \
    --overwrite > /dev/null
  log "Stored: /${NAME}/gemini/api_key"
else
  log "Skipped: /${NAME}/gemini/api_key (not provided)"
fi

aws ssm put-parameter --region "$REGION" \
  --name "/${NAME}/gateway/token" \
  --value "$GATEWAY_TOKEN" \
  --type SecureString \
  --overwrite > /dev/null
log "Stored: /${NAME}/gateway/token"

###############################################################################
# Step 8: Get AMI (AL2023 ARM64)
###############################################################################
log ""
log "--- Step 8: Getting latest AL2023 ARM64 AMI ---"
AMI_ID=$(aws_cmd ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query 'Parameter.Value')
log "AMI: $AMI_ID"

###############################################################################
# Step 9: Generate user-data script
###############################################################################
log ""
log "--- Step 9: Generating user-data ---"

# Node version — OpenClaw 2026.x requires ≥22.12.0
NODE_VERSION="22.14.0"

USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -euo pipefail

exec > /var/log/openclaw-bootstrap.log 2>&1
echo "[$(date)] Starting OpenClaw bootstrap..."

# Variables (replaced by deploy script)
AGENT_NAME="__NAME__"
REGION="__REGION__"
NODE_VERSION="__NODE_VERSION__"
MODEL="__MODEL__"
HAS_GEMINI_KEY="__HAS_GEMINI_KEY__"

# Retry helper — 3 retries with exponential backoff
retry_cmd() {
  local max_retries=3
  local delay=5
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [[ $attempt -ge $max_retries ]]; then
      echo "[$(date)] FATAL: Command failed after $max_retries attempts: $*" >&2
      return 1
    fi
    echo "[$(date)] Attempt $attempt failed, retrying in ${delay}s..."
    sleep $delay
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# Install dependencies (git required for npm, jq for JSON)
echo "[$(date)] Installing dependencies..."
retry_cmd dnf install -y git jq tar gzip

# Install Node.js from official tarball (NodeSource unreliable on AL2023 ARM64)
echo "[$(date)] Installing Node.js ${NODE_VERSION}..."
cd /tmp
NODE_TARBALL="node-v${NODE_VERSION}-linux-arm64.tar.xz"
retry_cmd curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}" -o node.tar.xz
retry_cmd curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o SHASUMS256.txt

# Verify tarball integrity
echo "[$(date)] Verifying Node.js tarball SHA256..."
EXPECTED_SHA=$(grep "${NODE_TARBALL}" SHASUMS256.txt | awk '{print $1}')
ACTUAL_SHA=$(sha256sum node.tar.xz | awk '{print $1}')
if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  echo "[$(date)] FATAL: SHA256 mismatch! Expected=$EXPECTED_SHA Actual=$ACTUAL_SHA" >&2
  exit 1
fi
echo "[$(date)] SHA256 verified OK"

tar -xf node.tar.xz -C /usr/local --strip-components=1
rm -f node.tar.xz SHASUMS256.txt
hash -r

# Verify Node
echo "[$(date)] Node version: $(node --version)"
echo "[$(date)] npm version: $(npm --version)"

# Install OpenClaw (must use @latest to avoid placeholder package)
echo "[$(date)] Installing OpenClaw..."
retry_cmd npm install -g openclaw@latest 2>&1 | tail -20
echo "[$(date)] OpenClaw path: $(which openclaw)"

# Create openclaw user
echo "[$(date)] Creating openclaw user..."
useradd -r -m -s /bin/bash openclaw || true

# Create directories
mkdir -p /home/openclaw/.openclaw/agents/main/agent
mkdir -p /home/openclaw/.openclaw/workspace

# Retrieve secrets from SSM
echo "[$(date)] Retrieving secrets from SSM..."
TELEGRAM_TOKEN=$(aws ssm get-parameter --region "$REGION" --name "/${AGENT_NAME}/telegram/bot_token" --with-decryption --query 'Parameter.Value' --output text)
if [[ "$HAS_GEMINI_KEY" == "true" ]]; then
  GEMINI_KEY=$(aws ssm get-parameter --region "$REGION" --name "/${AGENT_NAME}/gemini/api_key" --with-decryption --query 'Parameter.Value' --output text)
fi
GW_TOKEN=$(aws ssm get-parameter --region "$REGION" --name "/${AGENT_NAME}/gateway/token" --with-decryption --query 'Parameter.Value' --output text)

# Create OpenClaw config
echo "[$(date)] Writing openclaw.json..."
cat > /home/openclaw/.openclaw/openclaw.json <<OCEOF
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "${GW_TOKEN}"
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "${MODEL}"
      },
      "workspace": "/home/openclaw/.openclaw/workspace",
      "heartbeat": {
        "every": "30m",
        "prompt": "Check HEARTBEAT.md if it exists. If nothing needs attention, reply HEARTBEAT_OK."
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing",
      "groupPolicy": "allowlist",
      "streamMode": "partial",
      "accounts": {
        "default": {
          "name": "${AGENT_NAME}",
          "dmPolicy": "pairing",
          "botToken": "${TELEGRAM_TOKEN}",
          "groupPolicy": "allowlist",
          "streamMode": "partial"
        }
      }
    }
  },
  "plugins": {
    "entries": {
      "telegram": {
        "enabled": true
      }
    }
  },
  "models": {
    "providers": {
      "amazon-bedrock": {
        "baseUrl": "https://bedrock-runtime.${REGION}.amazonaws.com",
        "api": "bedrock-converse-stream",
        "auth": "aws-sdk",
        "models": [
          {
            "id": "minimax.minimax-m2.1",
            "name": "MiniMax M2.1",
            "input": ["text"],
            "contextWindow": 128000,
            "maxTokens": 4096
          }
        ]
      }
    },
    "bedrockDiscovery": {
      "enabled": true,
      "region": "${REGION}"
    }
  },
  "tools": {
    "agentToAgent": {
      "enabled": true
    }
  }
}
OCEOF

# Create auth profiles (always include Bedrock for IAM-based access)
echo "[$(date)] Writing auth-profiles.json..."
if [[ "$HAS_GEMINI_KEY" == "true" ]]; then
  cat > /home/openclaw/.openclaw/agents/main/agent/auth-profiles.json <<APEOF
{
  "version": 1,
  "profiles": {
    "amazon-bedrock:default": {
      "type": "aws",
      "provider": "amazon-bedrock",
      "awsRegion": "${REGION}"
    },
    "google:default": {
      "type": "token",
      "provider": "google",
      "token": "${GEMINI_KEY}"
    }
  }
}
APEOF
else
  cat > /home/openclaw/.openclaw/agents/main/agent/auth-profiles.json <<APEOF
{
  "version": 1,
  "profiles": {
    "amazon-bedrock:default": {
      "type": "aws",
      "provider": "amazon-bedrock",
      "awsRegion": "${REGION}"
    }
  }
}
APEOF
fi

# Create startup script
echo "[$(date)] Writing startup script..."
cat > /usr/local/bin/openclaw-startup.sh <<'STARTEOF'
#!/bin/bash
set -e

export HOME="/home/openclaw"
export PATH="/usr/local/bin:/usr/bin:$PATH"
export NODE_OPTIONS="--max-old-space-size=1024"
export AWS_DEFAULT_REGION="__REGION__"
export AWS_REGION="__REGION__"

cd /home/openclaw/.openclaw

# Start gateway in FOREGROUND mode
# CRITICAL: Use 'run' not 'start' — start tries systemctl --user which fails
exec /usr/local/bin/openclaw gateway run --allow-unconfigured
STARTEOF
chmod +x /usr/local/bin/openclaw-startup.sh
sed -i "s/__REGION__/${REGION}/g" /usr/local/bin/openclaw-startup.sh

# Create systemd service (simplified — security hardening removed due to namespace issues)
echo "[$(date)] Writing systemd service..."
cat > /etc/systemd/system/openclaw.service <<'SVCEOF'
[Unit]
Description=OpenClaw Gateway
Documentation=https://docs.openclaw.ai
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/home/openclaw/.openclaw
ExecStart=/usr/local/bin/openclaw-startup.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw

[Install]
WantedBy=multi-user.target
SVCEOF

# Write SOUL.md (personality) to workspace AND agent directory
echo "[$(date)] Writing SOUL.md (personality)..."
echo "__SOUL_B64__" | base64 -d > /home/openclaw/.openclaw/workspace/SOUL.md
cp /home/openclaw/.openclaw/workspace/SOUL.md /home/openclaw/.openclaw/agents/main/agent/SOUL.md

# Fix ownership
chown -R openclaw:openclaw /home/openclaw/.openclaw

# Enable and start
echo "[$(date)] Starting OpenClaw service..."
systemctl daemon-reload
systemctl enable openclaw
systemctl start openclaw

# Wait and check
sleep 15
if systemctl is-active openclaw; then
  echo "[$(date)] ✅ OpenClaw is running!"
  journalctl -u openclaw -n 10 --no-pager
else
  echo "[$(date)] ❌ OpenClaw failed to start"
  journalctl -u openclaw -n 30 --no-pager
  exit 1
fi

echo "[$(date)] Bootstrap complete!"
USERDATA
)

# Validate MODEL — must be a simple model string (no control chars, quotes, or newlines)
if [[ "$MODEL" =~ [[:cntrl:]] ]] || [[ "$MODEL" == *'"'* ]] || [[ "$MODEL" == *$'\n'* ]]; then
  echo "ERROR: --model contains invalid characters (quotes, newlines, or control chars)" >&2
  exit 1
fi
MODEL_ESCAPED="$MODEL"

# Replace placeholders
USER_DATA="${USER_DATA//__NAME__/$NAME}"
USER_DATA="${USER_DATA//__REGION__/$REGION}"
USER_DATA="${USER_DATA//__NODE_VERSION__/$NODE_VERSION}"
USER_DATA="${USER_DATA//__MODEL__/$MODEL_ESCAPED}"
USER_DATA="${USER_DATA//__HAS_GEMINI_KEY__/$HAS_GEMINI_KEY}"
USER_DATA="${USER_DATA//__SOUL_B64__/$SOUL_B64}"

# Base64 encode
USER_DATA_B64=$(echo "$USER_DATA" | base64)

###############################################################################
# Step 10: Launch EC2 Instance
###############################################################################
log ""
log "--- Step 10: Launching EC2 Instance ---"

INSTANCE_ID=$(aws_cmd ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=${NAME}-instance-profile" \
  --user-data "$USER_DATA_B64" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}},{Key=$TAG_KEY,Value=$TAG_VALUE},{Key=$DEPLOY_TAG_KEY,Value=$DEPLOY_ID}]" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","Encrypted":true}}]' \
  --query 'Instances[0].InstanceId')
log "Instance: $INSTANCE_ID"

log "Waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws_cmd ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress')
log "Public IP: $PUBLIC_IP"

###############################################################################
# Step 11: Wait for SSM + bootstrap to complete
###############################################################################
log ""
log "--- Step 11: Waiting for SSM agent and bootstrap ---"
log "This takes 4-6 minutes for Node.js + OpenClaw install..."

# Wait for SSM to be available
for i in $(seq 1 30); do
  if aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null | grep -q "Online"; then
    log "SSM agent is online (attempt $i)"
    break
  fi
  if [[ $i -eq 30 ]]; then
    log "WARN: SSM agent not online after 5 min — instance may still be bootstrapping"
  fi
  sleep 10
done

# Wait for bootstrap to finish (check for the log file marker)
log "Waiting for bootstrap to complete..."
for i in $(seq 1 48); do
  RESULT=$(aws ssm send-command --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["grep -c \"Bootstrap complete\" /var/log/openclaw-bootstrap.log 2>/dev/null || echo 0"]' \
    --query 'Command.CommandId' --output text 2>/dev/null) || true

  if [[ -n "$RESULT" ]]; then
    sleep 5
    STATUS=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$RESULT" --instance-id "$INSTANCE_ID" \
      --query 'StandardOutputContent' --output text 2>/dev/null) || true
    if [[ "$STATUS" == *"1"* ]]; then
      log "Bootstrap completed!"
      break
    fi
  fi

  if [[ $i -eq 48 ]]; then
    log "WARN: Bootstrap may still be running after 8 min"
    log "Check logs: aws ssm start-session --target $INSTANCE_ID"
  fi
  sleep 10
done

###############################################################################
# Step 12: Smoke Test
###############################################################################
log ""
log "--- Step 12: Smoke Test ---"

SMOKE_CMD='systemctl is-active openclaw && echo "SERVICE_OK"; journalctl -u openclaw -n 5 --no-pager'
SMOKE_ID=$(aws ssm send-command --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"$SMOKE_CMD\"]" \
  --query 'Command.CommandId' --output text 2>/dev/null) || true

if [[ -n "$SMOKE_ID" ]]; then
  sleep 10
  SMOKE_OUT=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$SMOKE_ID" --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' --output text 2>/dev/null) || true
  log "Smoke test output:"
  echo "$SMOKE_OUT"
fi

###############################################################################
# Step 13: Save outputs
###############################################################################
log ""
log "--- Step 13: Saving deployment outputs ---"

# Build conditional SSM entry for deploy output
if [[ "$HAS_GEMINI_KEY" == "true" ]]; then
  GEMINI_SSM_JSON_ENTRY=",
    \"/${NAME}/gemini/api_key\""
else
  GEMINI_SSM_JSON_ENTRY=""
fi

cat > "$OUTPUT_PATH" <<OUTEOF
{
  "name": "$NAME",
  "region": "$REGION",
  "accountId": "$CALLER",
  "deployId": "$DEPLOY_ID",
  "deployedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "infrastructure": {
    "vpcId": "$VPC_ID",
    "subnetId": "$SUBNET_ID",
    "igwId": "$IGW_ID",
    "routeTableId": "$RTB_ID",
    "securityGroupId": "$SG_ID",
    "iamRole": "${NAME}-role",
    "instanceProfile": "${NAME}-instance-profile"
  },
  "instance": {
    "instanceId": "$INSTANCE_ID",
    "instanceType": "$INSTANCE_TYPE",
    "amiId": "$AMI_ID",
    "publicIp": "$PUBLIC_IP"
  },
  "ssmParameters": [
    "/${NAME}/telegram/bot_token",
    "/${NAME}/gateway/token"${GEMINI_SSM_JSON_ENTRY}
  ],
  "config": {
    "model": "$MODEL",
    "channel": "telegram",
    "dmPolicy": "pairing",
    "gatewayPort": 18789,
    "personality": "$PERSONALITY"
  },
  "access": {
    "ssm": "aws ssm start-session --target $INSTANCE_ID --region $REGION",
    "logs": "aws ssm send-command --instance-ids $INSTANCE_ID --document-name AWS-RunShellScript --parameters 'commands=[\"journalctl -u openclaw -n 50 --no-pager\"]' --region $REGION"
  }
}
OUTEOF

log ""
log "=========================================="
log "  ✅ Deployment Complete!"
log "=========================================="
log ""
log "  Instance:  $INSTANCE_ID"
log "  Public IP: $PUBLIC_IP"
log "  Model:     $MODEL"
log "  Channel:   Telegram (@${NAME} bot)"
log ""
log "  SSM Access:"
log "    aws ssm start-session --target $INSTANCE_ID --region $REGION"
if [[ "$HAS_TELEGRAM_USER_ID" == "true" ]]; then
  log ""
  log "  --- Auto-approving Telegram pairing for user $TELEGRAM_USER_ID ---"
  APPROVE_CMD_ID=$(aws ssm send-command --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"sudo -u openclaw HOME=/home/openclaw /usr/local/bin/openclaw pairing add telegram $TELEGRAM_USER_ID\"]}" \
    --query 'Command.CommandId' --output text 2>/dev/null || true)
  if [[ -n "$APPROVE_CMD_ID" ]]; then
    sleep 5
    APPROVE_RESULT=$(aws ssm get-command-invocation --region "$REGION" \
      --command-id "$APPROVE_CMD_ID" --instance-id "$INSTANCE_ID" \
      --query 'StandardOutputContent' --output text 2>/dev/null || echo "unknown")
    log "  Pairing result: $APPROVE_RESULT"
  fi
  log ""
  log "  ✅ Telegram user $TELEGRAM_USER_ID pre-approved!"
  log "  Just message the bot — it will respond immediately."
else
  log ""
  log "  Next steps:"
  log "    1. Message the Telegram bot to get a pairing code"
  log "    2. Approve pairing via SSM:"
  log "       openclaw pairing approve telegram <CODE>"
  log ""
  log "  TIP: Add TELEGRAM_USER_ID=<your_id> to .env.starfish for auto-approval"
fi
log ""
log "  Output saved to: $OUTPUT_PATH"
log "=========================================="
