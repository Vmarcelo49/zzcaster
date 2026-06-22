#!/usr/bin/env bash
# ============================================================================
# deploy-pixeldrain.sh — upload a file to pixeldrain and print the download URL
#
# Usage:
#   ./scripts/deploy-pixeldrain.sh <file> [name]
#
# The file is uploaded via the pixeldrain API using HTTP Basic Auth.
# The API key goes in the password field (username is empty).
# After upload, the script prints the shareable download URL.
#
# Requirements: curl
# ============================================================================

set -euo pipefail

API_KEY="cf0f2917-1083-4989-abf6-00835a21d4d6"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <file> [name]" >&2
    exit 1
fi

FILE="$1"
NAME="${2:-$(basename "$FILE")}"

if [[ ! -f "$FILE" ]]; then
    echo "Error: file not found: $FILE" >&2
    exit 1
fi

FILESIZE=$(stat -c%s "$FILE" 2>/dev/null || stat -f%z "$FILE" 2>/dev/null)
echo "Uploading $FILE ($FILESIZE bytes) as '$NAME' to pixeldrain..." >&2

RESPONSE=$(curl -sSL --max-time 120 \
    -X PUT \
    --data-binary @"$FILE" \
    -u ":${API_KEY}" \
    "https://pixeldrain.com/api/file/${NAME}" \
    2>&1)

# Extract the id from the JSON response
# Response format: {"id":"xxxxx","name":"...","size":123,...}
ID=$(echo "$RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if data.get('success', True) and 'id' in data:
        print(data['id'])
    else:
        print('ERROR', file=sys.stderr)
        print(data.get('message', 'unknown error'), file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1)

if [[ "$ID" == ERROR* ]] || [[ -z "$ID" ]]; then
    echo "Upload failed:" >&2
    echo "$RESPONSE" >&2
    exit 1
fi

URL="https://pixeldrain.com/u/${ID}"
echo "$URL"
