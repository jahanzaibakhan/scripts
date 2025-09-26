#!/usr/bin/env bash
# block-ip.sh
# Usage:
# curl -s https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/blockip-nginx.sh | bash -s 192.168.1.100 203.0.113.45

CONF_FILE="/etc/nginx/additional_server_conf"

echo "===================================="
echo " 🚫 Nginx IP Blocker Script"
echo "===================================="

# Step 1: Check arguments
if [ $# -eq 0 ]; then
    echo "❌ No IPs provided."
    echo "👉 Usage: bash $0 <IP1> <IP2> ..."
    exit 1
fi

# Step 2: Append all provided IPs
for BLOCK_IP in "$@"; do
    echo "📝 Blocking IP $BLOCK_IP in $CONF_FILE..."
    echo "deny $BLOCK_IP;" | sudo tee -a "$CONF_FILE" > /dev/null
done

# Step 3: Test Nginx configuration
echo "🔍 Checking Nginx configuration..."
if ! sudo nginx -t; then
    echo "❌ Nginx config test failed. Removing last added entries."
    for BLOCK_IP in "$@"; do
        sudo sed -i "/deny $BLOCK_IP;/d" "$CONF_FILE"
    done
    exit 1
fi

# Step 4: Restart Nginx
echo "🔄 Restarting Nginx..."
if sudo systemctl restart nginx; then
    echo "✅ Nginx restarted successfully."
    echo "🎉 Blocked IPs: $*"
else
    echo "❌ Failed to restart Nginx. Please check logs."
    exit 1
fi
