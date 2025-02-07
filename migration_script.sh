#!/bin/bash

# Load sensitive information from config.sh
if [ ! -f config.sh ]; then
    echo "Error: config.sh file not found!"
    exit 1
fi
source config.sh

# Initialize skip_backup flag
skip_backup=false

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --skip-backup) skip_backup=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

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
    else
        echo "✓ $1 completed successfully"
    fi
}

# Function to test SSH connectivity between servers
test_ssh_connectivity() {
    echo "Testing SSH connectivity..."

    # Test SSH connection to the old server
    echo "Connecting to old server ($old_server)..."
    ssh -o BatchMode=yes -o ConnectTimeout=5 $ssh_user@$old_server "echo '✓ SSH to old server successful'"
    if [ $? -ne 0 ]; then
        echo "Error: Unable to connect to old server ($old_server) via SSH. Aborting."
        exit 1
    fi

    # Test SSH connection to the new server
    echo "Connecting to new server ($new_server)..."
    ssh -o BatchMode=yes -o ConnectTimeout=5 $ssh_user@$new_server "echo '✓ SSH to new server successful'"
    if [ $? -ne 0 ]; then
        echo "Error: Unable to connect to new server ($new_server) via SSH. Aborting."
        exit 1
    fi

    check_success "SSH Connectivity Test"
}

# Function to test SSH connectivity from the old server to the new server
test_ssh_from_old_to_new() {
    echo "Testing SSH connectivity from $old_server to $new_server..."
    ssh $ssh_user@$old_server "ssh -o BatchMode=yes -o ConnectTimeout=5 $ssh_user@$new_server 'echo ✓ SSH from old server to new server successful'"
    check_success "SSH Connectivity Test from Old to New Server"
}
# Function to check if the site already exists on the new server
check_site_exists() {
    echo "Checking if site '$new_site' already exists on $new_server..."
    
    # Check if the site directory exists
    ssh $ssh_user@$new_server "[ -d ~/frappe-bench/sites/$new_site ]"
    if [ $? -eq 0 ]; then
        echo "✓ Site '$new_site' already exists on $new_server. Skipping site creation."
        return 1  # Indicate that the site already exists
    else
        echo "Site '$new_site' does not exist. Proceeding with creation..."
        return 0  # Indicate that the site does not exist
    fi
}

# function to Create the new site
create_new_site() {
    check_site_exists
    if [ $? -eq 1 ]; then
        return  # Skip site creation if it already exists
    fi
    echo "Creating new site on $new_server..."
    
    # Create new site command
    create_site_cmd="cd ~/frappe-bench && bench new-site $new_site --db-root-password $db_root_password --admin-password $admin_password"
    
    # Install apps command
    install_apps_cmd=""
    for app in "${APPS_TO_INSTALL[@]}"; do
        echo "Will install app: $app"
        install_apps_cmd+=" && bench --site $new_site install-app $app"
    done

    # Execute commands
    ssh -t $ssh_user@$new_server "$create_site_cmd$install_apps_cmd"
    check_success "New Site Creation"
}

# Function to perform backup
perform_backup() {
    echo "Starting backup process on $old_server..."
    
    # Build uninstall commands for legacy apps
    uninstall_cmd=""
    for app in "${LEGACY_APPS[@]}"; do
        echo "Will uninstall legacy app: $app"
        uninstall_cmd+="bench --site $old_site uninstall-app $app -y && "
    done

    echo "Performing backup operations..."
    # Run the backup command and capture the output
    backup_output=$(ssh -t $ssh_user@$old_server "cd ~/frappe-bench && \
        $uninstall_cmd \
        bench --site $old_site disable-scheduler && \
        bench --site $old_site set-maintenance-mode on && \
        bench --site $old_site backup --with-files --compress")

    # Extract timestamp and filenames from the backup output
    timestamp=$(echo "$backup_output" | awk '/Backup Summary for/ {print $6, $7}' )
    config_file=$(echo "$backup_output" | awk '/Config/ {print $3}'  | xargs basename)
    database_file=$(echo "$backup_output" | awk '/Database/ {print $2}' | xargs basename)
    public_file=$(echo "$backup_output" | awk '/Public/ {print $3}' | xargs basename)
    private_file=$(echo "$backup_output" | awk '/Private/ {print $3}' | xargs basename)

    # Display extracted information
    echo "Backup Summary:"
    echo "  Timestamp: $timestamp"
    echo "  Config File: $config_file"
    echo "  Database File: $database_file"
    echo "  Public File: $public_file"
    echo "  Private File: $private_file"

    check_success "Backup"
}

