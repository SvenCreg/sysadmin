<#
ConnectWise RMM-safe OEM update runner
- Dell Command | Update
- Lenovo System Update
- HP Image Assistant

Run as System/Admin.
Do not enable auto reboot.
Recommended timeout: 120 minutes or higher.

Policy:
- Install selected OEM updates.
- Allow reboot-required updates where vendor CLI supports suppressing auto-reboot.
- Never intentionally restart the endpoint.
- BIOS/Firmware are excluded by default because those are highest reboot-risk.
#>

# ============================================================
# ConnectWise RMM Defaults
# ============================================================

$LenovoSearchMode = "R"                  # C = Critical, R = Critical + Recommended, A = Critical + Recommended + Optional
$HPCategoryMode = "DriversSoftware"      # DriversSoftware or All

$InstallDellCommandUpdateIfMissing = $true
$InstallDotNetDesktopRuntimeIfMissing = $true

$InstallLenovoSystemUpdateIfMissing = $true
$InstallHPImageAssistantIfMissing = $true

# Shared reboot policy
$InstallRebootRequiredUpdatesNoAutoReboot = $true
$IncludeBiosFirmwareUpdates = $false

# Lenovo-specific reboot package handling.
# "3" is the safest no-auto-reboot setting. Avoid "1,3,4" unless you accept higher vendor reboot/shutdown risk.
$LenovoRebootPackageTypes = "3"

# Dell service recovery
$RestartDellClientManagementServiceBeforeDellApply = $true
$RestartDellClientManagementServiceOnServiceError = $true
$DellClientManagementServiceForceStop = $true
$DellClientManagementServiceWaitTimeoutSeconds = 90
$DellClientManagementServicePostStartDelaySeconds = 20
$DellDcuServiceRecoveryExitCodes = @(3000, 3001, 3002, 3003, 3004, 3005)
$DellDcuServiceRestartRecoveryExitCodes = @(3000, 3001, 3002)
$DellDcuServiceBusyExitCodes = @(3003, 3004, 3005)
$DellDcuServiceRecoveryRetries = 1
$DellDcuServiceBusyWaitMinutes = 30
$DellDcuServiceBusyPollSeconds = 60
# Dell documents 3003/3004/3005 as wait states, not proof that DCU is corrupt.
# Keep this false for RMM runs where avoiding unnecessary reboot debt is more important than forcing repair.
$DellDcuTreatPersistentServiceBusyAsRebootRequired = $false
$DellDcuRepairPersistentBusyAfterWait = $false

# Avoid compounding a pending reboot. If Windows already has a pending reboot marker, skip Dell install/apply.
$SkipDellCommandUpdateWhenWindowsPendingReboot = $true

# Dell Command Update repair path for persistent service state problems.
# Default is intentionally conservative: do not repair on 3003/3004/3005 because Dell documents those as busy/pending-update states.
# Avoid uninstall/reinstall by default because failed MSI removal can leave DCU in a broken 1714/1612 state.
$RepairDellCommandUpdateOnPersistentServiceBusy = $false
$DellCommandUpdateRepairOnExitCodes = @()
$DellCommandUpdateRepairRetriesPerRun = 1
$DellCommandUpdateUninstallTimeoutMinutes = 15
$DellCommandUpdateRepairPostInstallDelaySeconds = 30
$DellCommandUpdateAllowUninstallReinstallRepair = $false
$DellCommandUpdateMsiSourceErrorCodes = @(1612, 1714)
$DellCommandUpdateEnableMsiSourceErrorRegistryCleanup = $true

# .NET detection fallback.
# Some systems do not expose the runtime immediately in registry after install.
# If the installer exits successfully but detection still fails, allow Dell install to continue.
$AssumeDotNetDesktopRuntime8InstalledAfterSuccessfulInstaller = $true

$EnableLenovoDebugLogging = $true
$LenovoArtifactLookbackMinutes = 15
$LenovoArtifactInventoryMaxItems = 300
$LenovoArtifactParseMaxDetailLines = 40

$AllowDellNoUpdateTypeFallback = $false

$VendorTimeoutMinutes = 120
$LenovoPostProcessWaitMinutes = 90

$WhatIfOnly = $false
$ReturnNonZeroOnVendorFailure = $false

# Dell Command Update installer sources.
# No private hosting required. The script tries Dell's driver details page, known Dell direct URLs,
# then optional Chocolatey fallback for install-only scenarios.
$DellCommandUpdateDriverId = "FGK9X"
$DellCommandUpdateInstallerFileName = "Dell-Command-Update-Windows-Universal-Application_FGK9X_WIN64_5.7.0_A00.EXE"
$DellCommandUpdateInstallerSha256 = "98C20D9809D7469A760B42A9A258E8C67A35C6CF46AA6A9C173E29D39A056D89"

$DellCommandUpdateDriverDetailsUrls = @(
    "https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=$DellCommandUpdateDriverId",
    "https://www.dell.com/support/home/en-ca/drivers/driversdetails?driverid=$DellCommandUpdateDriverId"
)

$DellCommandUpdateKnownDirectUrls = @(
    "https://dl.dell.com/FOLDER14424601M/1/$DellCommandUpdateInstallerFileName",
    "https://downloads.dell.com/FOLDER14424601M/1/$DellCommandUpdateInstallerFileName"
)

# Optional local path. Leave blank unless you later decide to attach/cache the installer locally on endpoints.
$DellCommandUpdateInstallerLocalPath = ""

# Chocolatey fallback is useful when DCU is missing, Dell direct download is blocked, or DCU repair is needed.
# If choco.exe is missing and InstallChocolateyIfMissing is enabled, the script installs Chocolatey first.
$UseChocolateyFallbackForDellCommandUpdateInstall = $true
$UseChocolateyFallbackForDellCommandUpdateRepair = $true
$InstallChocolateyIfMissing = $true
$ChocolateyInstallScriptUrl = "https://community.chocolatey.org/install.ps1"
$ChocolateyInstallTimeoutMinutes = 15
$ChocolateyInstallPostInstallDelaySeconds = 10
$ChocolateyDellCommandUpdatePackageId = "dellcommandupdate"
$DotNetDesktopRuntime8Url = "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"

$LenovoSystemUpdateInstallerUrl = "https://download.lenovo.com/pccbbs/thinkvantage_en/system_update_5.08.03.59.exe"

$HPImageAssistantInstallerUrl = "https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.4.exe"
$HPImageAssistantInstallDir = "C:\Program Files\HP\HPIA"

# ============================================================
# Script starts here
# ============================================================

$ErrorActionPreference = "Stop"

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnativePowerShell = "$env:WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

    if ((Test-Path $sysnativePowerShell) -and $PSCommandPath) {
        & $sysnativePowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseLogDir = "C:\ProgramData\OEMUpdateRunner"
$RunStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$RunLogDir = Join-Path $BaseLogDir $RunStamp
$MainLog = Join-Path $RunLogDir "OEMUpdateRunner.log"

New-Item -ItemType Directory -Path $RunLogDir -Force | Out-Null

$global:HadVendorFailure = $false
$global:HadVendorWarning = $false
$global:RebootRequired = $false
$global:SupportedToolFound = $false

$global:DellToolFound = $false
$global:DellApplyRan = $false
$global:DellToolBootstrapped = $false
$global:DellClientManagementServiceRecovered = $false
$global:DellCommandUpdateRepairAttempted = $false
$global:DellCommandUpdateRepairSucceeded = $false
$global:DellCommandUpdateRepairRequiresReboot = $false
$global:DellServiceBusyDeferral = $false
$global:WindowsPendingRebootDetected = $false
$global:DellStopFurtherApplyAttempts = $false
$script:LastDellCommandUpdateInstallerExitCode = $null
$script:LastDellCommandUpdateInstallerLog = ""
$script:LastDellCommandUpdateInstallerHadMsiSourceError = $false

$global:LenovoToolFound = $false
$global:LenovoApplyRan = $false
$global:LenovoToolBootstrapped = $false
$global:LenovoLikelyNoApplicableUpdates = $false
$global:LenovoRebootMetadataFound = $false

$global:HPToolFound = $false
$global:HPApplyRan = $false
$global:HPToolBootstrapped = $false

$lenovoHistory = $null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp [$Level] $Message"

    Add-Content -Path $MainLog -Value $line
    Write-Host $line
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ProgramFiles64 {
    if ($env:ProgramW6432) {
        return $env:ProgramW6432
    }

    return $env:ProgramFiles
}

function Get-ProgramFilesX86 {
    $path = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Machine")

    if (-not $path) {
        $path = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Process")
    }

    if (-not $path -and [Environment]::Is64BitOperatingSystem) {
        $path = "C:\Program Files (x86)"
    }

    if (-not $path) {
        $path = Get-ProgramFiles64
    }

    return $path
}

function Get-FirstExistingPath {
    param(
        [string[]]$Paths
    )

    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Get-InstalledAppNames {
    $names = New-Object System.Collections.Generic.List[string]
    $registryViews = @("Registry64","Registry32")

    foreach ($view in $registryViews) {
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                [Microsoft.Win32.RegistryView]::$view
            )

            $uninstallKey = $baseKey.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")

            if ($uninstallKey) {
                foreach ($subName in $uninstallKey.GetSubKeyNames()) {
                    $subKey = $uninstallKey.OpenSubKey($subName)

                    if ($subKey) {
                        $displayName = $subKey.GetValue("DisplayName")

                        if ($displayName) {
                            [void]$names.Add([string]$displayName)
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "Could not read $view uninstall registry view: $($_.Exception.Message)" "WARN"
        }
    }

    return $names | Sort-Object -Unique
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )

    Write-Log "Downloading: $Uri"
    Write-Log "Destination: $OutFile"

    if ($WhatIfOnly) {
        Write-Log "WhatIfOnly enabled. Skipping download."
        return $false
    }

    $parent = Split-Path -Path $OutFile -Parent

    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    try {
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }

        $headers = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
            "Accept" = "application/octet-stream,application/exe,application/vnd.microsoft.portable-executable,*/*"
            "Accept-Language" = "en-US,en;q=0.9"
            "Referer" = "https://www.dell.com/support/home/drivers/driversdetails"
        }

        Invoke-WebRequest `
            -Uri $Uri `
            -OutFile $OutFile `
            -UseBasicParsing `
            -Headers $headers `
            -MaximumRedirection 10 `
            -ErrorAction Stop

        if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)) {
            return $true
        }
    }
    catch {
        Write-Log "Invoke-WebRequest failed: $($_.Exception.Message)" "WARN"
    }

    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            if (Test-Path -LiteralPath $OutFile) {
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            }

            Start-BitsTransfer `
                -Source $Uri `
                -Destination $OutFile `
                -ErrorAction Stop

            if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)) {
                return $true
            }
        }
    }
    catch {
        Write-Log "BITS download failed: $($_.Exception.Message)" "WARN"
    }

    try {
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }

        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        $webClient.Headers.Add("Referer", "https://www.dell.com/support/home/drivers/driversdetails")
        $webClient.DownloadFile($Uri, $OutFile)
        $webClient.Dispose()

        if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)) {
            return $true
        }

        return $false
    }
    catch {
        Write-Log "WebClient download failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function ConvertTo-ArgumentLine {
    param(
        [string[]]$Arguments
    )

    $escapedArgs = foreach ($arg in $Arguments) {
        $argString = [string]$arg

        if ($argString -match '[\s"]') {
            '"' + ($argString -replace '"','\"') + '"'
        }
        else {
            $argString
        }
    }

    return ($escapedArgs -join " ")
}

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [int[]]$SuccessExitCodes = @(0),

        [int[]]$RebootExitCodes = @(),

        [int[]]$WarningExitCodes = @(),

        [int[]]$NonFatalUnexpectedExitCodes = @()
    )

    $safeName = $Name -replace "[^\w.-]", "_"
    $stdoutFile = Join-Path $RunLogDir "$safeName-stdout.log"
    $stderrFile = Join-Path $RunLogDir "$safeName-stderr.log"

    Write-Log "$Name detected: $FilePath"
    Write-Log "$Name arguments: $($Arguments -join " ")"

    if ($WhatIfOnly) {
        Write-Log "WhatIfOnly enabled. Skipping $Name execution."

        return [pscustomobject]@{
            Tool = $Name
            FilePath = $FilePath
            ExitCode = $null
            Ran = $false
            Success = $true
            Status = "WhatIf"
        }
    }

    $process = $null

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = ConvertTo-ArgumentLine -Arguments $Arguments
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

        $timeoutMs = $VendorTimeoutMinutes * 60 * 1000
        $finished = $process.WaitForExit($timeoutMs)

        if (-not $finished) {
            try {
                $process.Kill()
            }
            catch {}

            Write-Log "$Name timed out after $VendorTimeoutMinutes minutes and was killed." "ERROR"
            $global:HadVendorFailure = $true

            return [pscustomobject]@{
                Tool = $Name
                FilePath = $FilePath
                ExitCode = $null
                Ran = $true
                Success = $false
                Status = "Timeout"
            }
        }

        $process.WaitForExit()
        $process.Refresh()

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result

        if ($stdout) {
            [System.IO.File]::WriteAllText($stdoutFile, $stdout)
        }

        if ($stderr) {
            [System.IO.File]::WriteAllText($stderrFile, $stderr)
        }

        $exitCode = [int]$process.ExitCode

        Write-Log "$Name finished with exit code $exitCode."

        if ($stdout) {
            Write-Log "$Name stdout saved to $stdoutFile"
        }

        if ($stderr) {
            Write-Log "$Name stderr saved to $stderrFile"
        }

        $isSuccessCode = $SuccessExitCodes -contains $exitCode
        $isRebootCode = $RebootExitCodes -contains $exitCode
        $isWarningCode = $WarningExitCodes -contains $exitCode
        $isNonFatalUnexpectedCode = $NonFatalUnexpectedExitCodes -contains $exitCode

        $status = "Failure"

        if ($isSuccessCode) {
            $status = "Success"
        }

        if ($isRebootCode) {
            $status = "RebootRequired"
            $global:RebootRequired = $true
            Write-Log "$Name reports reboot required or pending, but this script will not restart the device." "WARN"
        }

        if ($isWarningCode) {
            $status = "Warning"
            $global:HadVendorWarning = $true
            Write-Log "$Name returned a warning or partial-success exit code: $exitCode" "WARN"
        }

        $success = $isSuccessCode -or $isRebootCode -or $isWarningCode

        if (-not $success) {
            if ($isNonFatalUnexpectedCode) {
                Write-Log "$Name returned recoverable/non-fatal unexpected exit code: $exitCode" "WARN"
            }
            else {
                $global:HadVendorFailure = $true
                Write-Log "$Name returned an unexpected or non-success exit code: $exitCode" "WARN"
            }
        }

        return [pscustomobject]@{
            Tool = $Name
            FilePath = $FilePath
            ExitCode = $exitCode
            Ran = $true
            Success = $success
            Status = $status
        }
    }
    catch {
        Write-Log "$Name failed to launch or complete: $($_.Exception.Message)" "ERROR"
        $global:HadVendorFailure = $true

        return [pscustomobject]@{
            Tool = $Name
            FilePath = $FilePath
            ExitCode = $null
            Ran = $false
            Success = $false
            Status = "LaunchError"
            Error = $_.Exception.Message
        }
    }
    finally {
        if ($process) {
            $process.Dispose()
        }
    }
}

function Invoke-CommandLineLogged {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$CommandLine,

        [int[]]$SuccessExitCodes = @(0),

        [int[]]$RebootExitCodes = @(3010, 1641),

        [int[]]$WarningExitCodes = @()
    )

    Write-Log "$Name command line: $CommandLine"

    return Invoke-LoggedProcess `
        -Name $Name `
        -FilePath "$env:WINDIR\System32\cmd.exe" `
        -Arguments @("/d", "/c", $CommandLine) `
        -SuccessExitCodes $SuccessExitCodes `
        -RebootExitCodes $RebootExitCodes `
        -WarningExitCodes $WarningExitCodes
}

function Wait-ForProcessNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string[]]$ProcessNames,

        [int]$TimeoutMinutes = 60
    )

    if ($TimeoutMinutes -le 0) {
        return
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $seenRunning = $false

    while ((Get-Date) -lt $deadline) {
        $running = @()

        foreach ($processName in $ProcessNames) {
            $running += Get-Process -Name $processName -ErrorAction SilentlyContinue
        }

        $running = @($running | Sort-Object -Property Id -Unique)

        if ($running.Count -eq 0) {
            if ($seenRunning) {
                Write-Log "$Label child/background processes have exited."
            }

            return
        }

        if (-not $seenRunning) {
            $seenRunning = $true
            $processList = ($running | ForEach-Object { "$($_.ProcessName)($($_.Id))" }) -join ", "
            Write-Log "Waiting for $Label child/background processes to finish: $processList"
        }

        Start-Sleep -Seconds 30
    }

    Write-Log "Timed out waiting for $Label child/background processes after $TimeoutMinutes minutes." "WARN"
    $global:HadVendorWarning = $true
}

# ============================================================
# Dell service recovery and repair helpers
# ============================================================

function Get-DellClientManagementServiceName {
    $candidateNames = @(
        "DellClientManagementService",
        "DellClientManagement",
        "DellUpdateService"
    )

    foreach ($candidateName in $candidateNames) {
        $svc = Get-Service -Name $candidateName -ErrorAction SilentlyContinue

        if ($svc) {
            return $svc.Name
        }
    }

    $svcByDisplayName = Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -eq "Dell Client Management Service" -or
            $_.DisplayName -match "(?i)^Dell.*Client.*Management.*Service$"
        } |
        Select-Object -First 1

    if ($svcByDisplayName) {
        return $svcByDisplayName.Name
    }

    try {
        $cimSvc = Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -eq "Dell Client Management Service" -or
                $_.DisplayName -match "(?i)^Dell.*Client.*Management.*Service$"
            } |
            Select-Object -First 1

        if ($cimSvc) {
            return $cimSvc.Name
        }
    }
    catch {}

    return $null
}

function Wait-ServiceStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,

        [Parameter(Mandatory = $true)]
        [string]$DesiredStatus,

        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

        if ($svc -and $svc.Status.ToString() -eq $DesiredStatus) {
            return $true
        }

        Start-Sleep -Seconds 2
    }

    return $false
}

function Restart-DellClientManagementService {
    param(
        [bool]$ForceStop = $true,

        [int]$WaitTimeoutSeconds = 90,

        [int]$PostStartDelaySeconds = 20
    )

    $svcName = Get-DellClientManagementServiceName

    if (-not $svcName) {
        Write-Log "Dell Client Management Service was not found. Dell Command Update may need repair/reinstall." "WARN"
        return $false
    }

    Write-Log "Dell Client Management Service detected as service name: $svcName"

    try {
        $cimSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue

        if ($cimSvc -and $cimSvc.StartMode -eq "Disabled") {
            Write-Log "Dell Client Management Service is disabled. Setting startup type to Automatic." "WARN"

            try {
                Set-Service -Name $svcName -StartupType Automatic -ErrorAction Stop
            }
            catch {
                Write-Log "Set-Service failed for Dell Client Management Service startup type. Trying sc.exe config. Error: $($_.Exception.Message)" "WARN"
                & sc.exe config $svcName start= auto | Out-Null
            }
        }
    }
    catch {
        Write-Log "Could not inspect Dell Client Management Service startup mode: $($_.Exception.Message)" "WARN"
    }

    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop

        if ($svc.Status -ne "Stopped") {
            Write-Log "Stopping Dell Client Management Service. ForceStop=$ForceStop"

            if ($ForceStop) {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
            }
            else {
                Stop-Service -Name $svcName -ErrorAction Stop
            }

            $stopped = Wait-ServiceStatus `
                -ServiceName $svcName `
                -DesiredStatus "Stopped" `
                -TimeoutSeconds $WaitTimeoutSeconds

            if (-not $stopped) {
                Write-Log "Dell Client Management Service did not stop within $WaitTimeoutSeconds seconds." "WARN"
                return $false
            }
        }
        else {
            Write-Log "Dell Client Management Service is already stopped."
        }
    }
    catch {
        Write-Log "Could not stop Dell Client Management Service: $($_.Exception.Message)" "WARN"
        return $false
    }

    try {
        Write-Log "Starting Dell Client Management Service."
        Start-Service -Name $svcName -ErrorAction Stop

        $running = Wait-ServiceStatus `
            -ServiceName $svcName `
            -DesiredStatus "Running" `
            -TimeoutSeconds $WaitTimeoutSeconds

        if (-not $running) {
            Write-Log "Dell Client Management Service did not reach Running state within $WaitTimeoutSeconds seconds." "WARN"
            return $false
        }

        if ($PostStartDelaySeconds -gt 0) {
            Write-Log "Waiting $PostStartDelaySeconds seconds after Dell Client Management Service start."
            Start-Sleep -Seconds $PostStartDelaySeconds
        }

        $global:DellClientManagementServiceRecovered = $true
        Write-Log "Dell Client Management Service restart completed."
        return $true
    }
    catch {
        Write-Log "Could not start Dell Client Management Service: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Test-PendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]

    $rebootKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
    )

    foreach ($keyPath in $rebootKeys) {
        try {
            if (Test-Path -LiteralPath $keyPath) {
                [void]$reasons.Add($keyPath)
            }
        }
        catch {}
    }

    try {
        $sessionManager = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ErrorAction SilentlyContinue

        if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
            [void]$reasons.Add("HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations value")
        }
    }
    catch {}

    try {
        $ccm = Invoke-CimMethod -Namespace "root\ccm\ClientSDK" -ClassName "CCM_ClientUtilities" -MethodName "DetermineIfRebootPending" -ErrorAction Stop

        if ($ccm -and (($ccm.RebootPending -eq $true) -or ($ccm.IsHardRebootPending -eq $true))) {
            [void]$reasons.Add("ConfigMgr ClientSDK reboot pending")
        }
    }
    catch {}

    $uniqueReasons = @($reasons | Sort-Object -Unique)

    if ($uniqueReasons.Count -gt 0) {
        Write-Log "Windows pending reboot indicators detected: $($uniqueReasons -join '; ')" "WARN"
        return $true
    }

    Write-Log "No Windows pending reboot indicators were detected by the built-in checks."
    return $false
}

function Test-IsDellCommandUpdateDisplayName {
    param(
        [string]$DisplayName
    )

    if (-not $DisplayName) {
        return $false
    }

    $name = $DisplayName.Trim()

    if ($name -match "(?i)^Dell\s+Command\s*\|\s*Update") {
        return $true
    }

    if ($name -match "(?i)^Dell\s+Command\s+Update") {
        return $true
    }

    if ($name -match "(?i)^Dell\s+Update(\s+for\s+Windows\s+Universal)?$") {
        return $true
    }

    if ($name -match "(?i)^Dell\s+Command\s*\|\s*Update\s+for\s+Windows\s+Universal") {
        return $true
    }

    if ($name -match "(?i)^Dell\s+Command\s+Update\s+for\s+Windows\s+Universal") {
        return $true
    }

    if ($name -match "(?i)^Dell\s+Client\s+Management\s+Service") {
        return $true
    }

    return $false
}

function Get-DellCommandUpdateInstalledApp {
    $matches = [System.Collections.ArrayList]::new()
    $registryViews = @("Registry64", "Registry32")

    foreach ($view in $registryViews) {
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                [Microsoft.Win32.RegistryView]::$view
            )

            $uninstallKey = $baseKey.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")

            if (-not $uninstallKey) {
                continue
            }

            foreach ($subName in $uninstallKey.GetSubKeyNames()) {
                $subKey = $uninstallKey.OpenSubKey($subName)

                if (-not $subKey) {
                    continue
                }

                $displayName = [string]$subKey.GetValue("DisplayName")

                if (-not (Test-IsDellCommandUpdateDisplayName -DisplayName $displayName)) {
                    continue
                }

                [void]$matches.Add([pscustomobject]@{
                    DisplayName = $displayName
                    DisplayVersion = [string]$subKey.GetValue("DisplayVersion")
                    UninstallString = [string]$subKey.GetValue("UninstallString")
                    QuietUninstallString = [string]$subKey.GetValue("QuietUninstallString")
                    WindowsInstaller = [string]$subKey.GetValue("WindowsInstaller")
                    RegistryKeyName = $subName
                    RegistryView = $view
                })
            }
        }
        catch {
            Write-Log "Could not inspect Dell Command Update uninstall registry in $view`: $($_.Exception.Message)" "WARN"
        }
    }

    return @($matches | Sort-Object DisplayName, DisplayVersion -Descending)
}

