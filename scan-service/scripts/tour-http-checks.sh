#!/bin/sh
set -eu

BASE_URL="${SCAN_SERVICE_BASE_URL:-http://127.0.0.1:8089}"
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 2; }
command -v php >/dev/null || { echo "php required" >&2; exit 2; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

fail=0
checks=0
check() {
    label="$1"; shift
    checks=$((checks+1))
    if "$@"; then
        echo "  [PASS] $label"
    else
        fail=$((fail+1))
        echo "  [FAIL] $label"
    fi
}

suffix="$(date +%s)-$$"

create="$(curl -s -X POST "$BASE_URL/scan-sessions" \
    -H 'Content-Type: application/json' \
    -d "{\"property_id\":\"p-$suffix\",\"unit_id\":\"u-$suffix\",\"organisation_id\":\"o-$suffix\",\"purpose\":\"listing\",\"occupied\":false}")"

sid="$(printf '%s' "$create" | jq -r .id)"
tok="$(printf '%s' "$create" | jq -r .access_token)"

if [ -z "$sid" ] || [ "$sid" = "null" ]; then
    echo "Could not create a session; response was: $create" >&2
    exit 1
fi

capture='{"raw_capture":{"floors":[{"identifier":"f","category":"floor","confidence":"high","polygonCorners":[[0,0,0],[4,0,0],[4,0,3],[0,0,3]]}],"walls":[{"identifier":"w1","category":"wall","confidence":"high","dimensions":[4,2.6,0.1]}],"doors":[],"windows":[],"openings":[],"objects":[]},"capture_provider":"roomplan","floor":"Ground"}'
curl -s -X POST "$BASE_URL/scan-sessions/$sid/capture" \
    -H 'Content-Type: application/json' \
    -H "X-Scan-Access-Token: $tok" \
    -d "$capture" >/dev/null

php -r 'if (!extension_loaded("gd")) { fwrite(STDERR, "gd required to generate the JPEG fixture\n"); exit(2); } $img = imagecreatetruecolor(2,2); imagefilledrectangle($img,0,0,1,1,imagecolorallocate($img,200,100,50)); ob_start(); imagejpeg($img); file_put_contents($argv[1], ob_get_clean()); imagedestroy($img);' "$SCRATCH/jpeg.jpg"

printf '%%PDF-1.4\n%%\n' > "$SCRATCH/doc.pdf"
printf 'plain text not an image' > "$SCRATCH/text.txt"
: > "$SCRATCH/empty"

status() {
    curl -s -o /dev/null -w '%{http_code}' "$@"
}

upload_url="$BASE_URL/scan-sessions/$sid/photo-uploads"

jpeg_status="$(status -X POST "$upload_url" -H "X-Scan-Access-Token: $tok" -F "photo=@$SCRATCH/jpeg.jpg;type=image/jpeg")"
check "JPEG upload accepted" test "$jpeg_status" = "201"

pdf_status="$(status -X POST "$upload_url" -H "X-Scan-Access-Token: $tok" -F "photo=@$SCRATCH/doc.pdf;type=application/pdf")"
check "PDF rejected" test "$pdf_status" = "422"

txt_status="$(status -X POST "$upload_url" -H "X-Scan-Access-Token: $tok" -F "photo=@$SCRATCH/text.txt;type=text/plain")"
check "text/plain rejected" test "$txt_status" = "422"

empty_status="$(status -X POST "$upload_url" -H "X-Scan-Access-Token: $tok" -F "photo=@$SCRATCH/empty")"
check "empty file rejected" test "$empty_status" = "422"

glb_url="$BASE_URL/scan-sessions/$sid/export/dollhouse.glb"
first_headers="$(curl -s -D - -o /dev/null "$glb_url" -H "X-Scan-Access-Token: $tok" | tr -d '\r')"
first_status="$(printf '%s' "$first_headers" | awk 'NR==1 {print $2}')"
etag="$(printf '%s' "$first_headers" | awk -F': ' 'tolower($1) == "etag" {print $2}')"
check "first GLB request returns 200" test "$first_status" = "200"
check "first GLB request has an ETag" test -n "$etag"

match_status="$(status -H "If-None-Match: $etag" "$glb_url" -H "X-Scan-Access-Token: $tok")"
check "matching ETag -> 304" test "$match_status" = "304"

miss_status="$(status -H 'If-None-Match: "nope"' "$glb_url" -H "X-Scan-Access-Token: $tok")"
check "wrong ETag -> 200" test "$miss_status" = "200"

room_id="$(curl -s "$BASE_URL/scan-sessions/$sid" -H "X-Scan-Access-Token: $tok" | jq -r '.rooms[0].room_id')"
curl -s -o /dev/null -X POST "$BASE_URL/scan-sessions/$sid/photos-360" \
    -H "X-Scan-Access-Token: $tok" \
    -H "Idempotency-Key: etag-$suffix" \
    -F "photo=@$SCRATCH/jpeg.jpg;type=image/jpeg" \
    -F "room_id=$room_id" \
    -F 'position_x=2' \
    -F 'position_z=2' \
    -F 'heading_deg=180'

second_headers="$(curl -s -D - -o /dev/null "$glb_url" -H "X-Scan-Access-Token: $tok" | tr -d '\r')"
etag2="$(printf '%s' "$second_headers" | awk -F': ' 'tolower($1) == "etag" {print $2}')"
check "adding a photo_360 changes the ETag" test "$etag" != "$etag2"

stale_status="$(status -H "If-None-Match: $etag" "$glb_url" -H "X-Scan-Access-Token: $tok")"
check "old ETag after new photo -> 200" test "$stale_status" = "200"

curl -s -X DELETE "$BASE_URL/scan-sessions/$sid" -H "X-Scan-Access-Token: $tok" >/dev/null

echo ""
echo "$fail failure(s) out of $checks check(s)."
if [ "$fail" = "0" ]; then
    echo "VERDICT: GREEN"
    exit 0
else
    echo "VERDICT: RED"
    exit 1
fi
