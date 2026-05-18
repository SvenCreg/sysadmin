<#
ConnectWise RMM-safe OEM update runner
- Dell Command | Update
- Lenovo System Update
- HP Image Assistant

Paste directly into a ConnectWise RMM PowerShell script.
Run as System/Admin.
Do not enable auto reboot.
Recommended timeout: 120 minutes or higher.
#>

# ============================================================
# ConnectWise RMM Defaults
# ============================================================

$LenovoSearchMode = "R"                  # C = Critical, R = Critical + Recommended, A = Critical + Recommended + Optional
$HPCategoryMode = "DriversSoftware"      # DriversSoftware or All

$InstallDellCommandUpdateIfMissing = $true
$InstallDotNetDesktopRuntimeIfMissing = $true

$IncludeDellBiosFirmware = $false
$IncludeLenovoRebootPackages = $false

# If true, Dell will retry /applyUpdates without -updateType if Dell rejects all filtered attempts with exit code 107.
# Warning: unfiltered Dell apply may include BIOS/firmware updates. The script still uses -reboot=disable.
$AllowDellNoUpdateTypeFallback = $false

$VendorTimeoutMinutes = 120
$LenovoPostProcessWaitMinutes = 90

$WhatIfOnly = $false
$ReturnNonZeroOnVendorFailure = $false

$DellCommandUpdateInstallerUrl = "https://dl.dell.com/FOLDER14424601M/1/Dell-Command-Update-Windows-Universal-Application_FGK9X_WIN64_5.7.0_A00.EXE"
$DotNetDesktopRuntime8Url = "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"

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

$global:LenovoToolFound = $false
$global:LenovoApplyRan = $false

$global:HPToolFound = $false
$global:HPApplyRan = $false

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

    try {
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }

        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
        return (Test-Path -LiteralPath $OutFile)
    }
    catch {
        Write-Log "Invoke-WebRequest failed: $($_.Exception.Message)" "WARN"
    }

    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($Uri, $OutFile)
        $webClient.Dispose()
        return (Test-Path -LiteralPath $OutFile)
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

        [int[]]$WarningExitCodes = @()
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
            $global:HadVendorFailure = $true
            Write-Log "$Name returned an unexpected or non-success exit code: $exitCode" "WARN"
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

                    if ($parsedVersion.Major -eq 8 -and $parsedVersion -ge [version]"8.0.8") {
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
        return (Test-DotNetDesktopRuntime8Installed)
    }

    return $false
}