function Uninstall-DellCommandUpdate {
    param(
        [int]$TimeoutMinutes = 15
    )

    $apps = @(Get-DellCommandUpdateInstalledApp)

    if ($apps.Count -eq 0) {
        Write-Log "Dell Command Update uninstall entry was not found. It may already be removed or registered under an unexpected name." "WARN"

        $existingCli = Find-DellCommandUpdateCli

        if ($existingCli) {
            Write-Log "Dell Command Update CLI still exists even though no uninstall entry was found: $existingCli" "WARN"
        }

        return $true
    }

    $allSucceeded = $true

    foreach ($app in $apps) {
        Write-Log "Dell Command Update uninstall candidate: $($app.DisplayName) $($app.DisplayVersion) [$($app.RegistryView)]"

        $commandLine = $null
        $guid = $null

        if ($app.RegistryKeyName -match "^\{[0-9A-Fa-f-]{36}\}$") {
            $guid = $app.RegistryKeyName
        }
        elseif ($app.UninstallString -match "\{[0-9A-Fa-f-]{36}\}") {
            $guid = $Matches[0]
        }

        if ($guid) {
            $commandLine = "msiexec.exe /x $guid /qn /norestart"
        }
        elseif ($app.QuietUninstallString) {
            $commandLine = $app.QuietUninstallString
        }
        elseif ($app.UninstallString) {
            if ($app.UninstallString -match "(?i)msiexec") {
                $commandLine = ($app.UninstallString -replace "(?i)/I", "/x" -replace "(?i)/X", "/x")

                if ($commandLine -notmatch "(?i)/q") {
                    $commandLine += " /qn"
                }

                if ($commandLine -notmatch "(?i)norestart") {
                    $commandLine += " /norestart"
                }
            }
            else {
                $commandLine = $app.UninstallString

                if ($commandLine -notmatch "(?i)(/quiet|/qn|/s|/silent)") {
                    $commandLine += " /quiet"
                }

                if ($commandLine -notmatch "(?i)norestart") {
                    $commandLine += " /norestart"
                }
            }
        }

        if (-not $commandLine) {
            Write-Log "Could not determine uninstall command for Dell Command Update entry: $($app.DisplayName)" "WARN"
            $allSucceeded = $false
            continue
        }

        $oldTimeout = $script:VendorTimeoutMinutes
        $script:VendorTimeoutMinutes = $TimeoutMinutes

        try {
            $uninstallResult = Invoke-CommandLineLogged `
                -Name "Dell Command Update Uninstall" `
                -CommandLine $commandLine `
                -SuccessExitCodes @(0, 1605, 1614) `
                -RebootExitCodes @(3010, 1641)

            if (-not $uninstallResult.Success) {
                Write-Log "Dell Command Update uninstall did not report success. ExitCode=$($uninstallResult.ExitCode)" "WARN"
                $allSucceeded = $false
            }
        }
        finally {
            $script:VendorTimeoutMinutes = $oldTimeout
        }
    }

    Start-Sleep -Seconds 10

    $remainingCli = Find-DellCommandUpdateCli

    if ($remainingCli) {
        Write-Log "Dell Command Update CLI still exists after uninstall attempt: $remainingCli" "WARN"
    }
    else {
        Write-Log "Dell Command Update CLI is no longer present after uninstall."
    }

    return $allSucceeded
}