# function to Copy the backup files from old server to new server
copy_files(){
    echo "Copying backup files from $old_server to $new_server..."
    ssh -t $ssh_user@$old_server "scp -v ~/frappe-bench/sites/$old_site/private/backups/* $ssh_user@$new_server:~/frappe-bench/sites/$new_site/private"
    check_success "Copying files"
}

# Function to perform restore and migration
restore_and_migrate() {
    ssh -t $ssh_user@$new_server "cd ~/frappe-bench && \
        bench --site $new_site --force restore sites/$new_site/private/$database_file --db-root-password $db_root_password && \
        bench --site $new_site migrate && \
        tar xzvf sites/$new_site/private/$private_file && \
        tar xzvf sites/$new_site/private/$public_file && \
        rsync -av --ignore-existing $old_site/private/files/ sites/$new_site/private/files/ && \
        rsync -av --ignore-existing $old_site/public/files/ sites/$new_site/public/files/ && \
        rm -r $old_site/"
    check_success "Restore and Migration"
}

# Function to copy encryption key
copy_encryption_key() {
    echo "Copying encryption key..."
    source_file="/home/$ssh_user/frappe-bench/sites/$new_site/private/$config_file"
    dest_file="/home/$ssh_user/frappe-bench/sites/$new_site/site_config.json"
    key="encryption_key"

    echo "Extracting encryption key from $source_file"
    value=$(ssh $ssh_user@$new_server "grep -Po '\"encryption_key\":\\s*\"\\K[^\"]*' $source_file")

    if ssh $ssh_user@$new_server "grep -q '\"$key\"' \"$dest_file\""; then
        echo "Updating existing encryption key..."
        ssh $ssh_user@$new_server "sed -i 's/\"$key\":\\s*\".*\"/\"$key\": \"$value\"/' $dest_file"
        echo "✓ Updated encryption key in $dest_file"
    else
        echo "Adding new encryption key..."
        ssh $ssh_user@$new_server "sed -i '/\"encryption_key\":/s/$/,/' $dest_file && sed -i '\$s/}/,\n  \"$key\": \"$value\"\n}/' $dest_file"
        echo "✓ Added encryption key to $dest_file"
    fi

    check_success "Copying Encryption Key"
} 

# Function to clean up backups
clean_backup() {
    echo "Cleaning up backup files..."
    # Remove all files inside the backups directory on the old server
    #ssh frappe@$old_server "rm -rf ~/frappe-bench/sites/$old_site/private/backups/*"

    # Remove all files except 'files' and 'backups' directories on the new server
    #ssh frappe@$new_server "find ~/frappe-bench/sites/$new_site/private/ -mindepth 1 -maxdepth 1 ! -name 'files' ! -name 'backups' -exec rm -rf {} +"

    check_success "Cleaning Backup"
}

echo "Starting migration process..."
echo "From: $old_server ($old_site)"
echo "To: $new_server ($new_site)"
echo "-----------------------------------"

# Call functions
test_ssh_connectivity
test_ssh_from_old_to_new
create_new_site

# Main script execution
if [ "$skip_backup" = false ]; then
    echo "Creating backup..."
    perform_backup
else
    echo "Skipping backup as per user request..."
fi

copy_files
restore_and_migrate
copy_encryption_key
clean_backup

# Step 3: Update DNS Records
# Step 4: Setup Let's Encrypt SSL Certificate
# ...

echo "-----------------------------------"
echo "✓ Migration for $old_site completed successfully!"