#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --endpoint <url> --gateway-token <token> [--output <path>]
USAGE
}

ENDPOINT=""
TOKEN=""
OUTPUT="./smoke-test-report.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint) ENDPOINT="${2:-}"; shift 2 ;;
    --gateway-token) TOKEN="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ -n "$ENDPOINT" ]] || { echo "--endpoint required" >&2; exit 1; }
[[ -n "$TOKEN" ]] || { echo "--gateway-token required" >&2; exit 1; }

health_status="fail"
auth_status="fail"

if curl -fsS "$ENDPOINT/health" >/dev/null 2>&1; then health_status="pass"; fi
if curl -fsS -H "Authorization: Bearer $TOKEN" "$ENDPOINT" >/dev/null 2>&1; then auth_status="pass"; fi

overall="pass"
if [[ "$health_status" != "pass" || "$auth_status" != "pass" ]]; then
  overall="fail"
fi

mkdir -p "$(dirname "$OUTPUT")"
jq -n \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg overall "$overall" \
  --arg health "$health_status" \
  --arg auth "$auth_status" \
  '{generatedAt:$generatedAt, overall:$overall, checks:{health:$health, auth:$auth}}' > "$OUTPUT"

echo "Smoke report: $OUTPUT"
[[ "$overall" == "pass" ]]
