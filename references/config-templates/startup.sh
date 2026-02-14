#!/bin/bash
# OpenClaw AWS Startup Script
# This script is called by systemd to start the OpenClaw gateway

set -e

# Configuration
export HOME="/home/openclaw"
OPENCLAW_HOME="/home/openclaw/.openclaw"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

log "Starting OpenClaw startup sequence..."

# Set PATH
export PATH="/usr/local/bin:/usr/bin:$PATH"

# Limit Node.js heap (512MB is enough for t4g.small)
export NODE_OPTIONS="--max-old-space-size=512"

# Verify Node.js
NODE_VERSION=$(node --version)
log "Node.js version: $NODE_VERSION"

# Verify OpenClaw
OPENCLAW_PATH=$(which openclaw)
log "OpenClaw path: $OPENCLAW_PATH"

# Set AWS region (for SSM and Bedrock)
export AWS_DEFAULT_REGION="us-east-1"
export AWS_REGION="us-east-1"

# Change to OpenClaw directory
cd "$OPENCLAW_HOME"

# Start gateway in FOREGROUND mode
# Note: We use 'run' not 'start' because 'start' tries systemctl --user
log "Starting OpenClaw gateway (foreground)..."
exec openclaw gateway run --allow-unconfigured
