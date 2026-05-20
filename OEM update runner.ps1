<#
OEMUpdateRunner

Purpose:
- Run the vendor-supported silent update CLI for the detected OEM: Dell, Lenovo, or HP.
- Install the vendor CLI first when it is missing and bootstrapping is enabled.
- Suppress intentional restarts. BIOS and firmware are excluded by default.
- Keep RMM-friendly logs and machine-readable OEMUPDATER_* output lines.

This refactor intentionally removes high-risk/low-value paths from the original:
- No Chocolatey bootstrap or third-party package fallback.
- No Dell Command Update uninstall/reinstall repair path.
- No registry cleanup for MSI source errors.
- No deep Lenovo artifact parser. Vendor logs are preserved instead.
#>

# -----------------------------
# ConnectWise/RMM paste-safe configuration
# -----------------------------
# Leave these defaults for normal RMM deployment. Edit values here before pasting if needed.

$LenovoSearchMode = 'R'                       # C = Critical, R = Critical + Recommended, A = Critical + Recommended + Optional
$HPCategoryMode = 'DriversSoftware'           # DriversSoftware or All

$InstallDellCommandUpdateIfMissing = $true
$InstallDotNetDesktopRuntimeIfMissing = $true
$InstallLenovoSystemUpdateIfMissing = $true
$InstallHPImageAssistantIfMissing = $true

$InstallRebootRequiredUpdatesNoAutoReboot = $true
$IncludeBiosFirmwareUpdates = $false
$LenovoRebootPackageTypes = '3'

$SkipWhenWindowsPendingReboot = $true
$RestartDellClientManagementServiceBeforeDellApply = $true
$DellClientManagementServiceWaitTimeoutSeconds = 90
$DellClientManagementServicePostStartDelaySeconds = 15
$DellDcuServiceRecoveryRetries = 1
$DellDcuServiceBusyWaitMinutes = 30
$DellDcuServiceBusyPollSeconds = 60
$AllowDellNoUpdateTypeFallback = $false

$VendorTimeoutMinutes = 120
$LenovoPostProcessWaitMinutes = 90
$WhatIfOnly = $false
$ReturnNonZeroOnVendorFailure = $false

$BaseLogDir = 'C:\ProgramData\OEMUpdateRunner'

# Dell Command Update installer source. Prefer a local/cache path in RMM if possible.
$DellCommandUpdateInstallerLocalPath = ''
$DellCommandUpdateInstallerUrls = @(
    'https://dl.dell.com/FOLDER14424601M/1/Dell-Command-Update-Windows-Universal-Application_FGK9X_WIN64_5.7.0_A00.EXE',
    'https://downloads.dell.com/FOLDER14424601M/1/Dell-Command-Update-Windows-Universal-Application_FGK9X_WIN64_5.7.0_A00.EXE'
)
$DellCommandUpdateInstallerSha256 = '98C20D9809D7469A760B42A9A258E8C67A35C6CF46AA6A9C173E29D39A056D89'
$DotNetDesktopRuntime8Url = 'https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe'

$LenovoSystemUpdateInstallerUrl = 'https://download.lenovo.com/pccbbs/thinkvantage_en/system_update_5.08.03.59.exe'

$HPImageAssistantInstallerUrl = 'https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.4.exe'
$HPImageAssistantInstallDir = 'C:\Program Files\HP\HPIA'

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Relaunch in 64-bit PowerShell when this script is saved as a .ps1 file.
# When pasted directly into ConnectWise, $PSCommandPath can be empty. In that case the script continues
# and logs a warning. Prefer ConnectWise's 64-bit PowerShell option when pasting.
$script:PasteMode64BitRelaunchUnavailable = $false
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnativePowerShell = Join-Path $env:WINDIR 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'

    if ((Test-Path -LiteralPath $sysnativePowerShell) -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        & $sysnativePowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }

    $script:PasteMode64BitRelaunchUnavailable = $true
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {}

$script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:RunLogDir = Join-Path $BaseLogDir $RunStamp
$script:MainLog = Join-Path $RunLogDir 'OEMUpdateRunner.log'
New-Item -ItemType Directory -Path $RunLogDir -Force | Out-Null

$script:RunState = [ordered]@{
    SupportedToolFound = $false
    HadVendorFailure = $false
    HadVendorWarning = $false
    RebootRequired = $false
    WindowsPendingRebootDetected = $false

    DellToolFound = $false
    DellToolBootstrapped = $false
    DellApplyRan = $false
    DellClientManagementServiceRecovered = $false
    DellServiceBusyDeferral = $false
    DellStopFurtherApplyAttempts = $false

    LenovoToolFound = $false
    LenovoToolBootstrapped = $false
    LenovoApplyRan = $false

    HPToolFound = $false
    HPToolBootstrapped = $false
    HPApplyRan = $false
}

function Set-State {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value
    )

    if (-not $script:RunState.Contains($Name)) {
        throw "Unknown run-state key: $Name"
    }

    $script:RunState[$Name] = $Value
}

function Get-State {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $script:RunState[$Name]
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp [$Level] $Message"
    Add-Content -LiteralPath $script:MainLog -Value $line
    Write-Host $line
}