function Install-DellCommandUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadFolder
    )

    $dotNetReady = Install-DotNetDesktopRuntime8 -DownloadFolder $DownloadFolder

    if (-not $dotNetReady) {
        Write-Log "Dell Command Update install skipped because required .NET Desktop Runtime 8 x64 is not available." "WARN"
        return $false
    }

    $dcuInstaller = Join-Path $DownloadFolder "Dell-Command-Update-Installer.exe"
    $dcuInstallLog = Join-Path $DownloadFolder "Dell-Command-Update-Install.log"

    $downloaded = Invoke-FileDownload -Uri $DellCommandUpdateInstallerUrl -OutFile $dcuInstaller

    if (-not $downloaded) {
        Write-Log "Failed to download Dell Command Update installer." "ERROR"
        $global:HadVendorFailure = $true
        return $false
    }

    Write-Log "Installing Dell Command Update silently."

    $dcuInstallResult = Invoke-LoggedProcess `
        -Name "Dell Command Update Installer" `
        -FilePath $dcuInstaller `
        -Arguments @("/s", "/l=$dcuInstallLog") `
        -SuccessExitCodes @(0) `
        -RebootExitCodes @(2, 3010)

    if ($dcuInstallResult.Success) {
        Start-Sleep -Seconds 20
        return $true
    }

    return $false
}

function Find-DellCommandUpdateCli {
    $pf64 = Get-ProgramFiles64

    return Get-FirstExistingPath -Paths @(
        "$pf64\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
    )
}

function Find-HPImageAssistant {
    $pf64 = Get-ProgramFiles64

    $knownPaths = @(
        "$pf64\HP\HP Image Assistant\HPImageAssistant.exe",
        "${env:ProgramFiles(x86)}\HP\HP Image Assistant\HPImageAssistant.exe",
        "$pf64\HPIA\HPImageAssistant.exe",
        "${env:ProgramFiles(x86)}\HPIA\HPImageAssistant.exe",
        "C:\SWSetup\HPImageAssistant.exe"
    )

    $known = Get-FirstExistingPath -Paths $knownPaths

    if ($known) {
        return $known
    }

    if (Test-Path "C:\SWSetup") {
        $found = Get-ChildItem -Path "C:\SWSetup" -Filter "HPImageAssistant.exe" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($found) {
            return $found.FullName
        }
    }

    return $null
}

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

    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS

    Write-Log "Manufacturer: $($system.Manufacturer)"
    Write-Log "Model: $($system.Model)"
    Write-Log "BIOS: $($bios.SMBIOSBIOSVersion)"

    $installedApps = Get-InstalledAppNames
    $results = @()

    $pf64 = Get-ProgramFiles64

    # -----------------------------
    # Dell Command Update
    # -----------------------------
    $dellCli = Find-DellCommandUpdateCli

    if (-not $dellCli -and $system.Manufacturer -match "Dell" -and $InstallDellCommandUpdateIfMissing) {
        Write-Log "Dell system detected, but dcu-cli.exe was not found. InstallDellCommandUpdateIfMissing is enabled."

        $bootstrapDir = Join-Path $RunLogDir "Bootstrap"
        New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null

        $installedDcu = Install-DellCommandUpdate -DownloadFolder $bootstrapDir

        if ($installedDcu) {
            $dellCli = Find-DellCommandUpdateCli
        }
    }

    if ($dellCli) {
        $global:SupportedToolFound = $true
        $global:DellToolFound = $true

        $dellNativeLogDir = "C:\ProgramData\Dell\OEMUpdateRunner\$RunStamp"
        New-Item -ItemType Directory -Path $dellNativeLogDir -Force | Out-Null

        if ($IncludeDellBiosFirmware) {
            $dellUpdateTypes = @("bios", "firmware", "driver", "application")
            Write-Log "IncludeDellBiosFirmware enabled. BIOS and firmware updates may require restart even though reboot is disabled." "WARN"
        }
        else {
            $dellUpdateTypes = @("driver", "application")
            Write-Log "Dell BIOS, firmware, and other update types are excluded by default to avoid forced or unexpected restarts."
        }

        $dellAny107 = $false
        $dellAllFilteredAttempts107 = $true

        foreach ($dellUpdateType in $dellUpdateTypes) {
            $dellApplyLog = Join-Path $dellNativeLogDir "Dell-Apply-$dellUpdateType.log"

            Write-Log "Running Dell apply step for update type: $dellUpdateType"
            Write-Log "This is the step that actually installs available Dell $dellUpdateType updates."

            $global:DellApplyRan = $true

            $dellApplyResult = Invoke-LoggedProcess `
                -Name "Dell Command Update Apply $dellUpdateType" `
                -FilePath $dellCli `
                -Arguments @("/applyUpdates", "-silent", "-reboot=disable", "-updateType=$dellUpdateType", "-outputLog=$dellApplyLog") `
                -SuccessExitCodes @(0, 500) `
                -RebootExitCodes @(1, 5, 14) `
                -WarningExitCodes @(6, 7)

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

        if ($dellAny107 -and $dellAllFilteredAttempts107) {
            Write-Log "All Dell filtered update type attempts returned exit code 107." "WARN"

            if ($AllowDellNoUpdateTypeFallback) {
                $dellFallbackLog = Join-Path $dellNativeLogDir "Dell-Apply-Unfiltered.log"

                Write-Log "AllowDellNoUpdateTypeFallback is enabled. Running Dell apply without -updateType." "WARN"
                Write-Log "This may include BIOS and firmware updates. The script still passes -reboot=disable." "WARN"

                $global:DellApplyRan = $true

                $dellFallbackResult = Invoke-LoggedProcess `
                    -Name "Dell Command Update Apply Unfiltered" `
                    -FilePath $dellCli `
                    -Arguments @("/applyUpdates", "-silent", "-reboot=disable", "-outputLog=$dellFallbackLog") `
                    -SuccessExitCodes @(0, 500) `
                    -RebootExitCodes @(1, 5, 14) `
                    -WarningExitCodes @(6, 7)

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
    $lenovoTvsu = Get-FirstExistingPath -Paths @(
        "$pf64\Lenovo\System Update\Tvsu.exe",
        "${env:ProgramFiles(x86)}\Lenovo\System Update\Tvsu.exe"
    )

    if ($lenovoTvsu) {
        $global:SupportedToolFound = $true
        $global:LenovoToolFound = $true

        $lenovoArgs = @("/CM", "-search", $LenovoSearchMode, "-action", "INSTALL", "-noicon", "-nolicense")

        if ($IncludeLenovoRebootPackages) {
            $lenovoArgs += @("-includerebootpackages", "1,3,4", "-noreboot")
            Write-Log "IncludeLenovoRebootPackages enabled. Some Lenovo reboot package behavior is vendor controlled; reboot type 3 suppression does not mean every reboot type is suppressed." "WARN"
        }
        else {
            Write-Log "Lenovo reboot-required packages are excluded by default."
        }

        Write-Log "Running Lenovo System Update install step."

        $global:LenovoApplyRan = $true

        $lenovoResult = Invoke-LoggedProcess `
            -Name "Lenovo System Update Apply" `
            -FilePath $lenovoTvsu `
            -Arguments $lenovoArgs `
            -SuccessExitCodes @(0) `
            -WarningExitCodes @(1)

        if ($null -ne $lenovoResult -and $lenovoResult.PSObject.Properties.Name -contains "Tool") {
            $results += $lenovoResult
        }

        Wait-ForProcessNames `
            -Label "Lenovo System Update" `
            -ProcessNames @("tvsu", "tvsukernel", "tvsucommandlauncher", "tvsuscheduler") `
            -TimeoutMinutes $LenovoPostProcessWaitMinutes
    }
    elseif (($system.Manufacturer -match "Lenovo") -or ($installedApps -match "Lenovo Vantage|Commercial Vantage|LenovoCommercialVantage|Lenovo System Update")) {
        Write-Log "Lenovo system or software detected, but Lenovo System Update CLI Tvsu.exe was not found. Skipping Lenovo updates. Lenovo Vantage GUI is intentionally not launched from RMM." "WARN"
    }

    # -----------------------------
    # HP Image Assistant
    # -----------------------------
    $hpia = Find-HPImageAssistant

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
            Write-Log "HP category mode is DriversSoftware. HP Image Assistant will run separate Drivers and Software passes. BIOS and firmware are excluded by default."
        }

        foreach ($hpCategory in $hpCategories) {
            Write-Log "Running HP Image Assistant install step for category: $hpCategory"

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
                -RebootExitCodes @(3010) `
                -WarningExitCodes @(3011, 4096, 4104)

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
    Write-Log "Dell apply ran: $global:DellApplyRan"
    Write-Log "Lenovo tool found: $global:LenovoToolFound"
    Write-Log "Lenovo apply ran: $global:LenovoApplyRan"
    Write-Log "HP tool found: $global:HPToolFound"
    Write-Log "HP apply ran: $global:HPApplyRan"

    Write-Log "Reboot required reported by vendor tool: $global:RebootRequired"
    Write-Log "Vendor warning detected: $global:HadVendorWarning"
    Write-Log "Vendor failure detected: $global:HadVendorFailure"
    Write-Log "OEM update run complete."

    Write-Output "OEMUPDATER_RESULT=Complete"
    Write-Output "OEMUPDATER_SUPPORTED_TOOL_FOUND=$global:SupportedToolFound"
    Write-Output "OEMUPDATER_DELL_TOOL_FOUND=$global:DellToolFound"
    Write-Output "OEMUPDATER_DELL_APPLY_RAN=$global:DellApplyRan"
    Write-Output "OEMUPDATER_LENOVO_TOOL_FOUND=$global:LenovoToolFound"
    Write-Output "OEMUPDATER_LENOVO_APPLY_RAN=$global:LenovoApplyRan"
    Write-Output "OEMUPDATER_HP_TOOL_FOUND=$global:HPToolFound"
    Write-Output "OEMUPDATER_HP_APPLY_RAN=$global:HPApplyRan"
    Write-Output "OEMUPDATER_REBOOT_REQUIRED=$global:RebootRequired"
    Write-Output "OEMUPDATER_VENDOR_WARNING=$global:HadVendorWarning"
    Write-Output "OEMUPDATER_VENDOR_FAILURE=$global:HadVendorFailure"
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
