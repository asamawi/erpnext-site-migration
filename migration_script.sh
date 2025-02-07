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
db_root_password=$DB_ROOT_PASSWORD
admin_password=$ADMIN_PASSWORD
old_site=$1
legacy_app=$LEGACY_APP
if [ $# -eq 1 ]; then
    new_site=$old_site
else
    new_site=$2
fi

# Function to check if the last command was successful
check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed. Exiting..."
        exit 1
    fi
}
# Function to test SSH connectivity between servers
test_ssh_connectivity() {
    echo "Testing SSH connectivity..."

    # Test SSH connection to the old server
    ssh -o BatchMode=yes -o ConnectTimeout=5 $ssh_user@$old_server "echo SSH to old server successful" &> /dev/null
    if [ $? -ne 0 ]; then
        echo "Error: Unable to connect to old server ($old_server) via SSH. Aborting."
        exit 1
    else
        echo "SSH connection to old server ($old_server) successful."
    fi

    # Test SSH connection to the new server
    ssh -o BatchMode=yes -o ConnectTimeout=5 $ssh_user@$new_server "echo SSH to new server successful" &> /dev/null
    if [ $? -ne 0 ]; then
        echo "Error: Unable to connect to new server ($new_server) via SSH. Aborting."
        exit 1
    else
        echo "SSH connection to new server ($new_server) successful."
    fi

    check_success "SSH Connectivity Test"
}
# Function to test SSH connectivity from the old server to the new server
test_ssh_from_old_to_new() {
    echo "Testing SSH connectivity from $old_server to $new_server..."

    # Run SSH command from old server to new server
    ssh $ssh_user@$old_server "ssh -o BatchMode=yes -o ConnectTimeout=5 $ssh_user@$new_server 'echo SSH from old server to new server successful'" &> /dev/null
    if [ $? -ne 0 ]; then
        echo "Error: Unable to connect from old server ($old_server) to new server ($new_server) via SSH. Aborting."
        exit 1
    else
        echo "SSH connectivity from old server ($old_server) to new server ($new_server) successful."
    fi

    check_success "SSH Connectivity Test from Old to New Server"
}
# function to Create the new site
create_new_site() {

    # Create new site command
    create_site_cmd="cd ~/frappe-bench && bench new-site $new_site --db-root-password $db_root_password --admin-password $admin_password"

    # Install apps command
    install_apps_cmd=""
    for app in "${APPS_TO_INSTALL[@]}"; do
        install_apps_cmd+=" && bench --site $new_site install-app $app"
    done

    # Execute commands
    ssh $ssh_user@$new_server "$create_site_cmd$install_apps_cmd"
    check_success "New Site Creation"

}
# Function to perform backup
perform_backup() {
    # Run the backup command and capture the output
    backup_output=$(ssh $ssh_user@$old_server "cd ~/frappe-bench && \
        bench --site $old_site uninstall-app $legacy_app -y && \
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

check_success "Backup"
}

# function to Copy the backup files from old server to new server
copy_files(){
ssh $ssh_user@$old_server "scp ~/frappe-bench/sites/$old_site/private/backups/* $ssh_user@$new_server:~/frappe-bench/sites/$new_site/private"
check_success "Copying files"
}
# Function to perform restore and migration
perform_migration() {
    ssh $ssh_user@$new_server "cd ~/frappe-bench && \
        bench --site $new_site --force restore sites/$new_site/private/$database_file --db-root-password $db_root_password && \
        bench --site $new_site migrate && \
        tar xzvf sites/$new_site/private/$private_file && \
        tar xzvf sites/$new_site/private/$public_file && \
        mv $old_site/private/files/* sites/$new_site/private/files/ && \
        mv $old_site/public/files/* sites/$new_site/public/files/ && \
        rm -r $old_site/"
    check_success "Restore and Migration"
}

# Function to copy encryption key
copy_encryption_key() {
    source_file="/home/$ssh_user/frappe-bench/sites/$new_site/private/$config_file"  # Source JSON file path
    dest_file="/home/$ssh_user/frappe-bench/sites/$new_site/site_config.json"        # Destination JSON file path
    key="encryption_key"                                                           # Key to extract from source JSON file

    # Extracting value corresponding to the provided key from the source JSON file
    value=$(ssh $ssh_user@$new_server "grep -Po '\"encryption_key\":\\s*\"\\K[^\"]*' $source_file")

    # Check if the key exists in the destination file on the remote server
    if ssh $ssh_user@$new_server "grep -q '\"$key\"' \"$dest_file\""; then
        # If the key exists, replace its value in the destination JSON file
        ssh $ssh_user@$new_server "sed -i 's/\"$key\":\\s*\".*\"/\"$key\": \"$value\"/' $dest_file"
        echo "Replaced key '$key' with value '$value' in $dest_file"
    else
        # Insert the key-value pair into the destination JSON file after the previous line
        ssh $ssh_user@$new_server "sed -i '/\"encryption_key\":/s/$/,/' $dest_file && sed -i '\$s/}/,\n  \"$key\": \"$value\"\n}/' $dest_file"
        echo "Appended key '$key' with value '$value' to $dest_file"
    fi

    check_success "Copying Encryption Key"
} 

# Function to clean up backups
clean_backup() {
    # Remove all files inside the backups directory on the old server
    #ssh frappe@$old_server "rm -rf ~/frappe-bench/sites/$old_site/private/backups/*"

    # Remove all files except 'files' and 'backups' directories on the new server
    #ssh frappe@$new_server "find ~/frappe-bench/sites/$new_site/private/ -mindepth 1 -maxdepth 1 ! -name 'files' ! -name 'backups' -exec rm -rf {} +"

    check_success "Cleaning Backup"
}

# Call functions
test_ssh_connectivity
test_ssh_from_old_to_new
create_new_site
perform_backup
copy_files
perform_migration
copy_encryption_key
clean_backup

# Step 3: Update DNS Records
# Step 4: Setup Let's Encrypt SSL Certificate
# ...


echo "Migration for $old_site completed successfully."