function New-ToolResult {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [string]$FilePath = '',
        [Nullable[int]]$ExitCode = $null,
        [bool]$Ran = $false,
        [bool]$Success = $false,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Message = ''
    )

    [pscustomobject]@{
        Tool = $Tool
        FilePath = $FilePath
        ExitCode = $ExitCode
        Ran = $Ran
        Success = $Success
        Status = $Status
        Message = $Message
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProgramFiles64 {
    if ($env:ProgramW6432) { return $env:ProgramW6432 }
    return $env:ProgramFiles
}

function Get-ProgramFilesX86 {
    $path = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)', 'Machine')
    if (-not $path) { $path = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)', 'Process') }
    if (-not $path -and [Environment]::Is64BitOperatingSystem) { $path = 'C:\Program Files (x86)' }
    if (-not $path) { $path = Get-ProgramFiles64 }
    return $path
}

function Resolve-FirstExistingPath {
    param([string[]]$Path)

    foreach ($candidate in $Path) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Join-CommandLineArgument {
    param([string[]]$Argument)

    $escaped = foreach ($item in $Argument) {
        if ($null -eq $item) { continue }
        $text = [string]$item

        if ($text.Length -eq 0) {
            '""'
            continue
        }

        if ($text -notmatch '[\s"]') {
            $text
            continue
        }

        $text = $text -replace '(\\*)"', '$1$1\"'
        $text = $text -replace '(\\+)$', '$1$1'
        '"' + $text + '"'
    }

    return ($escaped -join ' ')
}

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$SuccessExitCodes = @(0),
        [int[]]$RebootExitCodes = @(),
        [int[]]$WarningExitCodes = @(),
        [int[]]$NonFatalExitCodes = @(),
        [int]$TimeoutMinutes = $script:VendorTimeoutMinutes
    )

    $safeName = $Name -replace '[^\w.-]', '_'
    $stdoutFile = Join-Path $script:RunLogDir "$safeName-stdout.log"
    $stderrFile = Join-Path $script:RunLogDir "$safeName-stderr.log"

    Write-Log "$Name executable: $FilePath"
    Write-Log "$Name arguments: $($Arguments -join ' ')"

    if ($WhatIfOnly) {
        Write-Log "WhatIfOnly enabled. Skipping $Name execution."
        return New-ToolResult -Tool $Name -FilePath $FilePath -Ran $false -Success $true -Status 'WhatIf'
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Set-State HadVendorFailure $true
        Write-Log "$Name executable was not found: $FilePath" 'ERROR'
        return New-ToolResult -Tool $Name -FilePath $FilePath -Ran $false -Success $false -Status 'MissingExecutable'
    }

    $process = $null

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = Join-CommandLineArgument -Argument $Arguments
        $psi.WorkingDirectory = Split-Path -Path $FilePath -Parent
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $timeoutMs = [Math]::Max(1, $TimeoutMinutes) * 60 * 1000
        $finished = $process.WaitForExit($timeoutMs)

        if (-not $finished) {
            try { $process.Kill() } catch {}
            Set-State HadVendorFailure $true
            Write-Log "$Name timed out after $TimeoutMinutes minutes and was killed." 'ERROR'
            return New-ToolResult -Tool $Name -FilePath $FilePath -Ran $true -Success $false -Status 'Timeout'
        }

        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result

        if ($stdout) { [System.IO.File]::WriteAllText($stdoutFile, $stdout) }
        if ($stderr) { [System.IO.File]::WriteAllText($stderrFile, $stderr) }

        Write-Log "$Name finished with exit code $exitCode."
        if ($stdout) { Write-Log "$Name stdout saved to $stdoutFile" }
        if ($stderr) { Write-Log "$Name stderr saved to $stderrFile" }

        $success = $SuccessExitCodes -contains $exitCode
        $reboot = $RebootExitCodes -contains $exitCode
        $warning = $WarningExitCodes -contains $exitCode
        $nonFatal = $NonFatalExitCodes -contains $exitCode
        $status = 'Failure'

        if ($success) { $status = 'Success' }
        elseif ($reboot) {
            $status = 'RebootRequired'
            Set-State RebootRequired $true
            Write-Log "$Name reports reboot required. This script will not restart the device." 'WARN'
        }
        elseif ($warning) {
            $status = 'Warning'
            Set-State HadVendorWarning $true
            Write-Log "$Name returned a warning or partial-success exit code: $exitCode" 'WARN'
        }
        elseif ($nonFatal) {
            $status = 'Deferred'
            Set-State HadVendorWarning $true
            Write-Log "$Name returned a non-fatal deferral/retry exit code: $exitCode" 'WARN'
        }
        else {
            Set-State HadVendorFailure $true
            Write-Log "$Name returned an unexpected/non-success exit code: $exitCode" 'WARN'
        }

        return New-ToolResult -Tool $Name -FilePath $FilePath -ExitCode $exitCode -Ran $true -Success ($success -or $reboot -or $warning) -Status $status
    }
    catch {
        Set-State HadVendorFailure $true
        Write-Log "$Name failed to launch or complete: $($_.Exception.Message)" 'ERROR'
        return New-ToolResult -Tool $Name -FilePath $FilePath -Ran $false -Success $false -Status 'LaunchError' -Message $_.Exception.Message
    }
    finally {
        if ($process) { $process.Dispose() }
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    Write-Log "Downloading: $Uri"
    Write-Log "Destination: $OutFile"

    if ($WhatIfOnly) {
        Write-Log 'WhatIfOnly enabled. Skipping download.'
        return $false
    }

    $parent = Split-Path -Path $OutFile -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }

    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
        if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)) { return $true }
    }
    catch {
        Write-Log "Invoke-WebRequest failed: $($_.Exception.Message)" 'WARN'
    }

    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
            Start-BitsTransfer -Source $Uri -Destination $OutFile -ErrorAction Stop
            if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)) { return $true }
        }
    }
    catch {
        Write-Log "BITS download failed: $($_.Exception.Message)" 'WARN'
    }

    return $false
}

