#!/usr/bin/env bash
# ABOUTME: Captures a real /usage API response for fixture-making.
# ABOUTME: Writes raw output to spike-raw/ (gitignored); sanitize before committing.
set -euo pipefail
SERVICE="${1:?usage: spike.sh <keychain-service-name>}"
mkdir -p spike-raw
TOKEN=$(security find-generic-password -s "$SERVICE" -w | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
curl -sS https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Accept: application/json" | python3 -m json.tool | tee spike-raw/usage-response.json