function Repair-DellCommandUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )

    if ($global:DellCommandUpdateRepairAttempted) {
        Write-Log "Dell Command Update repair was already attempted during this script run. Skipping another repair." "WARN"
        return $false
    }

    $global:DellCommandUpdateRepairAttempted = $true

    Write-Log "Starting Dell Command Update repair path because persistent DCU service-busy state was detected." "WARN"

    New-Item -ItemType Directory -Path $DownloadFolder -Force | Out-Null

    $svcName = Get-DellClientManagementServiceName

    if ($svcName) {
        try {
            Write-Log "Stopping Dell Client Management Service before Dell Command Update repair."
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue

            [void](Wait-ServiceStatus `
                -ServiceName $svcName `
                -DesiredStatus "Stopped" `
                -TimeoutSeconds $DellClientManagementServiceWaitTimeoutSeconds)
        }
        catch {
            Write-Log "Could not stop Dell Client Management Service before repair: $($_.Exception.Message)" "WARN"
        }
    }

    if ($UseChocolateyFallbackForDellCommandUpdateRepair) {
        Write-Log "Trying Chocolatey Dell Command Update repair/install first."
        $chocoRepairSucceeded = Install-DellCommandUpdateWithChocolatey -Force

        if ($chocoRepairSucceeded) {
            Write-Log "Chocolatey Dell Command Update repair/install completed."

            [void](Restart-DellClientManagementService `
                -ForceStop $DellClientManagementServiceForceStop `
                -WaitTimeoutSeconds $DellClientManagementServiceWaitTimeoutSeconds `
                -PostStartDelaySeconds $DellClientManagementServicePostStartDelaySeconds)

            if ($script:LastDellCommandUpdateChocolateyRequiresReboot) {
                Write-Log "Chocolatey Dell Command Update repair completed and reported reboot required. DCU apply will be deferred until after reboot." "WARN"
                $global:DellCommandUpdateRepairRequiresReboot = $true
                $global:RebootRequired = $true
            }

            $global:DellCommandUpdateRepairSucceeded = $true
            return $true
        }

        Write-Log "Chocolatey Dell Command Update repair/install did not succeed. Trying Dell EXE fallback without uninstalling first." "WARN"
    }
    else {
        Write-Log "Chocolatey Dell Command Update repair is disabled."
    }

    Write-Log "Pre-downloading and verifying Dell Command Update installer for in-place repair. Existing DCU will not be uninstalled by default."
    $preDownloadedDcuInstaller = Get-DellCommandUpdateInstallerFile -DownloadFolder $DownloadFolder

    if (-not $preDownloadedDcuInstaller -or -not (Test-Path -LiteralPath $preDownloadedDcuInstaller)) {
        Write-Log "Dell Command Update repair aborted because replacement installer could not be downloaded and verified." "ERROR"
        $global:DellCommandUpdateRepairSucceeded = $false
        return $false
    }

    if ($svcName) {
        try {
            Write-Log "Stopping Dell Client Management Service before Dell Command Update in-place repair."
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue

            [void](Wait-ServiceStatus `
                -ServiceName $svcName `
                -DesiredStatus "Stopped" `
                -TimeoutSeconds $DellClientManagementServiceWaitTimeoutSeconds)
        }
        catch {
            Write-Log "Could not stop Dell Client Management Service before in-place repair: $($_.Exception.Message)" "WARN"
        }
    }

    Write-Log "Trying Dell Command Update EXE in-place repair/install before any uninstall attempt."

    $installed = Install-DellCommandUpdate `
        -DownloadFolder $DownloadFolder `
        -PreDownloadedInstallerPath $preDownloadedDcuInstaller `
        -AllowChocolateyFallback $false

    if (-not $installed -and $script:LastDellCommandUpdateInstallerHadMsiSourceError) {
        Write-Log "Dell Command Update in-place repair detected MSI 1612/1714-style source/removal errors. Attempting targeted stale Dell DCU MSI registration cleanup, then one reinstall retry." "WARN"

        $msiCleanupBackupDir = Join-Path $DownloadFolder "Dell-MSI-Source-Error-Registry-Backup"
        $cleanupSucceeded = Invoke-DellCommandUpdateMsiSourceErrorCleanup -BackupFolder $msiCleanupBackupDir

        if ($cleanupSucceeded) {
            $installed = Install-DellCommandUpdate `
                -DownloadFolder $DownloadFolder `
                -PreDownloadedInstallerPath $preDownloadedDcuInstaller `
                -AllowChocolateyFallback $false
        }
    }

    if (-not $installed) {
        if (-not $DellCommandUpdateAllowUninstallReinstallRepair) {
            Write-Log "Dell Command Update repair failed, but DellCommandUpdateAllowUninstallReinstallRepair is disabled. Not uninstalling DCU because failed uninstall/reinstall is the path that can leave MSI 1714/1612 corruption." "ERROR"
            $global:DellCommandUpdateRepairSucceeded = $false
            return $false
        }

        Write-Log "DellCommandUpdateAllowUninstallReinstallRepair is enabled. Proceeding with uninstall/reinstall as a last resort because in-place repair failed and replacement installer is cached." "WARN"

        if ($svcName) {
            try {
                Write-Log "Stopping Dell Client Management Service before Dell Command Update last-resort uninstall/reinstall."
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue

                [void](Wait-ServiceStatus `
                    -ServiceName $svcName `
                    -DesiredStatus "Stopped" `
                    -TimeoutSeconds $DellClientManagementServiceWaitTimeoutSeconds)
            }
            catch {
                Write-Log "Could not stop Dell Client Management Service before last-resort uninstall/reinstall: $($_.Exception.Message)" "WARN"
            }
        }

        $uninstallSucceeded = Uninstall-DellCommandUpdate -TimeoutMinutes $DellCommandUpdateUninstallTimeoutMinutes

        if (-not $uninstallSucceeded) {
            Write-Log "Dell Command Update uninstall had warnings or failures. Continuing with reinstall attempt because replacement installer is already cached." "WARN"
        }

        $installed = Install-DellCommandUpdate `
            -DownloadFolder $DownloadFolder `
            -PreDownloadedInstallerPath $preDownloadedDcuInstaller `
            -AllowChocolateyFallback $false
    }

    if (-not $installed) {
        Write-Log "Dell Command Update repair failed because install/repair did not complete successfully." "ERROR"
        $global:DellCommandUpdateRepairSucceeded = $false
        return $false
    }

    Start-Sleep -Seconds $DellCommandUpdateRepairPostInstallDelaySeconds

    $newCli = Find-DellCommandUpdateCli

    if (-not $newCli) {
        Write-Log "Dell Command Update repair failed because dcu-cli.exe was not found after repair/install." "ERROR"
        $global:DellCommandUpdateRepairSucceeded = $false
        return $false
    }

    Write-Log "Dell Command Update repair/install completed. New CLI path: $newCli"

    if ($script:LastDellCommandUpdateInstallerRequiresReboot) {
        Write-Log "Dell Command Update installer reported reboot required during repair. DCU apply will be deferred until after reboot." "WARN"
        $global:DellCommandUpdateRepairRequiresReboot = $true
        $global:RebootRequired = $true
    }

    [void](Restart-DellClientManagementService `
        -ForceStop $DellClientManagementServiceForceStop `
        -WaitTimeoutSeconds $DellClientManagementServiceWaitTimeoutSeconds `
        -PostStartDelaySeconds $DellClientManagementServicePostStartDelaySeconds)

    $global:DellCommandUpdateRepairSucceeded = $true
    return $true
}

function Invoke-DellCommandUpdateApplyWithServiceRecovery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DellCli,

        [string]$UpdateType,

        [Parameter(Mandatory = $true)]
        [string]$OutputLog,

        [switch]$Unfiltered
    )

    if ($Unfiltered) {
        $displayName = "Dell Command Update Apply Unfiltered"
        $arguments = @("/applyUpdates", "-silent", "-reboot=disable", "-outputLog=$OutputLog")
    }
    else {
        $displayName = "Dell Command Update Apply $UpdateType"
        $arguments = @("/applyUpdates", "-silent", "-reboot=disable", "-updateType=$UpdateType", "-outputLog=$OutputLog")
    }

    $effectiveDellCli = $DellCli
    $serviceRetryAttempt = 0
    $repairRetryAttempt = 0
    $busyWaitAttempt = 0
    $busyWaitStarted = $null
    $busyWaitDeadline = $null
    $result = $null

    if ($RestartDellClientManagementServiceBeforeDellApply -and -not $script:DellClientManagementServiceRestartedThisRun) {
        Write-Log "RestartDellClientManagementServiceBeforeDellApply is enabled. Restarting Dell Client Management Service before DCU apply."

        [void](Restart-DellClientManagementService `
            -ForceStop $DellClientManagementServiceForceStop `
            -WaitTimeoutSeconds $DellClientManagementServiceWaitTimeoutSeconds `
            -PostStartDelaySeconds $DellClientManagementServicePostStartDelaySeconds)

        $script:DellClientManagementServiceRestartedThisRun = $true
    }

    while ($true) {
        if ($global:DellStopFurtherApplyAttempts) {
            Write-Log "$displayName skipped because DellStopFurtherApplyAttempts=True." "WARN"
            return [pscustomobject]@{
                Tool = $displayName
                FilePath = $effectiveDellCli
                ExitCode = $null
                Ran = $false
                Success = $true
                Status = "SkippedAfterPriorDellDeferral"
            }
        }

        if ($serviceRetryAttempt -gt 0) {
            Write-Log "$displayName service recovery retry attempt $serviceRetryAttempt." "WARN"
        }

        if ($repairRetryAttempt -gt 0) {
            Write-Log "$displayName post-repair retry attempt $repairRetryAttempt." "WARN"
        }

        if ($busyWaitAttempt -gt 0) {
            Write-Log "$displayName Dell service-busy wait retry attempt $busyWaitAttempt." "WARN"
        }

        $result = Invoke-LoggedProcess `
            -Name $displayName `
            -FilePath $effectiveDellCli `
            -Arguments $arguments `
            -SuccessExitCodes @(0, 500) `
            -RebootExitCodes @(1, 5, 14) `
            -WarningExitCodes @(6, 7) `
            -NonFatalUnexpectedExitCodes $DellDcuServiceRecoveryExitCodes

        if ($null -eq $result) {
            return $result
        }

        if (-not ($DellDcuServiceRecoveryExitCodes -contains $result.ExitCode)) {
            return $result
        }

        if ($DellDcuServiceBusyExitCodes -contains $result.ExitCode) {
            if (-not $busyWaitStarted) {
                $busyWaitStarted = Get-Date
                $busyWaitDeadline = $busyWaitStarted.AddMinutes($DellDcuServiceBusyWaitMinutes)
                Write-Log "$displayName returned Dell service-busy/pending-update exit code $($result.ExitCode). Dell documents this as a wait condition, so repair/reinstall is not attempted by default." "WARN"
            }

            if ((Get-Date) -lt $busyWaitDeadline -and $DellDcuServiceBusyWaitMinutes -gt 0) {
                $busyWaitAttempt++
                Write-Log "Waiting $DellDcuServiceBusyPollSeconds seconds before retrying $displayName because Dell Client Management Service is busy or installing pending updates." "WARN"
                Start-Sleep -Seconds $DellDcuServiceBusyPollSeconds
                continue
            }

            Write-Log "$displayName still returned Dell service-busy/pending-update exit code $($result.ExitCode) after waiting up to $DellDcuServiceBusyWaitMinutes minutes." "WARN"

            if (-not $DellDcuRepairPersistentBusyAfterWait) {
                if ($DellDcuTreatPersistentServiceBusyAsRebootRequired) {
                    Write-Log "Treating persistent Dell service-busy state as pending Dell work/reboot-required and deferring further Dell apply attempts. The script will not restart the endpoint." "WARN"
                    $global:RebootRequired = $true
                    $global:HadVendorWarning = $true
                    $global:DellServiceBusyDeferral = $true
                    $global:DellStopFurtherApplyAttempts = $true

                    return [pscustomobject]@{
                        Tool = $displayName
                        FilePath = $effectiveDellCli
                        ExitCode = $result.ExitCode
                        Ran = $true
                        Success = $true
                        Status = "PendingDellServiceWorkOrRebootRequired"
                    }
                }

                Write-Log "Persistent Dell service-busy state will be reported as a warning deferral instead of a repair or reboot-required failure." "WARN"
                $global:HadVendorWarning = $true
                $global:DellServiceBusyDeferral = $true
                $global:DellStopFurtherApplyAttempts = $true

                return [pscustomobject]@{
                    Tool = $displayName
                    FilePath = $effectiveDellCli
                    ExitCode = $result.ExitCode
                    Ran = $true
                    Success = $true
                    Status = "PendingDellServiceWork"
                }
            }

            Write-Log "DellDcuRepairPersistentBusyAfterWait is enabled. Proceeding to configured repair path after persistent service-busy state." "WARN"
        }

        if (
            $RestartDellClientManagementServiceOnServiceError -and
            ($DellDcuServiceRestartRecoveryExitCodes -contains $result.ExitCode) -and
            $serviceRetryAttempt -lt $DellDcuServiceRecoveryRetries
        ) {
            Write-Log "$displayName returned Dell service-related exit code $($result.ExitCode). Restarting Dell Client Management Service and retrying." "WARN"

            [void](Restart-DellClientManagementService `
                -ForceStop $DellClientManagementServiceForceStop `
                -WaitTimeoutSeconds $DellClientManagementServiceWaitTimeoutSeconds `
                -PostStartDelaySeconds $DellClientManagementServicePostStartDelaySeconds)

            $serviceRetryAttempt++
            continue
        }

        if (
            $RepairDellCommandUpdateOnPersistentServiceBusy -and
            ($DellCommandUpdateRepairOnExitCodes -contains $result.ExitCode) -and
            ($repairRetryAttempt -lt $DellCommandUpdateRepairRetriesPerRun) -and
            (-not $global:DellCommandUpdateRepairAttempted)
        ) {
            Write-Log "$displayName returned Dell service-related exit code $($result.ExitCode) after recovery. Starting Dell Command Update repair path." "WARN"

            $repairDir = Join-Path $RunLogDir "DellCommandUpdateRepair"
            $repairSucceeded = Repair-DellCommandUpdate -DownloadFolder $repairDir

            if ($repairSucceeded) {
                $effectiveDellCli = Find-DellCommandUpdateCli

                if (-not $effectiveDellCli) {
                    Write-Log "Dell Command Update repair reported success, but dcu-cli.exe was not found. Cannot retry $displayName." "ERROR"
                    $global:HadVendorFailure = $true
                    $global:DellStopFurtherApplyAttempts = $true
                    return $result
                }

                if ($global:DellCommandUpdateRepairRequiresReboot) {
                    $repairExitCode = $script:LastDellCommandUpdateInstallerExitCode

                    if ($null -eq $repairExitCode) {
                        $repairExitCode = $script:LastDellCommandUpdateChocolateyExitCode
                    }

                    if ($null -eq $repairExitCode) {
                        $repairExitCode = $result.ExitCode
                    }

                    Write-Log "Dell Command Update repair succeeded but reported reboot required. Deferring $displayName until after reboot instead of immediately retrying DCU." "WARN"
                    $global:RebootRequired = $true
                    $global:HadVendorWarning = $true
                    $global:DellStopFurtherApplyAttempts = $true

                    return [pscustomobject]@{
                        Tool = $displayName
                        FilePath = $effectiveDellCli
                        ExitCode = $repairExitCode
                        Ran = $true
                        Success = $true
                        Status = "RebootRequiredAfterDcuRepair"
                    }
                }

                $serviceRetryAttempt = 0
                $repairRetryAttempt++
                $script:DellClientManagementServiceRestartedThisRun = $true

                Write-Log "Retrying $displayName after Dell Command Update repair." "WARN"
                continue
            }
            else {
                Write-Log "Dell Command Update repair failed. Stopping further Dell apply attempts for this run." "ERROR"
                $global:HadVendorFailure = $true
                $global:DellStopFurtherApplyAttempts = $true
                return $result
            }
        }

        if (-not $RepairDellCommandUpdateOnPersistentServiceBusy -and ($DellDcuServiceRecoveryExitCodes -contains $result.ExitCode)) {
            Write-Log "$displayName returned Dell service-related exit code $($result.ExitCode), but Dell Command Update repair is disabled by policy to avoid creating reboot-required/staged MSI state. Deferring Dell work as a warning." "WARN"
            $global:HadVendorWarning = $true
            $global:DellServiceBusyDeferral = $true
            $global:DellStopFurtherApplyAttempts = $true

            return [pscustomobject]@{
                Tool = $displayName
                FilePath = $effectiveDellCli
                ExitCode = $result.ExitCode
                Ran = $true
                Success = $true
                Status = "DellServiceUnavailableRepairDisabled"
            }
        }

        Write-Log "$displayName returned Dell service-related exit code $($result.ExitCode), but recovery/repair limits have been reached." "WARN"
        $global:HadVendorFailure = $true
        $global:DellStopFurtherApplyAttempts = $true
        return $result
    }
}

# ============================================================
# Lenovo helpers
# ============================================================

function Set-LenovoSystemUpdateSettings {
    param(
        [bool]$EnableDebug = $true
    )

    $generalPreferencePaths = @(
        "HKLM:\SOFTWARE\Lenovo\System Update\Preferences\UserSettings\General",
        "HKLM:\SOFTWARE\WOW6432Node\Lenovo\System Update\Preferences\UserSettings\General",
        "HKLM:\SOFTWARE\Policies\Lenovo\System Update\UserSettings\General",
        "HKLM:\SOFTWARE\WOW6432Node\Policies\Lenovo\System Update\UserSettings\General"
    )

    foreach ($prefPath in $generalPreferencePaths) {
        try {
            if (-not (Test-Path -LiteralPath $prefPath)) {
                New-Item -Path $prefPath -Force | Out-Null
            }

            if ($EnableDebug) {
                New-ItemProperty -Path $prefPath -Name "DebugEnable" -Value "YES" -PropertyType String -Force | Out-Null
            }

            New-ItemProperty -Path $prefPath -Name "MetricsEnabled" -Value "NO" -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $prefPath -Name "AskBeforeClosing" -Value "NO" -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $prefPath -Name "DisplayLicenseNotice" -Value "NO" -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $prefPath -Name "DisplayLicenseNoticeSU" -Value "NO" -PropertyType String -Force | Out-Null

            Write-Log "Set Lenovo System Update preferences at $prefPath"
        }
        catch {
            Write-Log "Could not set Lenovo System Update preference registry values at $prefPath`: $($_.Exception.Message)" "WARN"
        }
    }
}

function Get-RecentLenovoArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$RunStartTime,

        [int]$LookbackMinutes = 15,

        [int]$MaxItems = 300
    )

    $roots = New-Object System.Collections.Generic.List[string]

    $candidateRoots = @(
        "C:\ProgramData\Lenovo",
        "C:\Program Files (x86)\Lenovo\System Update",
        "C:\Program Files\Lenovo\System Update",
        "C:\Windows\Temp",
        "C:\Windows\SystemTemp"
    )

    foreach ($root in $candidateRoots) {
        if ($root -and (Test-Path -LiteralPath $root)) {
            [void]$roots.Add($root)
        }
    }

    $recentFiles = @()
    $cutoff = $RunStartTime.AddMinutes(-1 * [math]::Abs($LookbackMinutes))

    foreach ($root in $roots) {
        try {
            $recentFiles += Get-ChildItem -Path $root -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.LastWriteTime -ge $cutoff -and
                    (
                        $_.FullName -match "(?i)lenovo|tvsu|system.update|systemupdate|applicability|update|trace|log" -or
                        $root -match "(?i)\\Lenovo"
                    )
                } |
                Where-Object {
                    $_.FullName -notmatch "(?i)\\unins\d*\.dat$"
                }
        }
        catch {
            Write-Log "Could not inventory Lenovo artifacts under $root`: $($_.Exception.Message)" "WARN"
        }
    }

    $recentFiles = @($recentFiles |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $MaxItems)

    return $recentFiles
}