function Get-FileSha256String {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (Test-Path -LiteralPath $Path) {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        }
    }
    catch {
        Write-Log "Could not calculate SHA256 for $Path`: $($_.Exception.Message)" 'WARN'
    }

    return ''
}

function Test-Sha256IfConfigured {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedSha256
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return $true }

    $actual = Get-FileSha256String -Path $Path
    if (-not $actual) { return $false }

    if ($actual -eq $ExpectedSha256.ToUpperInvariant()) {
        Write-Log "SHA256 verified for $Path`: $actual"
        return $true
    }

    Write-Log "SHA256 mismatch for $Path. Expected=$ExpectedSha256 Actual=$actual" 'ERROR'
    return $false
}

function Test-PendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]

    $registryMarkers = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting'
    )

    foreach ($marker in $registryMarkers) {
        try {
            if (Test-Path -LiteralPath $marker) { [void]$reasons.Add($marker) }
        }
        catch {}
    }

    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
        if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
            [void]$reasons.Add('PendingFileRenameOperations')
        }
    }
    catch {}

    try {
        $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
        if ($ccm -and (($ccm.RebootPending -eq $true) -or ($ccm.IsHardRebootPending -eq $true))) {
            [void]$reasons.Add('ConfigMgr ClientSDK reboot pending')
        }
    }
    catch {}

    $unique = @($reasons | Sort-Object -Unique)

    [pscustomobject]@{
        Pending = ($unique.Count -gt 0)
        Reasons = $unique
    }
}

function Get-DeviceInfo {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Manufacturer = [string]$computer.Manufacturer
        Model = [string]$computer.Model
        BiosVersion = if ($bios) { [string]$bios.SMBIOSBIOSVersion } else { '' }
    }
}

function Get-OemVendor {
    param([Parameter(Mandatory = $true)]$DeviceInfo)

    $manufacturer = $DeviceInfo.Manufacturer
    $model = $DeviceInfo.Model

    if ($manufacturer -match '(?i)dell') { return 'Dell' }
    if ($manufacturer -match '(?i)lenovo') { return 'Lenovo' }
    if (($manufacturer -match '(?i)\bHP\b|hewlett') -or ($model -match '(?i)\bHP\b')) { return 'HP' }

    return 'Unsupported'
}

function Wait-ForProcessNames {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$ProcessNames,
        [int]$TimeoutMinutes = 60
    )

    if ($TimeoutMinutes -le 0) { return }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $seen = $false

    while ((Get-Date) -lt $deadline) {
        $running = @()
        foreach ($processName in $ProcessNames) {
            $running += Get-Process -Name $processName -ErrorAction SilentlyContinue
        }
        $running = @($running | Sort-Object -Property Id -Unique)

        if ($running.Count -eq 0) {
            if ($seen) { Write-Log "$Label child/background processes have exited." }
            return
        }

        if (-not $seen) {
            $seen = $true
            $list = ($running | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ', '
            Write-Log "Waiting for $Label child/background processes to finish: $list"
        }

        Start-Sleep -Seconds 30
    }

    Set-State HadVendorWarning $true
    Write-Log "Timed out waiting for $Label child/background processes after $TimeoutMinutes minutes." 'WARN'
}

# -----------------------------
# Dell helpers
# -----------------------------

function Find-DellCommandUpdateCli {
    $pf64 = Get-ProgramFiles64
    $pf86 = Get-ProgramFilesX86
    $paths = @("$pf64\Dell\CommandUpdate\dcu-cli.exe")
    if ($pf86) { $paths += "$pf86\Dell\CommandUpdate\dcu-cli.exe" }
    return Resolve-FirstExistingPath -Path $paths
}

function Get-DellClientManagementServiceName {
    $names = @('DellClientManagementService', 'DellClientManagement', 'DellUpdateService')

    foreach ($name in $names) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) { return $svc.Name }
    }

    $svcByDisplayName = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Dell Client Management Service' -or $_.DisplayName -match '(?i)^Dell.*Client.*Management.*Service$' } |
        Select-Object -First 1

    if ($svcByDisplayName) { return $svcByDisplayName.Name }
    return $null
}

function Wait-ServiceStatus {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$DesiredStatus,
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status.ToString() -eq $DesiredStatus) { return $true }
        Start-Sleep -Seconds 2
    }

    return $false
}

