#!/bin/bash

# List of servers (replace with your server IPs or hostnames)
servers=("192.168.1.10" "192.168.1.20" "192.168.1.30")

# SSH user (change if not root)
user="root"

for server in "${servers[@]}"; do
    echo "========================================"
    echo "➡️  Connecting to $server ..."
    
    ssh -o StrictHostKeyChecking=no "$user@$server" "
        echo '✅ Connected to $server';
        echo '📂 Listing /home directory';
        ls /home/;
        echo '▶️ Running backup script...';
        /var/cw/scripts/bash/duplicity_backup.sh;
        echo '✅ Finished execution on $server';
    "
    
    echo "⬅️  Exiting from $server ..."
    echo "========================================"
    echo ""
done