function Write-LenovoArtifactInventory {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Files
    )

    $inventoryFile = Join-Path $RunLogDir "Lenovo-Recent-Artifact-Inventory.txt"

    try {
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add("Lenovo recent artifact inventory")
        [void]$lines.Add("Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")")
        [void]$lines.Add("Count: $($Files.Count)")
        [void]$lines.Add("")

        foreach ($file in $Files) {
            $length = $null
            try {
                $length = $file.Length
            }
            catch {}

            [void]$lines.Add("$($file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")) | $length bytes | $($file.FullName)")
        }

        [System.IO.File]::WriteAllLines($inventoryFile, $lines.ToArray())
        Write-Log "Lenovo artifact inventory saved to $inventoryFile"
        return $inventoryFile
    }
    catch {
        Write-Log "Could not write Lenovo artifact inventory: $($_.Exception.Message)" "WARN"
        return $null
    }
}

function Copy-LenovoKeyArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Files
    )

    $copyDir = Join-Path $RunLogDir "Lenovo-Key-Artifacts"
    $copiedFiles = [System.Collections.ArrayList]::new()

    try {
        New-Item -ItemType Directory -Path $copyDir -Force | Out-Null
    }
    catch {
        Write-Log "Could not create Lenovo key artifact folder $copyDir`: $($_.Exception.Message)" "WARN"

        return [pscustomobject]@{
            CopyDir = $copyDir
            CopiedFiles = $copiedFiles
        }
    }

    $keyFiles = @($Files | Where-Object {
        $_.FullName -match "(?i)\\UpdateTaskList\.xml$" -or
        $_.FullName -match "(?i)\\update_history\.db$" -or
        $_.FullName -match "(?i)\\ApplicabilityRulesTrace\.txt$"
    })

    foreach ($file in $keyFiles) {
        try {
            $safeName = $file.FullName -replace "^[A-Za-z]:\\", ""
            $safeName = $safeName -replace '[\\/:*?"<>|]', "_"

            $destPath = Join-Path $copyDir $safeName

            Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force -ErrorAction Stop
            [void]$copiedFiles.Add($destPath)
        }
        catch {
            Write-Log "Could not copy Lenovo key artifact $($file.FullName): $($_.Exception.Message)" "WARN"
        }
    }

    if ($copiedFiles.Count -gt 0) {
        Write-Log "Copied $($copiedFiles.Count) Lenovo key artifact(s) to $copyDir"
    }
    else {
        Write-Log "No Lenovo key artifacts were copied." "WARN"
    }

    return [pscustomobject]@{
        CopyDir = $copyDir
        CopiedFiles = $copiedFiles
    }
}

function Get-LenovoUpdateTaskListSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Files,

        [int]$MaxSamples = 10
    )

    $samples = [System.Collections.ArrayList]::new()

    $taskListFile = $Files |
        Where-Object { $_.FullName -match "(?i)\\UpdateTaskList\.xml$" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $taskListFile) {
        return [pscustomobject]@{
            Found = $false
            SourcePath = ""
            SizeBytes = 0
            ParseSucceeded = $false
            ParseError = ""
            RootName = ""
            ChildElementCount = 0
            TaskLikeElementCount = 0
            Empty = $false
            LikelyNoApplicableUpdates = $false
            Samples = $samples
        }
    }

    $sourcePath = $taskListFile.FullName
    $sizeBytes = 0

    try {
        $sizeBytes = [int64]$taskListFile.Length
    }
    catch {}

    $parseSucceeded = $false
    $parseError = ""
    $rootName = ""
    $childElementCount = 0
    $taskLikeElementCount = 0
    $isEmpty = $false
    $likelyNoApplicableUpdates = $false

    try {
        $rawXml = Get-Content -LiteralPath $sourcePath -Raw -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($rawXml)) {
            $isEmpty = $true
            $likelyNoApplicableUpdates = $true

            return [pscustomobject]@{
                Found = $true
                SourcePath = $sourcePath
                SizeBytes = $sizeBytes
                ParseSucceeded = $true
                ParseError = ""
                RootName = ""
                ChildElementCount = 0
                TaskLikeElementCount = 0
                Empty = $isEmpty
                LikelyNoApplicableUpdates = $likelyNoApplicableUpdates
                Samples = $samples
            }
        }

        [xml]$xml = $rawXml
        $parseSucceeded = $true

        $root = $xml.DocumentElement

        if ($root) {
            $rootName = $root.LocalName
        }

        $allElements = @($xml.SelectNodes("//*"))

        if ($root) {
            $childElements = @($allElements | Where-Object { -not [object]::ReferenceEquals($_, $root) })
        }
        else {
            $childElements = @($allElements)
        }

        $childElementCount = $childElements.Count

        $containerNames = @(
            "UpateTaskListInfo",
            "UpdateTaskListInfo",
            "UpdateTaskList",
            "UpdateStatusList",
            "StatusList",
            "TaskList",
            "PackageList",
            "Updates",
            "Packages"
        )

        $realTaskLikeElements = @($childElements | Where-Object {
            $localName = $_.LocalName
            $isContainer = $containerNames -contains $localName
            $nameLooksLikeTask = $localName -match "(?i)task|status|update|package|install|driver|firmware|software|dependency|reboot"

            $attributeCount = 0
            try {
                if ($_.Attributes) {
                    $attributeCount = $_.Attributes.Count
                }
            }
            catch {}

            $elementChildCount = 0
            try {
                $elementChildCount = @($_.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element }).Count
            }
            catch {}

            $textValue = ""
            try {
                $textValue = ($_.InnerText -replace "\s+", " ").Trim()
            }
            catch {}

            $hasUsefulContent = $false

            if ($attributeCount -gt 0) {
                $hasUsefulContent = $true
            }

            if ($elementChildCount -gt 0 -and -not $isContainer) {
                $hasUsefulContent = $true
            }

            if ($textValue -and $textValue.Length -gt 0 -and -not $isContainer) {
                $hasUsefulContent = $true
            }

            (-not $isContainer) -and $nameLooksLikeTask -and $hasUsefulContent
        })

        $taskLikeElementCount = $realTaskLikeElements.Count

        if ($taskLikeElementCount -gt 0) {
            foreach ($node in $realTaskLikeElements) {
                if ($samples.Count -ge $MaxSamples) {
                    break
                }

                $sampleParts = [System.Collections.ArrayList]::new()
                [void]$sampleParts.Add("Element=$($node.LocalName)")

                if ($node.Attributes) {
                    foreach ($attrName in @("name","title","id","package","version","severity","status","result","reboot","type")) {
                        $attr = $node.Attributes[$attrName]

                        if ($attr -and $attr.Value) {
                            [void]$sampleParts.Add("$attrName=$($attr.Value)")
                        }
                    }
                }

                $inner = ""
                try {
                    $inner = ($node.InnerText -replace "\s+", " ").Trim()
                }
                catch {}

                if ($inner -and $inner.Length -le 200) {
                    [void]$sampleParts.Add("Text=$inner")
                }

                [void]$samples.Add(($sampleParts -join "; "))
            }
        }
        else {
            foreach ($node in $childElements) {
                if ($samples.Count -ge $MaxSamples) {
                    break
                }

                [void]$samples.Add("CONTAINER_ONLY: Element=$($node.LocalName)")
            }
        }

        if ($taskLikeElementCount -eq 0) {
            $isEmpty = $true
            $likelyNoApplicableUpdates = $true
        }
        else {
            $isEmpty = $false
            $likelyNoApplicableUpdates = $false
        }
    }
    catch {
        $parseSucceeded = $false
        $parseError = $_.Exception.Message
    }

    return [pscustomobject]@{
        Found = $true
        SourcePath = $sourcePath
        SizeBytes = $sizeBytes
        ParseSucceeded = $parseSucceeded
        ParseError = $parseError
        RootName = $rootName
        ChildElementCount = $childElementCount
        TaskLikeElementCount = $taskLikeElementCount
        Empty = $isEmpty
        LikelyNoApplicableUpdates = $likelyNoApplicableUpdates
        Samples = $samples
    }
}

function Test-LenovoParserNoiseLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    if ($Line -match "(?i)^(none|null|true|false|fffe|ffff|0x[0-9a-f]+|\d+)$") {
        return $true
    }

    if ($Line -match "(?i)^Microsoft Hardware Error Device Driver$") {
        return $true
    }

    if ($Line -match "(?i)^Windows Error Reporting Service$") {
        return $true
    }

    if ($Line -match "(?i)^Windows Error Reporting$") {
        return $true
    }

    return $false
}

function Add-LenovoParsedDetail {
    param(
        $DetailList,

        [Parameter(Mandatory = $true)]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$SourceFile,

        [Parameter(Mandatory = $true)]
        [string]$Line,

        [int]$MaxDetailLines = 40
    )

    if ($null -eq $DetailList) {
        return
    }

    if ($DetailList.Count -lt $MaxDetailLines) {
        [void]$DetailList.Add(($Type + ": [" + $SourceFile + "] " + $Line))
    }
}