function Restart-DellClientManagementService {
    $svcName = Get-DellClientManagementServiceName

    if (-not $svcName) {
        Write-Log 'Dell Client Management Service was not found.' 'WARN'
        return $false
    }

    Write-Log "Dell Client Management Service detected as: $svcName"

    try {
        $cimSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
        if ($cimSvc -and $cimSvc.StartMode -eq 'Disabled') {
            Write-Log 'Dell Client Management Service is disabled. Setting startup type to Automatic.' 'WARN'
            Set-Service -Name $svcName -StartupType Automatic -ErrorAction Stop
        }
    }
    catch {
        Write-Log "Could not inspect or adjust Dell service startup mode: $($_.Exception.Message)" 'WARN'
    }

    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        if ($svc.Status -ne 'Stopped') {
            Write-Log 'Stopping Dell Client Management Service.'
            Stop-Service -Name $svcName -Force -ErrorAction Stop
            if (-not (Wait-ServiceStatus -ServiceName $svcName -DesiredStatus 'Stopped' -TimeoutSeconds $DellClientManagementServiceWaitTimeoutSeconds)) {
                Write-Log 'Dell Client Management Service did not stop within the timeout.' 'WARN'
                return $false
            }
        }

        Write-Log 'Starting Dell Client Management Service.'
        Start-Service -Name $svcName -ErrorAction Stop
        if (-not (Wait-ServiceStatus -ServiceName $svcName -DesiredStatus 'Running' -TimeoutSeconds $DellClientManagementServiceWaitTimeoutSeconds)) {
            Write-Log 'Dell Client Management Service did not reach Running state within the timeout.' 'WARN'
            return $false
        }

        if ($DellClientManagementServicePostStartDelaySeconds -gt 0) {
            Start-Sleep -Seconds $DellClientManagementServicePostStartDelaySeconds
        }

        Set-State DellClientManagementServiceRecovered $true
        return $true
    }
    catch {
        Write-Log "Could not restart Dell Client Management Service: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Test-DotNetDesktopRuntime8Installed {
    $registryPaths = @(
        'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App',
        'HKLM:\SOFTWARE\WOW6432Node\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App'
    )

    foreach ($path in $registryPaths) {
        if (Test-Path -LiteralPath $path) {
            $versions = Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName
            foreach ($version in $versions) {
                try {
                    if (([version]$version).Major -eq 8) {
                        Write-Log ".NET Desktop Runtime 8 detected: $version"
                        return $true
                    }
                }
                catch {}
            }
        }
    }

    foreach ($folder in @('C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App', 'C:\Program Files (x86)\dotnet\shared\Microsoft.WindowsDesktop.App')) {
        if (Test-Path -LiteralPath $folder) {
            foreach ($child in Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue) {
                try {
                    if (([version]$child.Name).Major -eq 8) {
                        Write-Log ".NET Desktop Runtime 8 detected: $($child.FullName)"
                        return $true
                    }
                }
                catch {}
            }
        }
    }

    return $false
}

function Install-DotNetDesktopRuntime8 {
    param([Parameter(Mandatory = $true)][string]$DownloadFolder)

    if (Test-DotNetDesktopRuntime8Installed) { return $true }

    if (-not $InstallDotNetDesktopRuntimeIfMissing) {
        Write-Log '.NET Desktop Runtime 8 is missing and auto-install is disabled.' 'WARN'
        return $false
    }

    $installer = Join-Path $DownloadFolder 'windowsdesktop-runtime-8-win-x64.exe'
    if (-not (Invoke-DownloadFile -Uri $DotNetDesktopRuntime8Url -OutFile $installer)) {
        Set-State HadVendorFailure $true
        Write-Log 'Failed to download .NET Desktop Runtime 8 installer.' 'ERROR'
        return $false
    }

    $result = Invoke-LoggedProcess -Name '.NET Desktop Runtime 8 Installer' -FilePath $installer -Arguments @('/install', '/quiet', '/norestart') -SuccessExitCodes @(0, 1638) -RebootExitCodes @(3010) -TimeoutMinutes 30
    if ($result.Success) {
        Start-Sleep -Seconds 10
        return $true
    }

    return $false
}

function Get-DellCommandUpdateInstallerFile {
    param([Parameter(Mandatory = $true)][string]$DownloadFolder)

    New-Item -ItemType Directory -Path $DownloadFolder -Force | Out-Null
    $installer = Join-Path $DownloadFolder 'Dell-Command-Update-Installer.exe'

    if (-not [string]::IsNullOrWhiteSpace($DellCommandUpdateInstallerLocalPath)) {
        if (Test-Path -LiteralPath $DellCommandUpdateInstallerLocalPath) {
            Write-Log "Using local Dell Command Update installer: $DellCommandUpdateInstallerLocalPath"
            Copy-Item -LiteralPath $DellCommandUpdateInstallerLocalPath -Destination $installer -Force
            if (Test-Sha256IfConfigured -Path $installer -ExpectedSha256 $DellCommandUpdateInstallerSha256) { return $installer }
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Log "Configured DellCommandUpdateInstallerLocalPath does not exist: $DellCommandUpdateInstallerLocalPath" 'WARN'
        }
    }

    foreach ($url in $DellCommandUpdateInstallerUrls) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if (Invoke-DownloadFile -Uri $url -OutFile $installer) {
            if (Test-Sha256IfConfigured -Path $installer -ExpectedSha256 $DellCommandUpdateInstallerSha256) { return $installer }
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
    }

    return $null
}

function Install-DellCommandUpdate {
    param([Parameter(Mandatory = $true)][string]$DownloadFolder)

    if (-not (Install-DotNetDesktopRuntime8 -DownloadFolder $DownloadFolder)) {
        Write-Log 'Dell Command Update install skipped because .NET Desktop Runtime 8 is not available.' 'WARN'
        return $false
    }

    $installer = Get-DellCommandUpdateInstallerFile -DownloadFolder $DownloadFolder
    if (-not $installer) {
        Set-State HadVendorFailure $true
        Write-Log 'Unable to obtain Dell Command Update installer.' 'ERROR'
        return $false
    }

    $installLog = Join-Path $DownloadFolder 'Dell-Command-Update-Install.log'
    $result = Invoke-LoggedProcess -Name 'Dell Command Update Installer' -FilePath $installer -Arguments @('/s', "/l=$installLog") -SuccessExitCodes @(0) -RebootExitCodes @(2, 3010) -TimeoutMinutes 30

    if ($result.Success) {
        Start-Sleep -Seconds 20
        return [bool](Find-DellCommandUpdateCli)
    }

    return $false
}

