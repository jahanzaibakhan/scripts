#!/usr/bin/env bash
# server-id.sh
# Usage: ./server-id.sh 199.247.30.131 45.32.218.247

if [ $# -eq 0 ]; then
    echo "❌ Please provide one or more server IPs"
    echo "👉 Example: $0 199.247.30.131 45.32.218.247"
    exit 1
fi

# Print header
printf "\n========= FINAL SUMMARY =========\n"
printf "%-15s | %-20s\n" "SERVER IP" "APP ID"
printf "%-15s-+-%-20s\n" "---------------" "--------------------"

# Loop through servers
for server in "$@"; do
    result=$(bash -i -c "printf 'ls -1 /home/\nexit\n' | cng $server" 2>/dev/null)
    first_line=$(echo "$result" | head -n 1 | sed 's/\.cloudwaysapps\.com//')

    printf "%-15s | %-20s\n" "$server" "$first_line"
done
