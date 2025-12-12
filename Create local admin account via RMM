param (
    [string]$username = 'USERNAMEGOESHERE',
    [string]$password = 'PASSWORDGOESHERE'
)
 
# Check if running as Administrator
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}
 
# Check for required parameters
if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
    Write-Error "Both username and password must be provided."
    exit 1
}
 
# Check if user already exists
if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
    Write-Host "User '$username' already exists."
    exit 0
}
 
# Create secure password object
try {
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
} catch {
    Write-Error "Failed to convert password to secure string."
    exit 1
}
 
# Create local user
try {
    New-LocalUser -Name $username `
                  -Password $securePassword `
                  -FullName "Local Admin" `
                  -Description "Local admin account created by script" `
                  -PasswordNeverExpires:$true `
                  -UserMayNotChangePassword:$false
    Write-Host "User '$username' created successfully."
} catch {
    Write-Error "Failed to create local user: $_"
    exit 1
}
 
# Add to Administrators group
try {
    Add-LocalGroupMember -Group "Administrators" -Member $username
    Write-Host "User '$username' added to Administrators group."
} catch {
    Write-Error "Failed to add user to Administrators group: $_"
    exit 1
}
 
Write-Host "Admin user '$username' has been successfully created and granted local admin rights."