function Invoke-DellDcuApply {
    param(
        [Parameter(Mandatory = $true)][string]$DellCli,
        [string]$UpdateType,
        [Parameter(Mandatory = $true)][string]$OutputLog,
        [switch]$Unfiltered
    )

    $display = if ($Unfiltered) { 'Dell Command Update Apply Unfiltered' } else { "Dell Command Update Apply $UpdateType" }
    $args = @('/applyUpdates', '-silent', '-reboot=disable', "-outputLog=$OutputLog")
    if (-not $Unfiltered) { $args += "-updateType=$UpdateType" }

    $serviceRestartExitCodes = @(3000, 3001, 3002)
    $serviceBusyExitCodes = @(3003, 3004, 3005)
    $allServiceCodes = $serviceRestartExitCodes + $serviceBusyExitCodes
    $serviceRetry = 0
    $busyStarted = $null
    $busyDeadline = $null

    while ($true) {
        $result = Invoke-LoggedProcess -Name $display -FilePath $DellCli -Arguments $args -SuccessExitCodes @(0, 500) -RebootExitCodes @(1, 5, 14) -WarningExitCodes @(6, 7) -NonFatalExitCodes $allServiceCodes

        if ($null -eq $result.ExitCode -or -not ($allServiceCodes -contains $result.ExitCode)) {
            return $result
        }

        if (($serviceRestartExitCodes -contains $result.ExitCode) -and ($serviceRetry -lt $DellDcuServiceRecoveryRetries)) {
            Write-Log "$display returned Dell service exit code $($result.ExitCode). Restarting Dell service once and retrying." 'WARN'
            [void](Restart-DellClientManagementService)
            $serviceRetry++
            continue
        }

        if ($serviceBusyExitCodes -contains $result.ExitCode) {
            if (-not $busyStarted) {
                $busyStarted = Get-Date
                $busyDeadline = $busyStarted.AddMinutes($DellDcuServiceBusyWaitMinutes)
                Write-Log "$display returned Dell service-busy/pending-update exit code $($result.ExitCode). Waiting before one or more retries." 'WARN'
            }

            if ($DellDcuServiceBusyWaitMinutes -gt 0 -and (Get-Date) -lt $busyDeadline) {
                Start-Sleep -Seconds $DellDcuServiceBusyPollSeconds
                continue
            }

            Set-State DellServiceBusyDeferral $true
            Set-State DellStopFurtherApplyAttempts $true
            Set-State HadVendorWarning $true
            Write-Log "$display remained service-busy after waiting. Deferring further Dell work without repair/reinstall." 'WARN'
            return New-ToolResult -Tool $display -FilePath $DellCli -ExitCode $result.ExitCode -Ran $true -Success $true -Status 'PendingDellServiceWork'
        }

        Set-State DellStopFurtherApplyAttempts $true
        Set-State HadVendorWarning $true
        return New-ToolResult -Tool $display -FilePath $DellCli -ExitCode $result.ExitCode -Ran $true -Success $true -Status 'DellServiceUnavailable'
    }
}

function Invoke-DellUpdates {
    param([Parameter(Mandatory = $true)][string]$BootstrapDir)

    $results = @()
    $dellCli = Find-DellCommandUpdateCli

    if (-not $dellCli -and $InstallDellCommandUpdateIfMissing) {
        Write-Log 'Dell system detected, but dcu-cli.exe was not found. Bootstrapping Dell Command Update.'
        if (Install-DellCommandUpdate -DownloadFolder $BootstrapDir) {
            Set-State DellToolBootstrapped $true
            $dellCli = Find-DellCommandUpdateCli
        }
    }

    if (-not $dellCli) {
        Write-Log 'Dell Command Update CLI was not found. Skipping Dell updates.' 'WARN'
        Set-State HadVendorWarning $true
        return $results
    }

    Set-State SupportedToolFound $true
    Set-State DellToolFound $true

    if ($RestartDellClientManagementServiceBeforeDellApply) {
        [void](Restart-DellClientManagementService)
    }

    $dellNativeLogDir = 'C:\ProgramData\Dell\OEMUpdateRunner\' + $script:RunStamp
    New-Item -ItemType Directory -Path $dellNativeLogDir -Force | Out-Null

    $updateTypes = if ($IncludeBiosFirmwareUpdates) { @('bios', 'firmware', 'driver', 'application') } else { @('driver', 'application') }
    if ($IncludeBiosFirmwareUpdates) {
        Write-Log 'Dell BIOS/Firmware updates are included. Auto-reboot is still suppressed, but this is higher risk.' 'WARN'
    }
    else {
        Write-Log 'Dell BIOS/Firmware updates are excluded. Dell driver/application updates may still require reboot.'
    }

    $allRejectedUpdateType = $true
    $saw107 = $false

    foreach ($type in $updateTypes) {
        if (Get-State DellStopFurtherApplyAttempts) { break }

        $nativeLog = Join-Path $dellNativeLogDir "Dell-Apply-$type.log"
        Set-State DellApplyRan $true

        $result = Invoke-DellDcuApply -DellCli $dellCli -UpdateType $type -OutputLog $nativeLog
        $results += $result
        Write-Log "Dell Command Update native log: $nativeLog"

        if ($result.ExitCode -eq 107) {
            $saw107 = $true
            Write-Log "Dell rejected updateType '$type' with exit code 107." 'WARN'
        }
        else {
            $allRejectedUpdateType = $false
        }
    }

    if ($saw107 -and $allRejectedUpdateType -and -not (Get-State DellStopFurtherApplyAttempts)) {
        Write-Log 'All Dell updateType-filtered attempts returned 107.' 'WARN'

        if ($AllowDellNoUpdateTypeFallback) {
            $nativeLog = Join-Path $dellNativeLogDir 'Dell-Apply-Unfiltered.log'
            Write-Log 'Running Dell unfiltered fallback. This may include BIOS/Firmware depending on Dell policy.' 'WARN'
            Set-State DellApplyRan $true
            $results += Invoke-DellDcuApply -DellCli $dellCli -OutputLog $nativeLog -Unfiltered
            Write-Log "Dell Command Update native log: $nativeLog"
        }
        else {
            Set-State HadVendorWarning $true
            Write-Log 'Dell unfiltered fallback is disabled to avoid accidentally including BIOS/Firmware.' 'WARN'
        }
    }

    return $results
}