function Get-LenovoUpdateHistorySummary {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$RunStartTime,

        [int]$MaxDetailLines = 40
    )

    $detailLines = [System.Collections.ArrayList]::new()
    $logFilesReviewed = [System.Collections.ArrayList]::new()
    $wmiItems = [System.Collections.ArrayList]::new()

    $installedCount = 0
    $failedCount = 0
    $skippedCount = 0
    $notApplicableCount = 0
    $rebootMentionCount = 0
    $wmiItemsFound = 0

    $recentArtifacts = @(Get-RecentLenovoArtifacts `
        -RunStartTime $RunStartTime `
        -LookbackMinutes $LenovoArtifactLookbackMinutes `
        -MaxItems $LenovoArtifactInventoryMaxItems)

    $inventoryFile = Write-LenovoArtifactInventory -Files $recentArtifacts
    $keyArtifactCopy = Copy-LenovoKeyArtifacts -Files $recentArtifacts
    $taskListSummary = Get-LenovoUpdateTaskListSummary -Files $recentArtifacts

    $parseableArtifacts = @($recentArtifacts |
        Where-Object {
            $_.Extension -match "(?i)\.log|\.txt|\.xml|\.csv|\.dat" -and
            $_.Length -gt 0 -and
            $_.Length -lt 10485760
        } |
        Where-Object {
            $_.FullName -notmatch "(?i)\\unins\d*\.dat$"
        })

    foreach ($logFile in $parseableArtifacts) {
        [void]$logFilesReviewed.Add($logFile.FullName)

        try {
            $lines = Get-Content -LiteralPath $logFile.FullName -ErrorAction Stop
        }
        catch {
            continue
        }

        foreach ($line in $lines) {
            $cleanLine = ($line -replace "\s+", " ").Trim()

            if (-not $cleanLine) {
                continue
            }

            if (Test-LenovoParserNoiseLine -Line $cleanLine) {
                continue
            }

            $hasStrongLenovoContext = $cleanLine -match "(?i)\b(lenovo|tvsu|system update|thin installer|thininstaller|applicability|package|packages|update|updates|install|installed|installation|download|extract|repository|severity|result|return code|exit code|reboot type)\b"
            $hasFailureWord = $cleanLine -match "(?i)\b(failed|failure|fail)\b"
            $hasErrorWord = $cleanLine -match "(?i)\b(error|exception)\b"
            $hasInstallSuccess = $cleanLine -match "(?i)\b(successfully installed|install(ed|ation)?\b.*\b(success|successful|completed)|[1-9][0-9]*\s+(package|packages|update|updates)\s+(were\s+)?installed)\b"
            $hasSkipped = $cleanLine -match "(?i)\b(skip|skipped|not selected|not installed)\b"
            $hasNoUpdates = $cleanLine -match "(?i)\bnot applicable\b|\bno applicable\b|\bno updates\b|\bno packages\b|\bno package\b|\bno updates found\b|\bnothing to install\b"
            $hasReboot = $cleanLine -match "(?i)\breboot\b|\brestart\b"
            $hasBadReturnCode = $cleanLine -match "(?i)\b(return code|exit code|result code)\b\s*[:=]?\s*(1|[2-9][0-9]*)\b"

            if ($hasInstallSuccess -and $hasStrongLenovoContext) {
                $installedCount++
                Add-LenovoParsedDetail -DetailList $detailLines -Type "INSTALLED" -SourceFile $logFile.FullName -Line $cleanLine -MaxDetailLines $MaxDetailLines
                continue
            }

            if ($hasNoUpdates -and $hasStrongLenovoContext) {
                $notApplicableCount++
                Add-LenovoParsedDetail -DetailList $detailLines -Type "NOT_APPLICABLE" -SourceFile $logFile.FullName -Line $cleanLine -MaxDetailLines $MaxDetailLines
                continue
            }

            if ($hasSkipped -and $hasStrongLenovoContext) {
                $skippedCount++
                Add-LenovoParsedDetail -DetailList $detailLines -Type "SKIPPED" -SourceFile $logFile.FullName -Line $cleanLine -MaxDetailLines $MaxDetailLines
                continue
            }

            if ($hasReboot -and $hasStrongLenovoContext) {
                $rebootMentionCount++
                Add-LenovoParsedDetail -DetailList $detailLines -Type "REBOOT" -SourceFile $logFile.FullName -Line $cleanLine -MaxDetailLines $MaxDetailLines
                continue
            }

            if ($hasStrongLenovoContext -and ($hasFailureWord -or $hasBadReturnCode)) {
                $failedCount++
                Add-LenovoParsedDetail -DetailList $detailLines -Type "FAILED" -SourceFile $logFile.FullName -Line $cleanLine -MaxDetailLines $MaxDetailLines
                continue
            }

            if ($hasStrongLenovoContext -and $hasErrorWord -and ($cleanLine -match "(?i)\b(lenovo|tvsu|system update|package|update|install|download|extract|applicability|repository|return code|exit code|result code)\b")) {
                $failedCount++
                Add-LenovoParsedDetail -DetailList $detailLines -Type "FAILED" -SourceFile $logFile.FullName -Line $cleanLine -MaxDetailLines $MaxDetailLines
                continue
            }
        }
    }

    $wmiNamespacesToTry = @(
        "root\Lenovo",
        "root\Lenovo\Lenovo Updates",
        "root\Lenovo\Lenovo_Updates",
        "root\Lenovo\drivers"
    )

    foreach ($namespace in $wmiNamespacesToTry) {
        try {
            $classes = Get-CimClass -Namespace $namespace -ErrorAction Stop |
                Where-Object {
                    $_.CimClassName -match "Update|Package|Driver|Lenovo"
                }

            foreach ($class in $classes) {
                try {
                    $items = Get-CimInstance -Namespace $namespace -ClassName $class.CimClassName -ErrorAction Stop
                }
                catch {
                    continue
                }

                foreach ($item in $items) {
                    $wmiItemsFound++

                    $props = $item.CimInstanceProperties |
                        Where-Object {
                            $_.Name -match "Package|Title|Name|Version|Severity|Status|Result|Applicable|Install"
                        } |
                        ForEach-Object {
                            "$($_.Name)=$($_.Value)"
                        }

                    $wmiLine = "$namespace\$($class.CimClassName): " + ($props -join "; ")

                    if ($wmiItems.Count -lt $MaxDetailLines) {
                        [void]$wmiItems.Add($wmiLine)
                    }
                }
            }
        }
        catch {
            continue
        }
    }

    $likelyNoApplicableUpdates = $false

    if ($taskListSummary.LikelyNoApplicableUpdates -and $installedCount -eq 0 -and $failedCount -eq 0) {
        $likelyNoApplicableUpdates = $true
    }

    return [pscustomobject]@{
        InstalledCount = $installedCount
        FailedCount = $failedCount
        SkippedCount = $skippedCount
        NotApplicableCount = $notApplicableCount
        RebootMentionCount = $rebootMentionCount
        RebootMetadataFound = ($rebootMentionCount -gt 0)
        DetailLines = $detailLines
        LogFilesReviewed = $logFilesReviewed
        WmiItemsFound = $wmiItemsFound
        WmiItems = $wmiItems
        RecentArtifactsFound = $recentArtifacts.Count
        InventoryFile = $inventoryFile

        KeyArtifactCopyDir = $keyArtifactCopy.CopyDir
        KeyArtifactsCopied = $keyArtifactCopy.CopiedFiles.Count
        KeyArtifactCopiedFiles = $keyArtifactCopy.CopiedFiles

        TaskListFound = $taskListSummary.Found
        TaskListPath = $taskListSummary.SourcePath
        TaskListSizeBytes = $taskListSummary.SizeBytes
        TaskListParseSucceeded = $taskListSummary.ParseSucceeded
        TaskListParseError = $taskListSummary.ParseError
        TaskListRootName = $taskListSummary.RootName
        TaskListChildElementCount = $taskListSummary.ChildElementCount
        TaskListTaskLikeElementCount = $taskListSummary.TaskLikeElementCount
        TaskListEmpty = $taskListSummary.Empty
        TaskListLikelyNoApplicableUpdates = $taskListSummary.LikelyNoApplicableUpdates
        TaskListSamples = $taskListSummary.Samples

        LikelyNoApplicableUpdates = $likelyNoApplicableUpdates
    }
}

# ============================================================
# Vendor tool detection and install helpers
# ============================================================

function Test-DotNetDesktopRuntime8Installed {
    $desktopRuntimePaths = @(
        "HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App",
        "HKLM:\SOFTWARE\WOW6432Node\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App"
    )

    foreach ($path in $desktopRuntimePaths) {
        if (Test-Path $path) {
            $versions = Get-ChildItem $path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName

            foreach ($version in $versions) {
                try {
                    $parsedVersion = [version]$version

                    if ($parsedVersion.Major -eq 8) {
                        Write-Log ".NET Desktop Runtime 8 detected in registry: $version"
                        return $true
                    }
                }
                catch {}
            }
        }
    }

    $dotnetSharedPaths = @(
        "C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App",
        "C:\Program Files (x86)\dotnet\shared\Microsoft.WindowsDesktop.App"
    )

    foreach ($sharedPath in $dotnetSharedPaths) {
        if (Test-Path -LiteralPath $sharedPath) {
            $runtimeFolders = Get-ChildItem -LiteralPath $sharedPath -Directory -ErrorAction SilentlyContinue

            foreach ($folder in $runtimeFolders) {
                try {
                    $parsedVersion = [version]$folder.Name

                    if ($parsedVersion.Major -eq 8) {
                        Write-Log ".NET Desktop Runtime 8 detected in shared runtime folder: $($folder.FullName)"
                        return $true
                    }
                }
                catch {}
            }
        }
    }

    $dotnetExeCandidates = @(
        "C:\Program Files\dotnet\dotnet.exe",
        "C:\Program Files (x86)\dotnet\dotnet.exe"
    )

    foreach ($dotnetExe in $dotnetExeCandidates) {
        if (Test-Path -LiteralPath $dotnetExe) {
            try {
                $output = & $dotnetExe --list-runtimes 2>$null

                if ($output -match "(?im)^Microsoft\.WindowsDesktop\.App\s+8\.") {
                    Write-Log ".NET Desktop Runtime 8 detected using dotnet --list-runtimes at $dotnetExe"
                    return $true
                }
            }
            catch {}
        }
    }

    return $false
}

function Install-DotNetDesktopRuntime8 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )

    if (Test-DotNetDesktopRuntime8Installed) {
        Write-Log ".NET Desktop Runtime 8 x64 is already installed."
        return $true
    }

    if (-not $InstallDotNetDesktopRuntimeIfMissing) {
        Write-Log ".NET Desktop Runtime 8 x64 is missing, and InstallDotNetDesktopRuntimeIfMissing is disabled." "WARN"
        return $false
    }

    $dotNetInstaller = Join-Path $DownloadFolder "windowsdesktop-runtime-8-win-x64.exe"
    $downloaded = Invoke-FileDownload -Uri $DotNetDesktopRuntime8Url -OutFile $dotNetInstaller

    if (-not $downloaded) {
        Write-Log "Failed to download .NET Desktop Runtime 8 x64 installer." "ERROR"
        $global:HadVendorFailure = $true
        return $false
    }

    Write-Log "Installing .NET Desktop Runtime 8 x64 silently."

    $runtimeResult = Invoke-LoggedProcess `
        -Name ".NET Desktop Runtime 8 Installer" `
        -FilePath $dotNetInstaller `
        -Arguments @("/install", "/quiet", "/norestart") `
        -SuccessExitCodes @(0, 1638) `
        -RebootExitCodes @(3010)

    if ($runtimeResult.Success) {
        Start-Sleep -Seconds 10

        if (Test-DotNetDesktopRuntime8Installed) {
            return $true
        }

        if ($AssumeDotNetDesktopRuntime8InstalledAfterSuccessfulInstaller) {
            Write-Log ".NET Desktop Runtime 8 installer reported success, but immediate detection failed. Continuing because fallback is enabled." "WARN"
            return $true
        }

        Write-Log ".NET Desktop Runtime 8 installer reported success, but runtime was not detected afterward." "WARN"
        return $false
    }

    return $false
}

function Get-FileSha256String {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        if (Test-Path -LiteralPath $Path) {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        }
    }
    catch {
        Write-Log "Could not calculate SHA256 for $Path`: $($_.Exception.Message)" "WARN"
    }

    return ""
}

function Test-DellCommandUpdateInstallerHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($DellCommandUpdateInstallerSha256)) {
        return $true
    }

    $actualHash = Get-FileSha256String -Path $Path

    if (-not $actualHash) {
        return $false
    }

    if ($actualHash -eq $DellCommandUpdateInstallerSha256.ToUpperInvariant()) {
        Write-Log "Dell Command Update installer SHA256 verified: $actualHash"
        return $true
    }

    Write-Log "Dell Command Update installer SHA256 mismatch. Expected=$DellCommandUpdateInstallerSha256 Actual=$actualHash" "WARN"
    return $false
}

function Get-DellDriverDetailsPageHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {
        Write-Log "Reading Dell driver details page: $Url"

        $headers = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36"
            "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
            "Accept-Language" = "en-US,en;q=0.9"
        }

        $response = Invoke-WebRequest `
            -Uri $Url `
            -UseBasicParsing `
            -Headers $headers `
            -MaximumRedirection 10 `
            -ErrorAction Stop

        if ($response -and $response.Content) {
            return [string]$response.Content
        }
    }
    catch {
        Write-Log "Could not read Dell driver details page $Url`: $($_.Exception.Message)" "WARN"
    }

    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        $html = $webClient.DownloadString($Url)
        $webClient.Dispose()

        if ($html) {
            return [string]$html
        }
    }
    catch {
        Write-Log "WebClient could not read Dell driver details page $Url`: $($_.Exception.Message)" "WARN"
    }

    return ""
}

function Get-DellCommandUpdateInstallerCandidateUrls {
    $candidateUrls = [System.Collections.ArrayList]::new()

    foreach ($detailsUrl in $DellCommandUpdateDriverDetailsUrls) {
        $html = Get-DellDriverDetailsPageHtml -Url $detailsUrl

        if (-not $html) {
            continue
        }

        $decodedHtml = $html

        try {
            $decodedHtml = [System.Net.WebUtility]::HtmlDecode($decodedHtml)
        }
        catch {}

        $decodedHtml = $decodedHtml -replace '\u002f', '/'
        $decodedHtml = $decodedHtml -replace '\/', '/'

        $patterns = @(
            'https?://(?:dl|downloads)\.dell\.com/[^"''<>\s]+\.EXE',
            'https?://(?:dl|downloads)\.dell\.com/[^"''<>\s]+\.exe',
            '/FOLDER[0-9A-Za-z_/.-]+\.EXE',
            '/FOLDER[0-9A-Za-z_/.-]+\.exe'
        )

        foreach ($pattern in $patterns) {
            $matches = [regex]::Matches($decodedHtml, $pattern)

            foreach ($match in $matches) {
                $url = [string]$match.Value

                if ($url -notmatch '^https?://') {
                    $url = "https://dl.dell.com" + $url
                }

                if ($url -match [regex]::Escape($DellCommandUpdateInstallerFileName)) {
                    if (-not ($candidateUrls -contains $url)) {
                        [void]$candidateUrls.Add($url)
                    }
                }
            }
        }
    }

    foreach ($url in $DellCommandUpdateKnownDirectUrls) {
        if (-not ($candidateUrls -contains $url)) {
            [void]$candidateUrls.Add($url)
        }
    }

    return @($candidateUrls)
}

function Get-DellCommandUpdateInstallerFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )

    New-Item -ItemType Directory -Path $DownloadFolder -Force | Out-Null

    $installerPath = Join-Path $DownloadFolder "Dell-Command-Update-Installer.exe"

    if (-not [string]::IsNullOrWhiteSpace($DellCommandUpdateInstallerLocalPath)) {
        if (Test-Path -LiteralPath $DellCommandUpdateInstallerLocalPath) {
            Write-Log "Using local Dell Command Update installer: $DellCommandUpdateInstallerLocalPath"
            Copy-Item -LiteralPath $DellCommandUpdateInstallerLocalPath -Destination $installerPath -Force

            if ((Test-Path -LiteralPath $installerPath) -and ((Get-Item -LiteralPath $installerPath).Length -gt 0)) {
                if (Test-DellCommandUpdateInstallerHash -Path $installerPath) {
                    return $installerPath
                }

                Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Log "Configured DellCommandUpdateInstallerLocalPath does not exist: $DellCommandUpdateInstallerLocalPath" "WARN"
        }
    }

    $candidateUrls = @(Get-DellCommandUpdateInstallerCandidateUrls)

    if ($candidateUrls.Count -eq 0) {
        Write-Log "No Dell Command Update installer candidate URLs were found." "WARN"
    }

    foreach ($url in $candidateUrls) {
        Write-Log "Trying Dell Command Update installer source: $url"

        $downloaded = Invoke-FileDownload -Uri $url -OutFile $installerPath

        if ($downloaded -and (Test-Path -LiteralPath $installerPath) -and ((Get-Item -LiteralPath $installerPath).Length -gt 0)) {
            if (Test-DellCommandUpdateInstallerHash -Path $installerPath) {
                Write-Log "Dell Command Update installer downloaded successfully from: $url"
                return $installerPath
            }

            Write-Log "Downloaded Dell Command Update installer failed hash validation. Deleting file and trying next source." "WARN"
            Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        }

        Write-Log "Dell Command Update installer source failed: $url" "WARN"
    }

    Write-Log "Unable to obtain Dell Command Update installer from Dell sources." "ERROR"
    return $null
}

function Find-ChocolateyExecutable {
    $choco = Get-Command choco.exe -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($choco -and $choco.Source) {
        return $choco.Source
    }

    $candidatePaths = @(
        "C:\ProgramData\chocolatey\bin\choco.exe",
        "C:\ProgramData\Chocolatey\bin\choco.exe"
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            return $candidatePath
        }
    }

    return $null
}


function Ensure-ChocolateyInstalled {
    $choco = Find-ChocolateyExecutable

    if ($choco) {
        Write-Log "Chocolatey detected: $choco"
        return $choco
    }

    Write-Log "Chocolatey was not found on this endpoint." "WARN"

    if (-not $InstallChocolateyIfMissing) {
        Write-Log "InstallChocolateyIfMissing is disabled. Chocolatey-dependent fallback cannot run." "WARN"
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($ChocolateyInstallScriptUrl)) {
        Write-Log "ChocolateyInstallScriptUrl is blank. Cannot install Chocolatey." "WARN"
        return $null
    }

    $chocoBootstrapDir = Join-Path $RunLogDir "ChocolateyBootstrap"
    New-Item -ItemType Directory -Path $chocoBootstrapDir -Force | Out-Null

    $installScript = Join-Path $chocoBootstrapDir "install-chocolatey.ps1"
    $downloaded = Invoke-FileDownload -Uri $ChocolateyInstallScriptUrl -OutFile $installScript

    if (-not $downloaded -or -not (Test-Path -LiteralPath $installScript)) {
        Write-Log "Could not download the Chocolatey install script." "ERROR"
        $global:HadVendorWarning = $true
        return $null
    }

    $powerShellPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

    if (-not (Test-Path -LiteralPath $powerShellPath)) {
        $powerShellCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($powerShellCommand -and $powerShellCommand.Source) {
            $powerShellPath = $powerShellCommand.Source
        }
    }

    if (-not (Test-Path -LiteralPath $powerShellPath)) {
        Write-Log "powershell.exe was not found. Cannot install Chocolatey." "ERROR"
        $global:HadVendorWarning = $true
        return $null
    }

    $oldTimeout = $script:VendorTimeoutMinutes
    $script:VendorTimeoutMinutes = $ChocolateyInstallTimeoutMinutes

    try {
        Write-Log "Installing Chocolatey because choco.exe is missing."

        $installResult = Invoke-LoggedProcess `
            -Name "Chocolatey Bootstrap Install" `
            -FilePath $powerShellPath `
            -Arguments @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $installScript) `
            -SuccessExitCodes @(0) `
            -RebootExitCodes @()

        if (-not $installResult.Success) {
            Write-Log "Chocolatey bootstrap install did not report success. ExitCode=$($installResult.ExitCode)" "WARN"
            $global:HadVendorWarning = $true
            return $null
        }
    }
    finally {
        $script:VendorTimeoutMinutes = $oldTimeout
    }

    if ($ChocolateyInstallPostInstallDelaySeconds -gt 0) {
        Start-Sleep -Seconds $ChocolateyInstallPostInstallDelaySeconds
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $processPathParts = @($env:Path, $machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $env:Path = ($processPathParts -join ";")

    $choco = Find-ChocolateyExecutable

    if ($choco) {
        Write-Log "Chocolatey installed successfully: $choco"
        return $choco
    }

    Write-Log "Chocolatey bootstrap reported success, but choco.exe was still not found." "WARN"
    $global:HadVendorWarning = $true
    return $null
}

function Test-LogContainsDellMsiSourceError {
    param(
        [string[]]$Paths
    )

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            continue
        }

        try {
            $patterns = @()

            foreach ($code in $DellCommandUpdateMsiSourceErrorCodes) {
                $patterns += "(?i)\b$code\b"
                $patterns += "(?i)error\s+$code"
            }

            $patterns += "(?i)older\s+version\s+.*cannot\s+be\s+removed"
            $patterns += "(?i)installation\s+source\s+.*not\s+available"
            $patterns += "(?i)network\s+resource\s+.*unavailable"

            foreach ($pattern in $patterns) {
                $match = Select-String -LiteralPath $path -Pattern $pattern -SimpleMatch:$false -ErrorAction SilentlyContinue | Select-Object -First 1

                if ($match) {
                    Write-Log "Detected Dell Command Update MSI source/removal error marker in $path`: $($match.Line.Trim())" "WARN"
                    return $true
                }
            }
        }
        catch {
            Write-Log "Could not inspect log file for Dell MSI source errors: $path. Error: $($_.Exception.Message)" "WARN"
        }
    }

    return $false
}

