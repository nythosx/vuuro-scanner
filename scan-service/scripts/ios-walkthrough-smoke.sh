#!/bin/sh
set -eu

BASE_URL="${SCAN_SERVICE_BASE_URL:-http://127.0.0.1:8089}"
FAILURES=0
CHECKS=0

check() {
    label="$1"
    shift
    CHECKS=$((CHECKS + 1))
    if "$@"; then
        echo "  [PASS] $label"
    else
        FAILURES=$((FAILURES + 1))
        echo "  [FAIL] $label"
    fi
}

http_status() {
    curl -s -o /dev/null -w '%{http_code}' "$@"
}

echo "== Walkthrough recovery — server-side shape checks =="
echo "Target: $BASE_URL"
echo

command -v curl >/dev/null 2>&1 || { echo "curl not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 2; }

suffix="$(date +%s)-$$"

create_response="$(curl -s -X POST "$BASE_URL/scan-sessions" \
    -H 'Content-Type: application/json' \
    -d "{\"property_id\":\"prop-smoke-$suffix\",\"unit_id\":\"unit-smoke-$suffix\",\"organisation_id\":\"org-smoke-$suffix\",\"purpose\":\"listing\",\"occupied\":false}")"

session_id="$(printf '%s' "$create_response" | jq -r '.id // empty')"
access_token="$(printf '%s' "$create_response" | jq -r '.access_token // empty')"

check "session created" test -n "$session_id"
check "token returned" test -n "$access_token"

if [ -z "$session_id" ] || [ -z "$access_token" ]; then
    echo "Cannot continue without a session."
    exit 1
fi

capture_body='{"raw_capture":{"floors":[{"identifier":"floor-smoke","category":"floor","confidence":"high","polygonCorners":[[0,0,0],[4,0,0],[4,0,3],[0,0,3]]}],"walls":[{"identifier":"w1","category":"wall","confidence":"high","dimensions":[4,2.6,0.1]}],"doors":[],"windows":[],"openings":[],"objects":[]}}'

capture_response="$(curl -s -X POST "$BASE_URL/scan-sessions/$session_id/capture" \
    -H 'Content-Type: application/json' \
    -H "X-Scan-Access-Token: $access_token" \
    -d "$capture_body")"

room_count="$(printf '%s' "$capture_response" | jq '.rooms | length')"
check "first room captured" test "$room_count" = "1"

second_capture_response="$(curl -s -X POST "$BASE_URL/scan-sessions/$session_id/capture" \
    -H 'Content-Type: application/json' \
    -H "X-Scan-Access-Token: $access_token" \
    -d "$capture_body")"

room_count_after="$(printf '%s' "$second_capture_response" | jq '.rooms | length')"
check "second room captured, session now has 2 rooms" test "$room_count_after" = "2"

export_status="$(http_status "$BASE_URL/scan-sessions/$session_id/export/floorplan.png" \
    -H "X-Scan-Access-Token: $access_token")"
check "PNG export works mid-walkthrough" test "$export_status" = "200"

read_status="$(http_status "$BASE_URL/scan-sessions/$session_id" \
    -H "X-Scan-Access-Token: $access_token")"
check "session still readable after 2 rooms" test "$read_status" = "200"

rotation_response="$(curl -s -X POST "$BASE_URL/scan-sessions/$session_id/rotate-token" \
    -H "X-Scan-Access-Token: $access_token")"
new_token="$(printf '%s' "$rotation_response" | jq -r '.access_token // empty')"

check "token rotated cleanly" test -n "$new_token"

old_token_status="$(http_status "$BASE_URL/scan-sessions/$session_id" \
    -H "X-Scan-Access-Token: $access_token")"
check "old token rejected after rotation" test "$old_token_status" = "401"

new_token_status="$(http_status "$BASE_URL/scan-sessions/$session_id" \
    -H "X-Scan-Access-Token: $new_token")"
check "new token accepted" test "$new_token_status" = "200"

delete_status="$(http_status -X DELETE "$BASE_URL/scan-sessions/$session_id" \
    -H "X-Scan-Access-Token: $new_token")"
check "cleanup: session deleted" test "$delete_status" = "200"

echo
echo "$FAILURES failure(s) out of $CHECKS check(s)."
if [ "$FAILURES" = "0" ]; then
    echo "SMOKE VERDICT: GREEN"
else
    echo "SMOKE VERDICT: RED"
    exit 1
fi
