#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --infra <infra-json> --smoke <smoke-json> [--output <path>]
USAGE
}

INFRA=""
SMOKE=""
OUTPUT="./deployment-summary.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --infra) INFRA="${2:-}"; shift 2 ;;
    --smoke) SMOKE="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

[[ -f "$INFRA" ]] || { echo "infra json missing" >&2; exit 1; }
[[ -f "$SMOKE" ]] || { echo "smoke json missing" >&2; exit 1; }

jq -n --slurpfile infra "$INFRA" --slurpfile smoke "$SMOKE" \
  '{generatedAt:(now|todate), infra:$infra[0], smoke:$smoke[0], ready: ($smoke[0].overall=="pass")}' > "$OUTPUT"

echo "Summary: $OUTPUT"
