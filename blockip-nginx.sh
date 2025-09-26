#!/usr/bin/env bash
# block-ip.sh
# This script blocks an IP in Nginx and restarts the service.

CONF_FILE="/etc/nginx/additional_server_conf"

echo "===================================="
echo " 🚫 Nginx IP Blocker Script"
echo "===================================="

# Step 1: Ask for IP
read -rp "👉 Enter the IP address you want to block: " BLOCK_IP

if [[ -z "$BLOCK_IP" ]]; then
    echo "❌ No IP provided. Exiting."
    exit 1
fi

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
