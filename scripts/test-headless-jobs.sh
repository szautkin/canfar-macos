#!/bin/bash
# Test script: launches a few headless batch jobs to exercise the monitoring widget.
# Usage: ./scripts/test-headless-jobs.sh <bearer-token>
#
# To get your token, check Keychain (service: com.codebg.Verbinal, account: AuthToken)
# or log in via: curl -s -d "username=YOU&password=PASS" https://ws-cadc.canfar.net/ac/login

set -euo pipefail

SKAHA="https://ws-uv.canfar.net/skaha/v1"
IMAGE="images.canfar.net/skaha/terminal:1.1.2"
TOKEN="${1:-}"

# Try reading token from Keychain if not provided
if [ -z "$TOKEN" ]; then
    TOKEN=$(security find-generic-password -s "com.codebg.Verbinal" -a "AuthToken" -w 2>/dev/null || true)
fi

if [ -z "$TOKEN" ]; then
    echo "Usage: $0 [bearer-token]"
    echo ""
    echo "No token provided and none found in Keychain."
    echo "Get a token via:"
    echo "  curl -s -d 'username=YOU&password=PASS' https://ws-cadc.canfar.net/ac/login"
    exit 1
fi

AUTH="Authorization: Bearer $TOKEN"

echo "=== Launching test headless jobs ==="
echo "Image: $IMAGE"
echo ""

launch_job() {
    local name="$1" cmd="$2" label="$3"
    echo "$label"
    local response
    response=$(curl -s -X POST "$SKAHA/session" \
        -H "$AUTH" \
        -d "name=$name&image=$IMAGE&type=headless&cmd=$cmd&resourceType=shared")
    local id
    id=$(echo "$response" | tr -d '[]"' | tr -d '[:space:]')
    # Check if response looks like an ID (alphanumeric) or an error
    if echo "$id" | grep -qE '^[a-z0-9]+$'; then
        echo "   -> ID: $id"
        echo "$id"
    else
        echo "   -> ERROR: $response"
        echo ""
    fi
}

# Job 1: Quick success — runs 'env' and exits immediately
ID1=$(launch_job "quick-success" "env" "1) Launching 'quick-success' (runs env, finishes fast)..." | tee /dev/stderr | tail -1)

# Job 2: Slow runner — sleeps 90s so you can watch it in Running state
ID2=$(launch_job "slow-runner" "sleep%2090" "2) Launching 'slow-runner' (sleeps 90s, stays Running)..." | tee /dev/stderr | tail -1)

# Job 3: Will fail — runs a command that doesn't exist
ID3=$(launch_job "will-fail" "this-command-does-not-exist" "3) Launching 'will-fail' (bad command, should fail)..." | tee /dev/stderr | tail -1)

echo ""
echo "=== Jobs launched ==="
echo ""
echo "Expected behavior in Verbinal:"
echo "  - All 3 appear as Pending, then transition"
echo "  - 'quick-success' -> Completed (within ~1-2 min) -> notification"
echo "  - 'slow-runner'   -> Running for ~90s -> Completed -> notification"
echo "  - 'will-fail'     -> Failed (within ~1 min) -> failure notification"
echo "  - Dock badge shows active count, decreasing as jobs finish"
echo ""

# Show only headless sessions
echo "=== Headless sessions ==="
curl -s -H "$AUTH" "$SKAHA/session" | python3 -c "
import json, sys
sessions = json.load(sys.stdin)
headless = [s for s in sessions if s.get('type') == 'headless']
if not headless:
    print('  (none)')
else:
    for s in headless:
        print(f\"  {s['id']:12s}  {s['name']:20s}  {s['status']:12s}  {s['image'].split('/')[-1]}\")
" 2>/dev/null || curl -s -H "$AUTH" "$SKAHA/session"

echo ""
echo "--- Cleanup later with: ---"
for id in $ID1 $ID2 $ID3; do
    [ -n "$id" ] && echo "  curl -s -X DELETE -H 'Authorization: Bearer ...' $SKAHA/session/$id"
done
