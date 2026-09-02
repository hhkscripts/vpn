#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT/configs/90-hotspot-vpn-policy"
ROUTES="$ROOT/scripts/github-vpn-routes.sh"

cmp -s "$POLICY" "$ROOT/scripts/vpn-routing.sh"
grep -q 'flock -w 60 9' "$POLICY"
if grep -q 'sleep 5; apply_policy\|sleep 15; apply_policy' "$POLICY"; then
  echo "Policy must not schedule overlapping delayed applies" >&2
  exit 1
fi
# This is a literal source-code pattern, not a shell expression.
# shellcheck disable=SC2016
if grep -q '"\$POLICY_SCRIPT" "\$VPN_IF" up' "$ROUTES"; then
  echo "GitHub refresh must not reapply the VPN policy" >&2
  exit 1
fi
grep -q -- '--retry 3' "$ROUTES"
grep -q -- '--max-time 60' "$ROUTES"
grep -q 'GITHUB_ROUTES_FORCE_REFRESH' "$ROUTES"
grep -q 'Keeping existing GitHub IPv4 ranges' "$ROUTES"

echo "PASS: VPN scripts serialize policy and retry route downloads"
