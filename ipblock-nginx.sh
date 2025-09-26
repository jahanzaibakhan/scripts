#!/usr/bin/env bash
# block-ip.sh
# Usage: curl -s https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/blockip-nginx.sh | bash -s 192.168.1.100

CONF_FILE="/etc/nginx/additional_server_conf"

echo "===================================="
echo " 🚫 Nginx IP Blocker Script"
echo "===================================="

# Step 1: Get IP from argument
if [[ -z "$1" ]]; then
    echo "❌ No IP provided."
    echo "👉 Usage: bash $0 <IP_ADDRESS>"
    exit 1
fi

BLOCK_IP="$1"

# Step 2: Append to Nginx conf
echo "📝 Blocking IP $BLOCK_IP in $CONF_FILE..."
echo "deny $BLOCK_IP;" | sudo tee -a "$CONF_FILE" > /dev/null

# Step 3: Test Nginx configuration
echo "🔍 Checking Nginx configuration..."
if ! sudo nginx -t; then
    echo "❌ Nginx config test failed. Removing last entry."
    sudo sed -i '$d' "$CONF_FILE"
    exit 1
fi

# Step 4: Restart Nginx
echo "🔄 Restarting Nginx..."
if sudo systemctl restart nginx; then
    echo "✅ Nginx restarted successfully."
    echo "🎉 IP $BLOCK_IP is now blocked."
else
    echo "❌ Failed to restart Nginx. Please check logs."
    exit 1
fi
