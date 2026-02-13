#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [options]
  --host <ssm-instance-id>      Required EC2 instance id managed by SSM
  --region <aws-region>         Required
  --openclaw-version <version>  OpenClaw npm version (default: latest)
  --gateway-port <port>         Gateway port (default: 18789)
  -h, --help
USAGE
}

HOST=""
REGION=""
OPENCLAW_VERSION="latest"
GATEWAY_PORT="18789"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --openclaw-version) OPENCLAW_VERSION="${2:-}"; shift 2 ;;
    --gateway-port) GATEWAY_PORT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$HOST" ]] || { echo "--host required" >&2; exit 1; }
[[ -n "$REGION" ]] || { echo "--region required" >&2; exit 1; }

read -r -d '' COMMANDS <<SCRIPT || true
set -euo pipefail
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
  dnf install -y nodejs || yum install -y nodejs
fi
npm install -g openclaw@${OPENCLAW_VERSION}
mkdir -p /etc/openclaw /var/lib/openclaw /var/log/openclaw
cat >/etc/systemd/system/openclaw-gateway.service <<'UNIT'
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/env openclaw gateway start
ExecStop=/usr/bin/env openclaw gateway stop
Restart=on-failure
RestartSec=5
Environment=OPENCLAW_HOME=/var/lib/openclaw
Environment=OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable openclaw-gateway
systemctl restart openclaw-gateway
systemctl is-active openclaw-gateway
SCRIPT

CMD_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$HOST" \
  --document-name "AWS-RunShellScript" \
  --comment "Bootstrap OpenClaw host" \
  --parameters commands="$COMMANDS" \
  --query 'Command.CommandId' --output text)

echo "SSM command sent: $CMD_ID"
aws ssm wait command-executed --region "$REGION" --command-id "$CMD_ID" --instance-id "$HOST"
STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$HOST" --query 'Status' --output text)
echo "Bootstrap status: $STATUS"
[[ "$STATUS" == "Success" ]] || exit 1