function ConvertTo-MsiPackedGuid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Guid
    )

    $clean = $Guid.Trim().Trim([char[]]"{}").ToUpperInvariant()

    if ($clean -notmatch "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$") {
        return ""
    }

    $parts = $clean.Split("-")

    function Reverse-StringLocal {
        param([string]$Value)
        $chars = $Value.ToCharArray()
        [array]::Reverse($chars)
        return (-join $chars)
    }

    function Reverse-PairsLocal {
        param([string]$Value)
        $result = New-Object System.Text.StringBuilder

        for ($i = 0; $i -lt $Value.Length; $i += 2) {
            if (($i + 1) -lt $Value.Length) {
                [void]$result.Append($Value[$i + 1])
                [void]$result.Append($Value[$i])
            }
            else {
                [void]$result.Append($Value[$i])
            }
        }

        return $result.ToString()
    }

    return ((Reverse-StringLocal $parts[0]) + (Reverse-StringLocal $parts[1]) + (Reverse-StringLocal $parts[2]) + (Reverse-PairsLocal $parts[3]) + (Reverse-PairsLocal $parts[4]))
}

function Export-RegistryKeyIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NativeKeyPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupFolder,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $safeLabel = $Label -replace "[^\w.-]", "_"
    $backupFile = Join-Path $BackupFolder "$safeLabel.reg"

    try {
        & reg.exe query $NativeKeyPath *> $null

        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        & reg.exe export $NativeKeyPath $backupFile /y *> $null

        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $backupFile)) {
            Write-Log "Backed up registry key $NativeKeyPath to $backupFile"
            return $true
        }

        Write-Log "Could not export registry key $NativeKeyPath before removal." "WARN"
        return $false
    }
    catch {
        Write-Log "Could not back up registry key $NativeKeyPath`: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Remove-RegistryKeyIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NativeKeyPath
    )

    $psPath = "Registry::$NativeKeyPath"

    try {
        if (Test-Path -LiteralPath $psPath) {
            Remove-Item -LiteralPath $psPath -Recurse -Force -ErrorAction Stop
            Write-Log "Removed registry key: $NativeKeyPath" "WARN"
            return $true
        }
    }
    catch {
        Write-Log "Could not remove registry key $NativeKeyPath`: $($_.Exception.Message)" "WARN"
    }

    return $false
}

function Invoke-DellCommandUpdateMsiSourceErrorCleanup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupFolder
    )

    if (-not $DellCommandUpdateEnableMsiSourceErrorRegistryCleanup) {
        Write-Log "Dell MSI source-error registry cleanup is disabled." "WARN"
        return $false
    }

    $apps = @(Get-DellCommandUpdateInstalledApp)

    if ($apps.Count -eq 0) {
        Write-Log "No Dell Command Update uninstall/MSI registry entries were found for MSI source-error cleanup." "WARN"
        return $false
    }

    New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null

    $removedAny = $false

    foreach ($app in $apps) {
        $guid = $null

        if ($app.RegistryKeyName -match "^\{[0-9A-Fa-f-]{36}\}$") {
            $guid = $app.RegistryKeyName.ToUpperInvariant()
        }
        elseif ($app.UninstallString -match "\{[0-9A-Fa-f-]{36}\}") {
            $guid = $Matches[0].ToUpperInvariant()
        }

        Write-Log "Evaluating Dell Command Update stale MSI registration cleanup candidate: $($app.DisplayName) $($app.DisplayVersion) [$($app.RegistryView)] ProductCode=$guid" "WARN"

        if (-not $guid) {
            Write-Log "Skipping stale MSI cleanup for $($app.DisplayName) because no MSI product code was found." "WARN"
            continue
        }

        $uninstallNativePath = $null

        if ($app.RegistryView -eq "Registry32") {
            $uninstallNativePath = "HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$($app.RegistryKeyName)"
        }
        else {
            $uninstallNativePath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($app.RegistryKeyName)"
        }

        [void](Export-RegistryKeyIfPresent -NativeKeyPath $uninstallNativePath -BackupFolder $BackupFolder -Label "Uninstall_$($app.RegistryView)_$guid")

        if (Remove-RegistryKeyIfPresent -NativeKeyPath $uninstallNativePath) {
            $removedAny = $true
        }

        $packedGuid = ConvertTo-MsiPackedGuid -Guid $guid

        if ($packedGuid) {
            $installerProductPaths = @(
                "HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Products\$packedGuid",
                "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$packedGuid"
            )

            foreach ($installerProductPath in $installerProductPaths) {
                [void](Export-RegistryKeyIfPresent -NativeKeyPath $installerProductPath -BackupFolder $BackupFolder -Label "InstallerProduct_$packedGuid")

                if (Remove-RegistryKeyIfPresent -NativeKeyPath $installerProductPath) {
                    $removedAny = $true
                }
            }
        }
    }

    if ($removedAny) {
        Write-Log "Dell Command Update stale MSI registration cleanup completed. Backups are in: $BackupFolder" "WARN"
        return $true
    }

    Write-Log "Dell Command Update stale MSI registration cleanup did not remove any keys." "WARN"
    return $false
}

function Install-DellCommandUpdateWithChocolatey {
    param(
        [string]$PackageId = $ChocolateyDellCommandUpdatePackageId,

        [switch]$Force
    )

    $isRepairMode = [bool]$Force
    $script:LastDellCommandUpdateChocolateyExitCode = $null
    $script:LastDellCommandUpdateChocolateyRequiresReboot = $false

    if ($isRepairMode) {
        if (-not $UseChocolateyFallbackForDellCommandUpdateRepair) {
            Write-Log "Chocolatey fallback for Dell Command Update repair is disabled."
            return $false
        }
    }
    else {
        if (-not $UseChocolateyFallbackForDellCommandUpdateInstall) {
            Write-Log "Chocolatey fallback for Dell Command Update install is disabled."
            return $false
        }
    }

    $choco = Ensure-ChocolateyInstalled

    if (-not $choco) {
        Write-Log "choco.exe is still unavailable. Cannot use Chocolatey fallback for Dell Command Update." "WARN"
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        Write-Log "Chocolatey Dell Command Update package id is blank. Cannot use Chocolatey fallback." "WARN"
        return $false
    }

    $args = @(
        "upgrade",
        $PackageId,
        "-y",
        "--no-progress",
        "--execution-timeout=7200"
    )

    if ($Force) {
        $args += "--force"
        Write-Log "Trying Chocolatey fallback for Dell Command Update repair using package id: $PackageId"
        Write-Log "Chocolatey repair fallback will run a forced upgrade/install without uninstalling existing DCU first."
    }
    else {
        Write-Log "Trying Chocolatey fallback for Dell Command Update install using package id: $PackageId"
    }

    $chocoResult = Invoke-LoggedProcess `
        -Name "Dell Command Update Chocolatey Install" `
        -FilePath $choco `
        -Arguments $args `
        -SuccessExitCodes @(0) `
        -RebootExitCodes @(3010, 1641) `
        -NonFatalUnexpectedExitCodes @(1, 2, 3, 4, 5, 6, 7, 8, 9)

    if ($chocoResult) {
        $script:LastDellCommandUpdateChocolateyExitCode = $chocoResult.ExitCode

        if ($chocoResult.Status -eq "RebootRequired") {
            $script:LastDellCommandUpdateChocolateyRequiresReboot = $true
        }
    }

    if ($chocoResult.Success) {
        Start-Sleep -Seconds 20

        $cli = Find-DellCommandUpdateCli

        if ($cli) {
            Write-Log "Dell Command Update installed or repaired by Chocolatey fallback. CLI path: $cli"
            return $true
        }

        Write-Log "Chocolatey reported success, but dcu-cli.exe was not found." "WARN"
        return $false
    }

    Write-Log "Chocolatey fallback did not install or repair Dell Command Update successfully." "WARN"
    return $false
}

