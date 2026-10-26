#!/usr/bin/env bash
# cloudways-app-list.sh
# Lists the servers and apps in a Cloudways account through the API.
# For each app it shows the app ID, the system user (also the DB name on
# Cloudways), the app label, the domain and the application type.
#
# Usage:  bash cloudways-app-list.sh
# Needs:  curl, jq
# The API key is typed at the prompt and is not saved anywhere.

set -u

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is missing. Install it with: sudo apt install jq"
  exit 1
fi

echo "Get the API details from the client's Cloudways dashboard first."
read -rp "Client's email: " EMAIL </dev/tty
read -rsp "Client's API key: " API_KEY </dev/tty; echo

TOKEN=$(curl -s -X POST https://api.cloudways.com/api/v1/oauth/access_token \
  -H 'Accept: application/json' \
  --data-urlencode "email=$EMAIL" \
  --data-urlencode "api_key=$API_KEY" | jq -r '.access_token // empty')

if [ -z "$TOKEN" ]; then
  echo "Failed to get an access token. Check the email and API key."
  exit 1
fi

JSON=$(mktemp) || exit 1
trap 'rm -f "$JSON"' EXIT
chmod 600 "$JSON"

curl -s -H "Authorization: Bearer $TOKEN" https://api.cloudways.com/api/v1/server > "$JSON"

echo
echo "Servers and apps for $EMAIL"
echo "---------------------------------"

jq -r '
  .servers[]? | . as $s
  | "SERVER\t\($s.id)\t\($s.public_ip)\t\($s.label)\t\($s.cloud)\t\($s.region)\t\($s.instance_type)",
    (.apps[]? | "  APP\t\(.id)\t\(.sys_user)\t\(.label)\t\(.app_fqdn)\t\(.application)")
' "$JSON" | column -t -s $'\t'
