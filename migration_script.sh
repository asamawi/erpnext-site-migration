#!/bin/bash

# Load sensitive information from config.sh
source config.sh

# Check if one or two site names are provided as arguments
if [ $# -ne 1 ] && [ $# -ne 2 ]; then
    echo "Usage: $0 <old_site_name> [<new_site_name>]"
    echo "Please provide one site name for migration or both old and new site names."
    exit 1
fi

# Variables
old_server=$OLD_SERVER
new_server=$NEW_SERVER
ssh_user=$SSH_USER
echo "Old Server IP: $old_server"
echo "new Server IP: $new_server"
echo "ssh user: $ssh_user"
old_site=$1
if [ $# -eq 1 ]; then
    new_site=$old_site
else
    new_site=$2
fi

backup_dir="sites/$old_site/private/backups"

# Function to check if the last command was successful
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed. Exiting..."
        exit 1
    fi
}

# Function to perform backup
perform_backup() {
    # Run the backup command and capture the output
    backup_output=$(ssh $ssh_user@$old_server "cd ~/frappe-bench && \
        bench --site $old_site disable-scheduler && \
        bench --site $old_site set-maintenance-mode on && \
        bench --site $old_site backup --with-files --compress")

   # Extract timestamp and filenames from the backup output
timestamp=$(echo "$backup_output" | awk '/Backup Summary for/ {print $6, $7}' ) # Extracts timestamp
config_file=$(echo "$backup_output" | awk '/Config/ {print $3}'  | xargs basename)               # Extracts config file
database_file=$(echo "$backup_output" | awk '/Database/ {print $2}' | xargs basename)
public_file=$(echo "$backup_output" | awk '/Public/ {print $3}' | xargs basename)               # Extracts public file
private_file=$(echo "$backup_output" | awk '/Private/ {print $3}' | xargs basename)             # Extracts private file

# Display extracted information (for verification)
echo "Timestamp: $timestamp"
echo "Config File: $config_file"
echo "Database File: $database_file"
echo "Public File: $public_file"
echo "Private File: $private_file"

# Create  the new site

ssh $ssh_user@$new_server "cd ~/frappe-bench && \
    bench new-site $new_site && \
    bench --site $new_site install-app erpnext && \
    bench --site $new_site install-app hrms"



# Copy the backup files from old server to new server
ssh $ssh_user@$old_server "scp ~/frappe-bench/sites/$old_site/private/backups/* $ssh_user@$new_server:~/frappe-bench/sites/$new_site/private"



    check_success "Backup"
}



# Function to perform restore and migration
perform_migration() {
    ssh $ssh_user@$new_server "cd ~/frappe-bench && \
        bench --site $new_site --force restore sites/$new_site/private/$database_file && \
        bench --site $new_site migrate"

    check_success "Restore and Migration"
}

# Function to copy encryption key
copy_encryption_key() {
    source_file="/home/$ssh_user/frappe-bench/sites/$new_site/private/$config_file"  # Source JSON file path
    dest_file="/home/$ssh_user/frappe-bench/sites/$new_site/site_config.json"        # Destination JSON file path
    key="encryption_key"                                                           # Key to extract from source JSON file

    # Extracting value corresponding to the provided key from the source JSON file
    value=$(ssh $ssh_user@$new_server "grep -Po '\"encryption_key\":\\s*\"\\K[^\"]*' $source_file")

    # Checking if the key exists in the source file
    if [ -n "$value" ]; then
        # Inserting key-value pair into the destination JSON file
        ssh $ssh_user@$new_server "sed -i 's/\"$key\":\\s*\".*\"/\"$key\": \"$value\"/g' $dest_file"
        echo "Inserted key '$key' with value '$value' into $dest_file"
    else
        echo "Key '$key' not found in $source_file"
    fi

    check_success "Copying Encryption Key"
}

# Call functions
perform_backup
perform_migration
copy_encryption_key

# Step 3: Update DNS Records
# Step 4: Setup Let's Encrypt SSL Certificate
# ...

echo "Migration for $old_site completed successfully."
