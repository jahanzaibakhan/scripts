#!/bin/bash

# Purpose: To get a downloadable zip of database and web files.
# Author: Jahanzaib Khan | Cloudways
# Last Edited: 26/04/2024:10:28
# Usage: curl -s https://raw.githubusercontent.com/jahanzaibakhan/scripts/main/backup.sh | bash 

# Get the current working directory
current_dir=$(pwd)

# Extract the database name from the directory path
dbname=$(echo "$current_dir" | grep -oP '(?<=applications/)[^/]+')

# Check if the database name was successfully extracted
if [ -z "$dbname" ]; then
    echo "Error: Could not determine the database name from the current directory."
    exit 1
fi

# Define the backup file name for the database backup
backup_file_db="/home/master/applications/$dbname/public_html/database_backup.sql"

# Check if it's a WordPress site
if [ -e "/home/master/applications/$dbname/public_html/wp-config.php" ]; then
    # Site is WordPress
    wp db export "$backup_file_db" --path="/home/master/applications/$dbname/public_html"
    
    # Check the exit status for errors
    if [ $? -eq 0 ]; then
        echo "Database backup of '$dbname' created at '$backup_file_db'"
    else
        echo "Error: Database backup failed."
        exit 1
    fi
else
    # Site is not WordPress, use mysqldump
    mysqldump -u $dbname -p $dbname > "$backup_file_db"
    
    # Check the exit status for errors
    if [ $? -eq 0 ]; then
        echo "Database backup of '$dbname' created at '$backup_file_db'"
    else
        echo "Error: Database backup failed."
        exit 1
    fi
fi

# Define the backup directory and file name for the directory backup
backup_dir="/home/master/applications/$dbname/public_html"
backup_file_dir="/home/master/applications/$dbname/public_html/backup.tar.gz"

# Create a zip file containing the database backup and directory backup
tar -czvf "$backup_file_dir" -C "$backup_dir" . "$backup_file_db"

echo "Backup of '$dbname' created at '$backup_file_dir'"

# Calculate the size of the public_html folder
folder_size=$(du -sh "$backup_dir" | cut -f1)

# Calculate the required minimum space as 1.5 times the folder size
min_space_required=$((folder_size * 3 / 2))  # 1.5 times the folder size

# Check available disk space
disk_space=$(df -h / | awk 'NR==2 {print $4}')

# Compare available space with the minimum required space
if [[ "$disk_space" < "$min_space_required" ]]; then
    echo -e "\033[1;31mWarning: Insufficient disk space. You have $disk_space available, but at least $min_space_required is required (1.5 times the size of the public_html folder).\033[0m"
fi

# Run the wp cli command to get the site URL if it's WordPress
if [ -e "/home/master/applications/$dbname/public_html/wp-config.php" ]; then
    site_url=$(wp option get siteurl --path="/home/master/applications/$dbname/public_html")
else
    # Site is not WordPress, use Magento command
    site_url=$(php bin/magento config:show web/unsecure/base_url)
fi

# Create a downloadable link
download_link="$site_url/backup.tar.gz"

echo "Downloadable backup link: $download_link"

rm -rf ./app-backup.sh
exit