function Install-DellCommandUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder,

        [string]$PreDownloadedInstallerPath = "",

        [bool]$AllowChocolateyFallback = $true
    )

    $script:LastDellCommandUpdateInstallerExitCode = $null
    $script:LastDellCommandUpdateInstallerLog = ""
    $script:LastDellCommandUpdateInstallerHadMsiSourceError = $false
    $script:LastDellCommandUpdateInstallerRequiresReboot = $false

    $dotNetReady = Install-DotNetDesktopRuntime8 -DownloadFolder $DownloadFolder

    if (-not $dotNetReady) {
        Write-Log "Dell Command Update install skipped because required .NET Desktop Runtime 8 x64 is not available." "WARN"
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($PreDownloadedInstallerPath) -and (Test-Path -LiteralPath $PreDownloadedInstallerPath)) {
        $dcuInstaller = $PreDownloadedInstallerPath
        Write-Log "Using pre-downloaded Dell Command Update installer: $dcuInstaller"
    }
    else {
        $dcuInstaller = Get-DellCommandUpdateInstallerFile -DownloadFolder $DownloadFolder
    }

    if ($dcuInstaller -and (Test-Path -LiteralPath $dcuInstaller)) {
        $dcuInstallLog = Join-Path $DownloadFolder "Dell-Command-Update-Install.log"
        $script:LastDellCommandUpdateInstallerLog = $dcuInstallLog

        Write-Log "Installing Dell Command Update silently."

        $dcuInstallResult = Invoke-LoggedProcess `
            -Name "Dell Command Update Installer" `
            -FilePath $dcuInstaller `
            -Arguments @("/s", "/l=$dcuInstallLog") `
            -SuccessExitCodes @(0) `
            -RebootExitCodes @(2, 3010)

        if ($dcuInstallResult) {
            $script:LastDellCommandUpdateInstallerExitCode = $dcuInstallResult.ExitCode

            if ($dcuInstallResult.Status -eq "RebootRequired") {
                $script:LastDellCommandUpdateInstallerRequiresReboot = $true
            }
        }

        if ($dcuInstallResult.Success) {
            Start-Sleep -Seconds 20
            return $true
        }

        $script:LastDellCommandUpdateInstallerHadMsiSourceError = Test-LogContainsDellMsiSourceError -Paths @($dcuInstallLog)

        if ($script:LastDellCommandUpdateInstallerHadMsiSourceError) {
            Write-Log "Dell Command Update installer appears to have hit MSI 1612/1714-style source/removal errors." "WARN"
        }

        Write-Log "Dell Command Update installer ran but did not report success." "WARN"
    }
    else {
        Write-Log "Dell Command Update installer could not be downloaded from Dell sources." "WARN"
    }

    if ($AllowChocolateyFallback) {
        return (Install-DellCommandUpdateWithChocolatey)
    }

    Write-Log "Dell Command Update install cannot continue without a downloaded installer or the installer did not succeed." "ERROR"
    $global:HadVendorFailure = $true
    return $false
}

function Find-DellCommandUpdateCli {
    $pf64 = Get-ProgramFiles64
    $pf86 = Get-ProgramFilesX86

    $paths = @(
        "$pf64\Dell\CommandUpdate\dcu-cli.exe"
    )

    if ($pf86) {
        $paths += "$pf86\Dell\CommandUpdate\dcu-cli.exe"
    }

    return Get-FirstExistingPath -Paths $paths
}

function Find-LenovoSystemUpdateCli {
    $pf64 = Get-ProgramFiles64
    $pf86 = Get-ProgramFilesX86

    $paths = @(
        "$pf64\Lenovo\System Update\Tvsu.exe"
    )

    if ($pf86) {
        $paths += "$pf86\Lenovo\System Update\Tvsu.exe"
    }

    return Get-FirstExistingPath -Paths $paths
}

function Install-LenovoSystemUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )

    $lenovoInstaller = Join-Path $DownloadFolder "Lenovo-System-Update-Installer.exe"
    $lenovoInstallLog = Join-Path $DownloadFolder "Lenovo-System-Update-Install.log"

    Write-Log "Downloading Lenovo System Update installer."
    Write-Log "Lenovo System Update installer URL: $LenovoSystemUpdateInstallerUrl"

    $downloaded = Invoke-FileDownload -Uri $LenovoSystemUpdateInstallerUrl -OutFile $lenovoInstaller

    if (-not $downloaded) {
        Write-Log "Failed to download Lenovo System Update installer." "ERROR"
        $global:HadVendorFailure = $true
        return $false
    }

    Write-Log "Installing Lenovo System Update silently."

    $lenovoInstallResult = Invoke-LoggedProcess `
        -Name "Lenovo System Update Installer" `
        -FilePath $lenovoInstaller `
        -Arguments @("/SP-", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/LOG=$lenovoInstallLog") `
        -SuccessExitCodes @(0) `
        -RebootExitCodes @(3010) `
        -WarningExitCodes @(1, 2)

    if ($lenovoInstallResult.Success) {
        Start-Sleep -Seconds 20
        Set-LenovoSystemUpdateSettings -EnableDebug $EnableLenovoDebugLogging
        return $true
    }

    Write-Log "Lenovo System Update installer did not complete successfully." "WARN"
    return $false
}

function Find-HPImageAssistant {
    $pf64 = Get-ProgramFiles64
    $pf86 = Get-ProgramFilesX86

    $knownPaths = @(
        "$HPImageAssistantInstallDir\HPImageAssistant.exe",
        "$pf64\HP\HP Image Assistant\HPImageAssistant.exe",
        "$pf64\HPIA\HPImageAssistant.exe",
        "C:\SWSetup\HPImageAssistant.exe"
    )

    if ($pf86) {
        $knownPaths += "$pf86\HP\HP Image Assistant\HPImageAssistant.exe"
        $knownPaths += "$pf86\HPIA\HPImageAssistant.exe"
    }

    $known = Get-FirstExistingPath -Paths $knownPaths

    if ($known) {
        return $known
    }

    $searchRoots = @(
        $HPImageAssistantInstallDir,
        "C:\SWSetup"
    )

    foreach ($root in $searchRoots) {
        if (Test-Path -LiteralPath $root) {
            $found = Get-ChildItem -Path $root -Filter "HPImageAssistant.exe" -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($found) {
                return $found.FullName
            }
        }
    }

    return $null
}

function Install-HPImageAssistant {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )

    $hpiaInstaller = Join-Path $DownloadFolder "HP-Image-Assistant-Installer.exe"
    $hpiaExtractDir = $HPImageAssistantInstallDir

    Write-Log "Downloading HP Image Assistant installer."
    Write-Log "HP Image Assistant installer URL: $HPImageAssistantInstallerUrl"

    $downloaded = Invoke-FileDownload -Uri $HPImageAssistantInstallerUrl -OutFile $hpiaInstaller

    if (-not $downloaded) {
        Write-Log "Failed to download HP Image Assistant installer." "ERROR"
        $global:HadVendorFailure = $true
        return $false
    }

    New-Item -ItemType Directory -Path $hpiaExtractDir -Force | Out-Null

    Write-Log "Extracting HP Image Assistant silently to $hpiaExtractDir"

    $hpiaInstallResult = Invoke-LoggedProcess `
        -Name "HP Image Assistant Installer" `
        -FilePath $hpiaInstaller `
        -Arguments @("/s", "/e", "/f$hpiaExtractDir") `
        -SuccessExitCodes @(0, 1168) `
        -RebootExitCodes @(3010)

    if ($hpiaInstallResult.Success) {
        Start-Sleep -Seconds 10

        $hpia = Find-HPImageAssistant

        if ($hpia) {
            Write-Log "HP Image Assistant extracted successfully: $hpia"
            return $true
        }

        Write-Log "HP Image Assistant installer completed, but HPImageAssistant.exe was not found after extraction." "WARN"
        return $false
    }

    Write-Log "HP Image Assistant installer did not complete successfully." "WARN"
    return $false
}

# ============================================================
# Main
# ============================================================

$mutexName = "Global\OEMUpdateRunner"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$hasMutex = $false

try {
    $hasMutex = $mutex.WaitOne(0)

    if (-not $hasMutex) {
        Write-Output "OEMUPDATER_RESULT=AlreadyRunning"
        Write-Output "OEMUPDATER_LOG=$MainLog"
        exit 0
    }

    if (-not (Test-IsAdmin)) {
        throw "This script must run elevated. In ConnectWise RMM, run it as System or Admin."
    }

    Write-Log "Starting OEM update detection."
    Write-Log "PowerShell version: $($PSVersionTable.PSVersion)"
    Write-Log "64-bit OS: $([Environment]::Is64BitOperatingSystem)"
    Write-Log "64-bit PowerShell process: $([Environment]::Is64BitProcess)"
    Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "Log folder: $RunLogDir"

    Write-Log "Shared reboot policy: InstallRebootRequiredUpdatesNoAutoReboot=$InstallRebootRequiredUpdatesNoAutoReboot"
    Write-Log "Shared reboot policy: IncludeBiosFirmwareUpdates=$IncludeBiosFirmwareUpdates"

    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS

    Write-Log "Manufacturer: $($system.Manufacturer)"
    Write-Log "Model: $($system.Model)"
    Write-Log "BIOS: $($bios.SMBIOSBIOSVersion)"

    $installedApps = Get-InstalledAppNames
    $results = @()

    if ($SkipDellCommandUpdateWhenWindowsPendingReboot) {
        $global:WindowsPendingRebootDetected = Test-PendingReboot

        if ($global:WindowsPendingRebootDetected) {
            Write-Log "SkipDellCommandUpdateWhenWindowsPendingReboot is enabled. Dell Command Update install/apply will be skipped to avoid adding more staged work before the reboot is cleared." "WARN"
            $global:RebootRequired = $true
            $global:HadVendorWarning = $true
            $global:DellStopFurtherApplyAttempts = $true
        }
    }

    # -----------------------------
    # Dell Command Update
    # -----------------------------
    $dellCli = Find-DellCommandUpdateCli

    if (-not $global:DellStopFurtherApplyAttempts -and -not $dellCli -and $system.Manufacturer -match "Dell" -and $InstallDellCommandUpdateIfMissing) {
        Write-Log "Dell system detected, but dcu-cli.exe was not found. InstallDellCommandUpdateIfMissing is enabled."

        $bootstrapDir = Join-Path $RunLogDir "Bootstrap"
        New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null

        $installedDcu = Install-DellCommandUpdate -DownloadFolder $bootstrapDir

        if ($installedDcu) {
            $global:DellToolBootstrapped = $true
            $dellCli = Find-DellCommandUpdateCli

            if ($script:LastDellCommandUpdateInstallerRequiresReboot -or $script:LastDellCommandUpdateChocolateyRequiresReboot) {
                Write-Log "Dell Command Update was installed, but the installer reported reboot required. Deferring Dell apply until after reboot." "WARN"
                $global:RebootRequired = $true
                $global:DellStopFurtherApplyAttempts = $true
            }
        }
    }

    if ($global:DellStopFurtherApplyAttempts -and $system.Manufacturer -match "Dell" -and -not $dellCli) {
        Write-Log "Dell system detected, but Dell Command Update was not installed or run because DellStopFurtherApplyAttempts=True. This is expected when a pending reboot was detected." "WARN"
        $global:SupportedToolFound = $true
    }

    if ($dellCli) {
        $global:SupportedToolFound = $true
        $global:DellToolFound = $true
        $script:DellClientManagementServiceRestartedThisRun = $false

        $dellNativeLogDir = "C:\ProgramData\Dell\OEMUpdateRunner\$RunStamp"
        New-Item -ItemType Directory -Path $dellNativeLogDir -Force | Out-Null

        if ($IncludeBiosFirmwareUpdates) {
            $dellUpdateTypes = @("bios", "firmware", "driver", "application")
            Write-Log "Dell BIOS/Firmware updates are included. The script still passes -reboot=disable, but firmware/BIOS behavior is higher risk." "WARN"
        }
        else {
            $dellUpdateTypes = @("driver", "application")
            Write-Log "Dell BIOS and firmware are excluded. Dell driver/application updates may still require reboot, and -reboot=disable is used."
        }

        $dellAny107 = $false
        $dellAllFilteredAttempts107 = $true

        foreach ($dellUpdateType in $dellUpdateTypes) {
            if ($global:DellStopFurtherApplyAttempts) {
                Write-Log "Skipping remaining Dell update types because DellStopFurtherApplyAttempts=True." "WARN"
                break
            }

            $dellApplyLog = Join-Path $dellNativeLogDir "Dell-Apply-$dellUpdateType.log"

            Write-Log "Running Dell apply step for update type: $dellUpdateType"
            Write-Log "Dell auto-reboot suppression is enabled with -reboot=disable."

            $global:DellApplyRan = $true

            $dellApplyResult = Invoke-DellCommandUpdateApplyWithServiceRecovery `
                -DellCli $dellCli `
                -UpdateType $dellUpdateType `
                -OutputLog $dellApplyLog

            if ($null -ne $dellApplyResult -and $dellApplyResult.PSObject.Properties.Name -contains "Tool") {
                $results += $dellApplyResult

                if ($dellApplyResult.ExitCode -eq 107) {
                    $dellAny107 = $true
                    Write-Log "Dell rejected the update type value '$dellUpdateType' with exit code 107." "WARN"
                }
                else {
                    $dellAllFilteredAttempts107 = $false
                }
            }
            else {
                $dellAllFilteredAttempts107 = $false
            }

            Write-Log "Dell Command Update log should be here: $dellApplyLog"
        }

        if ($dellAny107 -and $dellAllFilteredAttempts107 -and -not $global:DellStopFurtherApplyAttempts) {
            Write-Log "All Dell filtered update type attempts returned exit code 107." "WARN"

            if ($AllowDellNoUpdateTypeFallback) {
                $dellFallbackLog = Join-Path $dellNativeLogDir "Dell-Apply-Unfiltered.log"

                Write-Log "AllowDellNoUpdateTypeFallback is enabled. Running Dell apply without -updateType." "WARN"
                Write-Log "This may include BIOS and firmware updates. The script still passes -reboot=disable." "WARN"

                $global:DellApplyRan = $true

                $dellFallbackResult = Invoke-DellCommandUpdateApplyWithServiceRecovery `
                    -DellCli $dellCli `
                    -OutputLog $dellFallbackLog `
                    -Unfiltered

                if ($null -ne $dellFallbackResult -and $dellFallbackResult.PSObject.Properties.Name -contains "Tool") {
                    $results += $dellFallbackResult
                }

                Write-Log "Dell Command Update unfiltered fallback log should be here: $dellFallbackLog"
            }
            else {
                Write-Log "AllowDellNoUpdateTypeFallback is disabled. Not running Dell unfiltered apply because it may include BIOS or firmware." "WARN"
            }
        }
    }
    elseif (($system.Manufacturer -match "Dell") -or ($installedApps -match "Dell Command|Dell Update|Dell Command Update")) {
        Write-Log "Dell system or software detected, but dcu-cli.exe was not found. Skipping Dell updates." "WARN"
    }

    # -----------------------------
    # Lenovo System Update / TVSU
    # -----------------------------
    $lenovoTvsu = Find-LenovoSystemUpdateCli

    if (-not $lenovoTvsu -and $system.Manufacturer -match "Lenovo" -and $InstallLenovoSystemUpdateIfMissing) {
        Write-Log "Lenovo system detected, but Tvsu.exe was not found. InstallLenovoSystemUpdateIfMissing is enabled."

        $bootstrapDir = Join-Path $RunLogDir "Bootstrap"
        New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null

        $installedLenovoSystemUpdate = Install-LenovoSystemUpdate -DownloadFolder $bootstrapDir

        if ($installedLenovoSystemUpdate) {
            $global:LenovoToolBootstrapped = $true
            $lenovoTvsu = Find-LenovoSystemUpdateCli
        }
    }

    if ($lenovoTvsu) {
        $global:SupportedToolFound = $true
        $global:LenovoToolFound = $true

        Set-LenovoSystemUpdateSettings -EnableDebug $EnableLenovoDebugLogging

        $lenovoArgs = @("/CM", "-search", $LenovoSearchMode, "-action", "INSTALL", "-noicon", "-nolicense", "-exporttowmi")

        if ($InstallRebootRequiredUpdatesNoAutoReboot) {
            $lenovoArgs += @("-includerebootpackages", $LenovoRebootPackageTypes, "-noreboot")

            Write-Log "Lenovo reboot-required packages are included for reboot type(s): $LenovoRebootPackageTypes"
            Write-Log "Lenovo -noreboot is enabled. Reboot type 3 is the recommended no-auto-reboot target." "WARN"

            if ($LenovoRebootPackageTypes -ne "3") {
                Write-Log "LenovoRebootPackageTypes is not exactly '3'. Including other Lenovo reboot types may carry higher vendor-controlled reboot/shutdown risk." "WARN"
            }
        }
        else {
            Write-Log "Lenovo reboot-required packages are excluded."
        }

        if ($IncludeBiosFirmwareUpdates) {
            Write-Log "IncludeBiosFirmwareUpdates is enabled, but Lenovo BIOS/firmware inclusion is controlled by Lenovo package type and reboot package selection. Review Lenovo results carefully." "WARN"
        }
        else {
            Write-Log "Lenovo BIOS/firmware are not explicitly targeted. Reboot package type 3 may still include some non-BIOS packages requiring reboot."
        }

        Write-Log "Running Lenovo System Update install step."

        $global:LenovoApplyRan = $true
        $lenovoRunStart = Get-Date

        $lenovoResult = Invoke-LoggedProcess `
            -Name "Lenovo System Update Apply" `
            -FilePath $lenovoTvsu `
            -Arguments $lenovoArgs `
            -SuccessExitCodes @(0) `
            -RebootExitCodes @(3010) `
            -WarningExitCodes @(1)

        if ($null -ne $lenovoResult -and $lenovoResult.PSObject.Properties.Name -contains "Tool") {
            $results += $lenovoResult
        }

        Wait-ForProcessNames `
            -Label "Lenovo System Update" `
            -ProcessNames @("tvsu", "tvsukernel", "tvsucommandlauncher", "tvsuscheduler") `
            -TimeoutMinutes $LenovoPostProcessWaitMinutes

        $lenovoHistory = Get-LenovoUpdateHistorySummary `
            -RunStartTime $lenovoRunStart `
            -MaxDetailLines $LenovoArtifactParseMaxDetailLines

        $global:LenovoLikelyNoApplicableUpdates = [bool]$lenovoHistory.LikelyNoApplicableUpdates
        $global:LenovoRebootMetadataFound = [bool]$lenovoHistory.RebootMetadataFound

        Write-Log "Lenovo recent artifacts found: $($lenovoHistory.RecentArtifactsFound)"
        Write-Log "Lenovo artifact inventory file: $($lenovoHistory.InventoryFile)"
        Write-Log "Lenovo key artifact copy folder: $($lenovoHistory.KeyArtifactCopyDir)"
        Write-Log "Lenovo key artifacts copied: $($lenovoHistory.KeyArtifactsCopied)"

        foreach ($copiedFile in $lenovoHistory.KeyArtifactCopiedFiles) {
            Write-Log "Lenovo copied artifact: $copiedFile"
        }

        Write-Log "Lenovo UpdateTaskList found: $($lenovoHistory.TaskListFound)"
        Write-Log "Lenovo UpdateTaskList path: $($lenovoHistory.TaskListPath)"
        Write-Log "Lenovo UpdateTaskList size bytes: $($lenovoHistory.TaskListSizeBytes)"
        Write-Log "Lenovo UpdateTaskList parse succeeded: $($lenovoHistory.TaskListParseSucceeded)"
        Write-Log "Lenovo UpdateTaskList root name: $($lenovoHistory.TaskListRootName)"
        Write-Log "Lenovo UpdateTaskList child elements: $($lenovoHistory.TaskListChildElementCount)"
        Write-Log "Lenovo UpdateTaskList task-like elements: $($lenovoHistory.TaskListTaskLikeElementCount)"
        Write-Log "Lenovo UpdateTaskList empty: $($lenovoHistory.TaskListEmpty)"
        Write-Log "Lenovo likely no applicable updates in requested scope: $($lenovoHistory.LikelyNoApplicableUpdates)"

        if ($lenovoHistory.TaskListParseError) {
            Write-Log "Lenovo UpdateTaskList parse error: $($lenovoHistory.TaskListParseError)" "WARN"
        }

        foreach ($sample in $lenovoHistory.TaskListSamples) {
            Write-Log "Lenovo UpdateTaskList sample: $sample"
        }

        Write-Log "Lenovo history logs reviewed: $($lenovoHistory.LogFilesReviewed.Count)"
        Write-Log "Lenovo WMI update items found: $($lenovoHistory.WmiItemsFound)"
        Write-Log "Lenovo parsed installed count: $($lenovoHistory.InstalledCount)"
        Write-Log "Lenovo parsed failed count: $($lenovoHistory.FailedCount)"
        Write-Log "Lenovo parsed skipped count: $($lenovoHistory.SkippedCount)"
        Write-Log "Lenovo parsed not-applicable/no-updates count: $($lenovoHistory.NotApplicableCount)"
        Write-Log "Lenovo parsed reboot mentions: $($lenovoHistory.RebootMentionCount)"

        foreach ($detailLine in $lenovoHistory.DetailLines) {
            Write-Log "Lenovo detail: $detailLine"
        }

        foreach ($wmiLine in $lenovoHistory.WmiItems) {
            Write-Log "Lenovo WMI: $wmiLine"
        }

        if ($lenovoHistory.FailedCount -gt 0) {
            $global:HadVendorWarning = $true
            Write-Log "Lenovo history parser found likely Lenovo update failure lines. Review Lenovo detail lines and TVSU logs." "WARN"
        }

        if ($lenovoHistory.RebootMentionCount -gt 0) {
            if ((-not $lenovoHistory.TaskListEmpty) -or $lenovoHistory.InstalledCount -gt 0) {
                $global:RebootRequired = $true
                Write-Log "Lenovo history parser found reboot/restart mentions tied to non-empty task list or installed updates. The script did not restart the endpoint." "WARN"
            }
            else {
                Write-Log "Lenovo reboot/restart metadata was found, but UpdateTaskList is empty and no installs were parsed. Not marking endpoint as reboot-required from this run." "WARN"
            }
        }

        if ($lenovoHistory.LikelyNoApplicableUpdates -and $lenovoResult.ExitCode -eq 1) {
            Write-Log "Lenovo returned exit code 1, but UpdateTaskList appears container-only or empty and no Lenovo package failures were parsed. This likely means no applicable selected updates in the requested scope." "WARN"
        }
    }
    elseif (($system.Manufacturer -match "Lenovo") -or ($installedApps -match "Lenovo Vantage|Commercial Vantage|LenovoCommercialVantage|Lenovo System Update")) {
        Write-Log "Lenovo system or software detected, but Lenovo System Update CLI Tvsu.exe was not found. Skipping Lenovo updates. Lenovo Vantage GUI is intentionally not launched from RMM." "WARN"
    }

    # -----------------------------
    # HP Image Assistant
    # -----------------------------
    $hpia = Find-HPImageAssistant

    if (-not $hpia -and (($system.Manufacturer -match "HP|Hewlett|Hewlett-Packard") -or ($system.Model -match "HP")) -and $InstallHPImageAssistantIfMissing) {
        Write-Log "HP system detected, but HPImageAssistant.exe was not found. InstallHPImageAssistantIfMissing is enabled."

        $bootstrapDir = Join-Path $RunLogDir "Bootstrap"
        New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null

        $installedHPIA = Install-HPImageAssistant -DownloadFolder $bootstrapDir

        if ($installedHPIA) {
            $global:HPToolBootstrapped = $true
            $hpia = Find-HPImageAssistant
        }
    }

    if ($hpia) {
        $global:SupportedToolFound = $true
        $global:HPToolFound = $true

        $hpReportDir = Join-Path $RunLogDir "HP-Report"
        $hpDownloadDir = Join-Path $RunLogDir "HP-SoftPaqs"
        New-Item -ItemType Directory -Path $hpReportDir, $hpDownloadDir -Force | Out-Null

        if ($HPCategoryMode -eq "All") {
            $hpCategories = @("All")
            Write-Log "HP category mode is All. BIOS or firmware may be included and may require restart." "WARN"
        }
        else {
            $hpCategories = @("Drivers", "Software")

            if ($IncludeBiosFirmwareUpdates) {
                $hpCategories += @("Firmware", "BIOS")
                Write-Log "HP BIOS/Firmware categories are included. This is higher risk and may stage firmware/BIOS requiring reboot." "WARN"
            }
            else {
                Write-Log "HP categories are Drivers and Software. BIOS and firmware are excluded."
            }
        }

        foreach ($hpCategory in $hpCategories) {
            Write-Log "Running HP Image Assistant install step for category: $hpCategory"
            Write-Log "HP Image Assistant may return 3010 when a reboot is required. The script will not restart the endpoint."

            $global:HPApplyRan = $true

            $categoryReportDir = Join-Path $hpReportDir $hpCategory
            $categoryDownloadDir = Join-Path $hpDownloadDir $hpCategory

            New-Item -ItemType Directory -Path $categoryReportDir, $categoryDownloadDir -Force | Out-Null

            $hpResult = Invoke-LoggedProcess `
                -Name "HP Image Assistant Apply $hpCategory" `
                -FilePath $hpia `
                -Arguments @(
                    "/Operation:Analyze",
                    "/Category:$hpCategory",
                    "/Selection:All",
                    "/Action:Install",
                    "/Silent",
                    "/Noninteractive",
                    "/AutoCleanup",
                    "/ReportFolder:$categoryReportDir",
                    "/SoftPaqDownloadFolder:$categoryDownloadDir"
                ) `
                -SuccessExitCodes @(0, 256, 257) `
                -RebootExitCodes @(3010, 3011, 3020) `
                -WarningExitCodes @(4096, 4104)

            if ($null -ne $hpResult -and $hpResult.PSObject.Properties.Name -contains "Tool") {
                $results += $hpResult
            }
        }

        Write-Log "HP Image Assistant report folder should be here: $hpReportDir"
    }
    elseif (($system.Manufacturer -match "HP|Hewlett|Hewlett-Packard") -or ($installedApps -match "HP Image Assistant|HP Support Assistant")) {
        Write-Log "HP system or software detected, but HPImageAssistant.exe was not found. Skipping HP updates. HP Support Assistant GUI is intentionally not launched from RMM." "WARN"
    }

    # -----------------------------
    # Unsupported consumer OEM tools
    # -----------------------------
    $unsupportedHints = @(
        @{ Brand = "ASUS"; Pattern = "MyASUS|ASUS Live Update|ASUS System Control" },
        @{ Brand = "Acer"; Pattern = "Acer Care Center|Acer Update" },
        @{ Brand = "MSI"; Pattern = "MSI Center|Dragon Center" },
        @{ Brand = "Microsoft Surface"; Pattern = "Surface" }
    )

    foreach ($hint in $unsupportedHints) {
        if (($system.Manufacturer -match $hint.Brand) -or ($installedApps -match $hint.Pattern)) {
            Write-Log "$($hint.Brand) detected, but no reliable vendor silent CLI is configured in this script. Skipping." "WARN"
        }
    }

    if (-not $global:SupportedToolFound) {
        Write-Log "No supported OEM CLI tools were found." "WARN"
    }

    Write-Log "Summary:"

    foreach ($result in $results) {
        if ($null -ne $result -and $result.PSObject.Properties.Name -contains "Tool") {
            Write-Log "$($result.Tool) | Ran=$($result.Ran) | Success=$($result.Success) | Status=$($result.Status) | ExitCode=$($result.ExitCode)"
        }
    }

    Write-Log "Dell tool found: $global:DellToolFound"
    Write-Log "Dell tool bootstrapped: $global:DellToolBootstrapped"
    Write-Log "Dell apply ran: $global:DellApplyRan"
    Write-Log "Dell Client Management Service recovered/restarted: $global:DellClientManagementServiceRecovered"
    Write-Log "Dell Command Update repair attempted: $global:DellCommandUpdateRepairAttempted"
    Write-Log "Dell Command Update repair succeeded: $global:DellCommandUpdateRepairSucceeded"
    Write-Log "Dell Command Update repair requires reboot: $global:DellCommandUpdateRepairRequiresReboot"
    Write-Log "Dell service-busy deferral: $global:DellServiceBusyDeferral"
    Write-Log "Windows pending reboot detected: $global:WindowsPendingRebootDetected"
    Write-Log "Dell stop further apply attempts: $global:DellStopFurtherApplyAttempts"

    Write-Log "Lenovo tool found: $global:LenovoToolFound"
    Write-Log "Lenovo tool bootstrapped: $global:LenovoToolBootstrapped"
    Write-Log "Lenovo apply ran: $global:LenovoApplyRan"
    Write-Log "Lenovo likely no applicable updates in requested scope: $global:LenovoLikelyNoApplicableUpdates"
    Write-Log "Lenovo reboot metadata found: $global:LenovoRebootMetadataFound"

    Write-Log "HP tool found: $global:HPToolFound"
    Write-Log "HP tool bootstrapped: $global:HPToolBootstrapped"
    Write-Log "HP apply ran: $global:HPApplyRan"

    if ($lenovoHistory) {
        Write-Log "Lenovo summary recent artifacts found: $($lenovoHistory.RecentArtifactsFound)"
        Write-Log "Lenovo summary artifact inventory file: $($lenovoHistory.InventoryFile)"
        Write-Log "Lenovo summary key artifacts copied: $($lenovoHistory.KeyArtifactsCopied)"
        Write-Log "Lenovo summary key artifact copy folder: $($lenovoHistory.KeyArtifactCopyDir)"
        Write-Log "Lenovo summary UpdateTaskList found: $($lenovoHistory.TaskListFound)"
        Write-Log "Lenovo summary UpdateTaskList empty: $($lenovoHistory.TaskListEmpty)"
        Write-Log "Lenovo summary likely no applicable updates: $($lenovoHistory.LikelyNoApplicableUpdates)"
        Write-Log "Lenovo summary installed count: $($lenovoHistory.InstalledCount)"
        Write-Log "Lenovo summary failed count: $($lenovoHistory.FailedCount)"
        Write-Log "Lenovo summary skipped count: $($lenovoHistory.SkippedCount)"
        Write-Log "Lenovo summary not-applicable/no-updates count: $($lenovoHistory.NotApplicableCount)"
        Write-Log "Lenovo summary reboot mentions: $($lenovoHistory.RebootMentionCount)"
    }

    Write-Log "Reboot required reported by vendor tool or parsed logs: $global:RebootRequired"
    Write-Log "Vendor warning detected: $global:HadVendorWarning"
    Write-Log "Vendor failure detected: $global:HadVendorFailure"
    Write-Log "OEM update run complete."

    Write-Output "OEMUPDATER_RESULT=Complete"
    Write-Output "OEMUPDATER_SUPPORTED_TOOL_FOUND=$global:SupportedToolFound"

    Write-Output "OEMUPDATER_INSTALL_REBOOT_REQUIRED_UPDATES_NO_AUTO_REBOOT=$InstallRebootRequiredUpdatesNoAutoReboot"
    Write-Output "OEMUPDATER_INCLUDE_BIOS_FIRMWARE_UPDATES=$IncludeBiosFirmwareUpdates"

    Write-Output "OEMUPDATER_DELL_TOOL_FOUND=$global:DellToolFound"
    Write-Output "OEMUPDATER_DELL_TOOL_BOOTSTRAPPED=$global:DellToolBootstrapped"
    Write-Output "OEMUPDATER_DELL_APPLY_RAN=$global:DellApplyRan"
    Write-Output "OEMUPDATER_DELL_CLIENT_MANAGEMENT_SERVICE_RECOVERED=$global:DellClientManagementServiceRecovered"
    Write-Output "OEMUPDATER_DELL_COMMAND_UPDATE_REPAIR_ATTEMPTED=$global:DellCommandUpdateRepairAttempted"
    Write-Output "OEMUPDATER_DELL_COMMAND_UPDATE_REPAIR_SUCCEEDED=$global:DellCommandUpdateRepairSucceeded"
    Write-Output "OEMUPDATER_DELL_COMMAND_UPDATE_REPAIR_REQUIRES_REBOOT=$global:DellCommandUpdateRepairRequiresReboot"
    Write-Output "OEMUPDATER_DELL_SERVICE_BUSY_DEFERRAL=$global:DellServiceBusyDeferral"
    Write-Output "OEMUPDATER_WINDOWS_PENDING_REBOOT_DETECTED=$global:WindowsPendingRebootDetected"
    Write-Output "OEMUPDATER_DELL_STOP_FURTHER_APPLY_ATTEMPTS=$global:DellStopFurtherApplyAttempts"

    Write-Output "OEMUPDATER_LENOVO_TOOL_FOUND=$global:LenovoToolFound"
    Write-Output "OEMUPDATER_LENOVO_TOOL_BOOTSTRAPPED=$global:LenovoToolBootstrapped"
    Write-Output "OEMUPDATER_LENOVO_APPLY_RAN=$global:LenovoApplyRan"
    Write-Output "OEMUPDATER_LENOVO_LIKELY_NO_APPLICABLE_UPDATES=$global:LenovoLikelyNoApplicableUpdates"
    Write-Output "OEMUPDATER_LENOVO_REBOOT_METADATA_FOUND=$global:LenovoRebootMetadataFound"

    Write-Output "OEMUPDATER_HP_TOOL_FOUND=$global:HPToolFound"
    Write-Output "OEMUPDATER_HP_TOOL_BOOTSTRAPPED=$global:HPToolBootstrapped"
    Write-Output "OEMUPDATER_HP_APPLY_RAN=$global:HPApplyRan"

    Write-Output "OEMUPDATER_REBOOT_REQUIRED=$global:RebootRequired"
    Write-Output "OEMUPDATER_VENDOR_WARNING=$global:HadVendorWarning"
    Write-Output "OEMUPDATER_VENDOR_FAILURE=$global:HadVendorFailure"

    if ($lenovoHistory) {
        Write-Output "OEMUPDATER_LENOVO_RECENT_ARTIFACTS_FOUND=$($lenovoHistory.RecentArtifactsFound)"
        Write-Output "OEMUPDATER_LENOVO_ARTIFACT_INVENTORY=$($lenovoHistory.InventoryFile)"
        Write-Output "OEMUPDATER_LENOVO_KEY_ARTIFACT_COPY_DIR=$($lenovoHistory.KeyArtifactCopyDir)"
        Write-Output "OEMUPDATER_LENOVO_KEY_ARTIFACTS_COPIED=$($lenovoHistory.KeyArtifactsCopied)"

        Write-Output "OEMUPDATER_LENOVO_TASKLIST_FOUND=$($lenovoHistory.TaskListFound)"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_PATH=$($lenovoHistory.TaskListPath)"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_SIZE_BYTES=$($lenovoHistory.TaskListSizeBytes)"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_PARSE_SUCCEEDED=$($lenovoHistory.TaskListParseSucceeded)"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_CHILD_ELEMENTS=$($lenovoHistory.TaskListChildElementCount)"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_TASKLIKE_ELEMENTS=$($lenovoHistory.TaskListTaskLikeElementCount)"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_EMPTY=$($lenovoHistory.TaskListEmpty)"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_LIKELY_NO_APPLICABLE_UPDATES=$($lenovoHistory.TaskListLikelyNoApplicableUpdates)"

        Write-Output "OEMUPDATER_LENOVO_HISTORY_LOGS_REVIEWED=$($lenovoHistory.LogFilesReviewed.Count)"
        Write-Output "OEMUPDATER_LENOVO_WMI_ITEMS_FOUND=$($lenovoHistory.WmiItemsFound)"
        Write-Output "OEMUPDATER_LENOVO_PARSED_INSTALLED=$($lenovoHistory.InstalledCount)"
        Write-Output "OEMUPDATER_LENOVO_PARSED_FAILED=$($lenovoHistory.FailedCount)"
        Write-Output "OEMUPDATER_LENOVO_PARSED_SKIPPED=$($lenovoHistory.SkippedCount)"
        Write-Output "OEMUPDATER_LENOVO_PARSED_NOT_APPLICABLE=$($lenovoHistory.NotApplicableCount)"
        Write-Output "OEMUPDATER_LENOVO_PARSED_REBOOT_MENTIONS=$($lenovoHistory.RebootMentionCount)"
    }
    else {
        Write-Output "OEMUPDATER_LENOVO_RECENT_ARTIFACTS_FOUND=0"
        Write-Output "OEMUPDATER_LENOVO_ARTIFACT_INVENTORY="
        Write-Output "OEMUPDATER_LENOVO_KEY_ARTIFACT_COPY_DIR="
        Write-Output "OEMUPDATER_LENOVO_KEY_ARTIFACTS_COPIED=0"

        Write-Output "OEMUPDATER_LENOVO_TASKLIST_FOUND=False"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_PATH="
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_SIZE_BYTES=0"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_PARSE_SUCCEEDED=False"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_CHILD_ELEMENTS=0"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_TASKLIKE_ELEMENTS=0"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_EMPTY=False"
        Write-Output "OEMUPDATER_LENOVO_TASKLIST_LIKELY_NO_APPLICABLE_UPDATES=False"

        Write-Output "OEMUPDATER_LENOVO_HISTORY_LOGS_REVIEWED=0"
        Write-Output "OEMUPDATER_LENOVO_WMI_ITEMS_FOUND=0"
        Write-Output "OEMUPDATER_LENOVO_PARSED_INSTALLED=0"
        Write-Output "OEMUPDATER_LENOVO_PARSED_FAILED=0"
        Write-Output "OEMUPDATER_LENOVO_PARSED_SKIPPED=0"
        Write-Output "OEMUPDATER_LENOVO_PARSED_NOT_APPLICABLE=0"
        Write-Output "OEMUPDATER_LENOVO_PARSED_REBOOT_MENTIONS=0"
    }

    Write-Output "OEMUPDATER_LOG=$MainLog"

    if ($ReturnNonZeroOnVendorFailure -and $global:HadVendorFailure) {
        exit 2
    }

    exit 0
}
catch {
    Write-Log "Fatal script error: $($_.Exception.Message)" "ERROR"

    Write-Output "OEMUPDATER_RESULT=FatalError"
    Write-Output "OEMUPDATER_ERROR=$($_.Exception.Message)"
    Write-Output "OEMUPDATER_LOG=$MainLog"

    exit 1
}
finally {
    if ($hasMutex) {
        $mutex.ReleaseMutex() | Out-Null
    }

    $mutex.Dispose()
}
