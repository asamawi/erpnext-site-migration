# ERPNext Site Migration Script

This script automates the migration of ERPNext sites between servers. Ensure you have the necessary permissions and follow these steps:

## Preparation:
- Ensure you have access to both the old and new servers.
- Set up the `config.sh` file with sensitive information (server IPs, SSH user) needed for the migration script.

```
export OLD_SERVER="x.x.x.x" # IP address for old server
export NEW_SERVER="x.x.x.x" # IP address for new server
export SSH_USER="username" # ssh user that has been set for frappe and erpnext
export DB_ROOT_PASSWORD="you database passowrd!"
export ADMIN_PASSWORD="ERPNEXT Adminstrator Password!"
export APPS_TO_INSTALL=("erpnext" "hrms") # List of apps to install on the new site
export LEGACY_APPS=("legacy_app1" "legacy_app2") # List of legacy apps to uninstall before backup
```

## Usage:
- **Syntax:** `./migration_script.sh <old_site_name> [<new_site_name>] [--skip-backup] [--skip-copy] [--extract-only] [--skip-preparation]`
- Provide one site name for migration or both old and new site names.
- Example: `./migration_script.sh old_site_name new_site_name`
- Use the `--skip-backup` option to skip the backup creation step if the backup has already been created during a previous attempt.
- Use the `--skip-copy` option to skip copying files from the old server if the files have already been copied.
- Use the `--extract-only` option to perform only the file extraction step.
- Use the `--skip-preparation` option to skip the preparation step for final migration.

## Script Execution:
The script performs the following:
- Backs up the old site from the old server.
- Creates a new site with specified apps on the new server.
- Copies the backup files from the old server to the new server.
- Restores the database and performs site migration on the new server.
- Copies the encryption key from the old site's config to the new site's config.

## Important Note:
- This script involves sensitive operations. Ensure you have backups and thoroughly review the script before execution.

## Cleanup:
- Review the migration logs and verify the success of the migration before removing any backups or old configurations.
