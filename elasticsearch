#!/bin/bash

echo "-----------------------------------------"
echo "🔄 Restarting Apache..."
sudo systemctl restart apache2 && echo "✅ Apache restarted." || echo "❌ Failed to restart Apache."

echo "-----------------------------------------"
echo "🔄 Restarting Nginx..."
sudo systemctl restart nginx && echo "✅ Nginx restarted." || echo "❌ Failed to restart Nginx."

echo "-----------------------------------------"
echo "🔄 Restarting MySQL..."
sudo systemctl restart mysql && echo "✅ MySQL restarted." || echo "❌ Failed to restart MySQL."

echo "-----------------------------------------"
echo "🧹 Clearing Swap Memory..."
sudo swapoff -a && sudo swapon -a && echo "✅ Swap memory cleared." || echo "❌ Failed to clear swap."

echo "-----------------------------------------"
echo "🔄 Restarting Elasticsearch..."
sudo systemctl restart elasticsearch && echo "✅ Elasticsearch restarted." || echo "❌ Failed to restart Elasticsearch."

echo "-----------------------------------------"
echo "📊 Current Memory and Swap Usage:"
free -h

echo "✅ Elastic Search is Started."