# -----------------------------
# Lenovo helpers
# -----------------------------

function Find-LenovoSystemUpdateCli {
    $pf64 = Get-ProgramFiles64
    $pf86 = Get-ProgramFilesX86
    $paths = @("$pf64\Lenovo\System Update\Tvsu.exe")
    if ($pf86) { $paths += "$pf86\Lenovo\System Update\Tvsu.exe" }
    return Resolve-FirstExistingPath -Path $paths
}

function Set-LenovoSystemUpdateSettings {
    $paths = @(
        'HKLM:\SOFTWARE\Lenovo\System Update\Preferences\UserSettings\General',
        'HKLM:\SOFTWARE\WOW6432Node\Lenovo\System Update\Preferences\UserSettings\General',
        'HKLM:\SOFTWARE\Policies\Lenovo\System Update\UserSettings\General',
        'HKLM:\SOFTWARE\WOW6432Node\Policies\Lenovo\System Update\UserSettings\General'
    )

    foreach ($path in $paths) {
        try {
            if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
            New-ItemProperty -Path $path -Name 'DebugEnable' -Value 'YES' -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $path -Name 'MetricsEnabled' -Value 'NO' -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $path -Name 'AskBeforeClosing' -Value 'NO' -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $path -Name 'DisplayLicenseNotice' -Value 'NO' -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $path -Name 'DisplayLicenseNoticeSU' -Value 'NO' -PropertyType String -Force | Out-Null
        }
        catch {
            Write-Log "Could not set Lenovo preference values at $path`: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Install-LenovoSystemUpdate {
    param([Parameter(Mandatory = $true)][string]$DownloadFolder)

    $installer = Join-Path $DownloadFolder 'Lenovo-System-Update-Installer.exe'
    $installLog = Join-Path $DownloadFolder 'Lenovo-System-Update-Install.log'

    if (-not (Invoke-DownloadFile -Uri $LenovoSystemUpdateInstallerUrl -OutFile $installer)) {
        Set-State HadVendorFailure $true
        Write-Log 'Failed to download Lenovo System Update installer.' 'ERROR'
        return $false
    }

    $result = Invoke-LoggedProcess -Name 'Lenovo System Update Installer' -FilePath $installer -Arguments @('/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$installLog") -SuccessExitCodes @(0) -RebootExitCodes @(3010) -WarningExitCodes @(1, 2) -TimeoutMinutes 30

    if ($result.Success) {
        Start-Sleep -Seconds 20
        Set-LenovoSystemUpdateSettings
        return [bool](Find-LenovoSystemUpdateCli)
    }

    return $false
}

function Invoke-LenovoUpdates {
    param([Parameter(Mandatory = $true)][string]$BootstrapDir)

    $results = @()
    $tvsu = Find-LenovoSystemUpdateCli

    if (-not $tvsu -and $InstallLenovoSystemUpdateIfMissing) {
        Write-Log 'Lenovo system detected, but Tvsu.exe was not found. Bootstrapping Lenovo System Update.'
        if (Install-LenovoSystemUpdate -DownloadFolder $BootstrapDir) {
            Set-State LenovoToolBootstrapped $true
            $tvsu = Find-LenovoSystemUpdateCli
        }
    }

    if (-not $tvsu) {
        Write-Log 'Lenovo System Update CLI was not found. Skipping Lenovo updates.' 'WARN'
        Set-State HadVendorWarning $true
        return $results
    }

    Set-State SupportedToolFound $true
    Set-State LenovoToolFound $true
    Set-LenovoSystemUpdateSettings

    $args = @('/CM', '-search', $LenovoSearchMode, '-action', 'INSTALL', '-noicon', '-nolicense', '-exporttowmi')

    if ($InstallRebootRequiredUpdatesNoAutoReboot) {
        $args += @('-includerebootpackages', $LenovoRebootPackageTypes, '-noreboot')
        Write-Log "Lenovo reboot-required packages included for reboot package type(s): $LenovoRebootPackageTypes. -noreboot is enabled." 'WARN'
        if ($LenovoRebootPackageTypes -ne '3') {
            Write-Log "LenovoRebootPackageTypes is not exactly '3'. Other values may carry higher reboot/shutdown risk." 'WARN'
        }
    }
    else {
        Write-Log 'Lenovo reboot-required packages are not explicitly included.'
    }

    if ($IncludeBiosFirmwareUpdates) {
        Write-Log 'Lenovo BIOS/Firmware inclusion is vendor/package dependent. Review TVSU logs carefully.' 'WARN'
    }

    Set-State LenovoApplyRan $true
    $result = Invoke-LoggedProcess -Name 'Lenovo System Update Apply' -FilePath $tvsu -Arguments $args -SuccessExitCodes @(0) -RebootExitCodes @(3010) -WarningExitCodes @(1)
    $results += $result

    Wait-ForProcessNames -Label 'Lenovo System Update' -ProcessNames @('tvsu', 'tvsukernel', 'tvsucommandlauncher', 'tvsuscheduler') -TimeoutMinutes $LenovoPostProcessWaitMinutes
    return $results
}

# -----------------------------
# HP helpers
# -----------------------------

function Find-HPImageAssistant {
    $pf64 = Get-ProgramFiles64
    $pf86 = Get-ProgramFilesX86
    $paths = @(
        "$HPImageAssistantInstallDir\HPImageAssistant.exe",
        "$pf64\HP\HP Image Assistant\HPImageAssistant.exe",
        "$pf64\HPIA\HPImageAssistant.exe",
        'C:\SWSetup\HPImageAssistant.exe'
    )
    if ($pf86) {
        $paths += "$pf86\HP\HP Image Assistant\HPImageAssistant.exe"
        $paths += "$pf86\HPIA\HPImageAssistant.exe"
    }

    $known = Resolve-FirstExistingPath -Path $paths
    if ($known) { return $known }

    foreach ($root in @($HPImageAssistantInstallDir, 'C:\SWSetup')) {
        if (Test-Path -LiteralPath $root) {
            $found = Get-ChildItem -LiteralPath $root -Filter 'HPImageAssistant.exe' -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }

    return $null
}

function Install-HPImageAssistant {
    param([Parameter(Mandatory = $true)][string]$DownloadFolder)

    $installer = Join-Path $DownloadFolder 'HP-Image-Assistant-Installer.exe'

    if (-not (Invoke-DownloadFile -Uri $HPImageAssistantInstallerUrl -OutFile $installer)) {
        Set-State HadVendorFailure $true
        Write-Log 'Failed to download HP Image Assistant installer.' 'ERROR'
        return $false
    }

    New-Item -ItemType Directory -Path $HPImageAssistantInstallDir -Force | Out-Null
    $result = Invoke-LoggedProcess -Name 'HP Image Assistant Installer' -FilePath $installer -Arguments @('/s', '/e', "/f$HPImageAssistantInstallDir") -SuccessExitCodes @(0, 1168) -RebootExitCodes @(3010) -TimeoutMinutes 30

    if ($result.Success) {
        Start-Sleep -Seconds 10
        return [bool](Find-HPImageAssistant)
    }

    return $false
}

function Invoke-HPUpdates {
    param([Parameter(Mandatory = $true)][string]$BootstrapDir)

    $results = @()
    $hpia = Find-HPImageAssistant

    if (-not $hpia -and $InstallHPImageAssistantIfMissing) {
        Write-Log 'HP system detected, but HPImageAssistant.exe was not found. Bootstrapping HP Image Assistant.'
        if (Install-HPImageAssistant -DownloadFolder $BootstrapDir) {
            Set-State HPToolBootstrapped $true
            $hpia = Find-HPImageAssistant
        }
    }

    if (-not $hpia) {
        Write-Log 'HP Image Assistant was not found. Skipping HP updates.' 'WARN'
        Set-State HadVendorWarning $true
        return $results
    }

    Set-State SupportedToolFound $true
    Set-State HPToolFound $true

    $reportRoot = Join-Path $script:RunLogDir 'HP-Report'
    $softPaqRoot = Join-Path $script:RunLogDir 'HP-SoftPaqs'
    New-Item -ItemType Directory -Path $reportRoot, $softPaqRoot -Force | Out-Null

    if ($HPCategoryMode -eq 'All') {
        $categories = @('All')
        Write-Log 'HP category mode is All. BIOS/Firmware may be included and may require restart.' 'WARN'
    }
    else {
        $categories = @('Drivers', 'Software')
        if ($IncludeBiosFirmwareUpdates) {
            $categories += @('Firmware', 'BIOS')
            Write-Log 'HP Firmware/BIOS categories are included. This is higher risk.' 'WARN'
        }
        else {
            Write-Log 'HP categories are Drivers and Software. BIOS/Firmware are excluded.'
        }
    }

    foreach ($category in $categories) {
        $categoryReport = Join-Path $reportRoot $category
        $categoryDownloads = Join-Path $softPaqRoot $category
        New-Item -ItemType Directory -Path $categoryReport, $categoryDownloads -Force | Out-Null

        Set-State HPApplyRan $true
        $results += Invoke-LoggedProcess -Name "HP Image Assistant Apply $category" -FilePath $hpia -Arguments @(
            '/Operation:Analyze',
            "/Category:$category",
            '/Selection:All',
            '/Action:Install',
            '/Silent',
            '/Noninteractive',
            '/AutoCleanup',
            "/ReportFolder:$categoryReport",
            "/SoftPaqDownloadFolder:$categoryDownloads"
        ) -SuccessExitCodes @(0, 256, 257) -RebootExitCodes @(3010, 3011, 3020) -WarningExitCodes @(4096, 4104)
    }

    Write-Log "HP Image Assistant report folder: $reportRoot"
    return $results
}

function Write-FinalSummary {
    param([object[]]$Results)

    Write-Log 'Summary:'
    foreach ($result in $Results) {
        if ($result) {
            Write-Log "$($result.Tool) | Ran=$($result.Ran) | Success=$($result.Success) | Status=$($result.Status) | ExitCode=$($result.ExitCode)"
        }
    }

    foreach ($key in $script:RunState.Keys) {
        Write-Log "$key`: $($script:RunState[$key])"
    }

    Write-Log 'OEM update run complete.'
}

function Write-RmmOutput {
    param([string]$Result = 'Complete')

    Write-Output "OEMUPDATER_RESULT=$Result"
    foreach ($key in $script:RunState.Keys) {
        $name = ($key -replace '([a-z])([A-Z])', '$1_$2').ToUpperInvariant()
        Write-Output "OEMUPDATER_$name=$($script:RunState[$key])"
    }
    Write-Output "OEMUPDATER_LOG=$script:MainLog"
}

# -----------------------------
# Main
# -----------------------------

$mutex = New-Object System.Threading.Mutex($false, 'Global\OEMUpdateRunner')
$hasMutex = $false

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        Write-Output 'OEMUPDATER_RESULT=AlreadyRunning'
        Write-Output "OEMUPDATER_LOG=$script:MainLog"
        exit 0
    }

    if (-not (Test-IsAdmin)) {
        throw 'This script must run elevated. In ConnectWise RMM, run it as System or Admin.'
    }

    Write-Log 'Starting OEM update detection.'
    Write-Log "PowerShell version: $($PSVersionTable.PSVersion)"
    Write-Log "64-bit OS: $([Environment]::Is64BitOperatingSystem)"
    Write-Log "64-bit PowerShell process: $([Environment]::Is64BitProcess)"
    if ($script:PasteMode64BitRelaunchUnavailable) { Write-Log 'Running in 32-bit PowerShell and no script file path is available for self-relaunch. This usually means the script was pasted into RMM. Prefer ConnectWise 64-bit PowerShell execution. Continuing with 64-bit-aware paths where possible.' 'WARN' }
    Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "Log folder: $script:RunLogDir"
    Write-Log "InstallRebootRequiredUpdatesNoAutoReboot=$InstallRebootRequiredUpdatesNoAutoReboot"
    Write-Log "IncludeBiosFirmwareUpdates=$IncludeBiosFirmwareUpdates"

    $device = Get-DeviceInfo
    $vendor = Get-OemVendor -DeviceInfo $device
    Write-Log "Manufacturer: $($device.Manufacturer)"
    Write-Log "Model: $($device.Model)"
    Write-Log "BIOS: $($device.BiosVersion)"
    Write-Log "Detected OEM runner: $vendor"

    $pending = Test-PendingReboot
    if ($pending.Pending) {
        Set-State WindowsPendingRebootDetected $true
        Set-State RebootRequired $true
        Set-State HadVendorWarning $true
        Write-Log "Windows pending reboot indicators detected: $($pending.Reasons -join '; ')" 'WARN'

        if ($SkipWhenWindowsPendingReboot) {
            Write-Log 'SkipWhenWindowsPendingReboot is enabled. Vendor update install/apply will be skipped to avoid compounding staged work.' 'WARN'
            Write-FinalSummary -Results @()
            Write-RmmOutput -Result 'SkippedPendingReboot'
            exit 0
        }
    }
    else {
        Write-Log 'No Windows pending reboot indicators were detected by built-in checks.'
    }

    $bootstrapDir = Join-Path $script:RunLogDir 'Bootstrap'
    New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null

    $results = @()

    switch ($vendor) {
        'Dell'   { $results += @(Invoke-DellUpdates -BootstrapDir $bootstrapDir) }
        'Lenovo' { $results += @(Invoke-LenovoUpdates -BootstrapDir $bootstrapDir) }
        'HP'     { $results += @(Invoke-HPUpdates -BootstrapDir $bootstrapDir) }
        default  {
            Write-Log 'This endpoint does not match the supported Dell, Lenovo, or HP OEM patterns. Skipping.' 'WARN'
            Set-State HadVendorWarning $true
        }
    }

    if (-not (Get-State SupportedToolFound)) {
        Write-Log 'No supported OEM CLI tool was found or bootstrapped.' 'WARN'
    }

    Write-FinalSummary -Results $results
    Write-RmmOutput -Result 'Complete'

    if ($ReturnNonZeroOnVendorFailure -and (Get-State HadVendorFailure)) { exit 2 }
    exit 0
}
catch {
    try { Write-Log "Fatal script error: $($_.Exception.Message)" 'ERROR' } catch {}
    Write-Output 'OEMUPDATER_RESULT=FatalError'
    Write-Output "OEMUPDATER_ERROR=$($_.Exception.Message)"
    Write-Output "OEMUPDATER_LOG=$script:MainLog"
    exit 1
}
finally {
    if ($hasMutex) { $mutex.ReleaseMutex() | Out-Null }
    if ($mutex) { $mutex.Dispose() }
}
