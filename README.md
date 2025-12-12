# System Administration Scripts

A collection of system administration and automation scripts for macOS and Windows environments.  
These scripts are intended to help with common administrative tasks, maintenance, and troubleshooting.

## Important Notes

Before running any script in this repository:

- Read the comments inside the script first
- Some scripts require manual adjustments (paths, usernames, variables, permissions, etc.)
- Scripts are provided as-is — review and understand what they do before executing

## Platform-Specific Usage

### macOS Based Scripts
Scripts intended for macOS must be run in:

- Terminal
- Bash or Zsh

You may need to adjust your execution policy:

    Set-ExecutionPolicy RemoteSigned-Scope CurrentUser

## Script Configuration

Some scripts will not work out of the box and require configuration before running. This may include:

- Editing variables at the top of the script
- Updating file paths
- Changing hostnames, usernames, or permissions
- Enabling or disabling specific sections

Always review the script comments for setup instructions.

## Disclaimer

These scripts can make system-level changes.

- Use at your own risk
- Test in a non-production environment when possible
- The author is not responsible for data loss or system damage
