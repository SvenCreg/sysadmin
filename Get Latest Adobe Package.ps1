# Name: Update-AdobeAcrobatAdjacent-ManualVersion.ps1
# Description:
#   Detects Adobe Acrobat / Adobe Acrobat Reader only, determines product and architecture,
#   downloads the manually specified Continuous Track MSP update from Adobe, and installs it silently.
#
# Designed for ConnectWise RMM execution as System/elevated PowerShell.
#
# Default safety behavior:
#   - If Acrobat.exe or AcroRd32.exe is open, the script exits 0 and does NOT update.
#   - If only Adobe background helper processes are running, it closes them before patching.
#   - It does NOT close Acrobat.exe or AcroRd32.exe.
#   - It does NOT reopen Adobe helper processes afterward.
#   - It does NOT require launch flags.
#
# Version behavior:
#   - No Adobe release-note scraping.
#   - Set the desired Adobe version manually in $AdobeTargetVersion.
#
# Cleanup behavior:
#   - Downloaded MSP patch files are removed after successful installation.
#   - Reader MSPs that return "patch not applicable" during MUI/non-MUI fallback are also removed.
#   - Logs are kept for troubleshooting.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =========================
# ConnectWise RMM settings
# =========================

$WorkingDirectory = "C:\ProgramData\AdobeAcrobatUpdate"

# Manually set the Adobe Acrobat / Reader Continuous Track version here.
# Format must be ##.###.##### such as 26.001.21563
$AdobeTargetVersion = "26.001.21563"

# Adobe direct download hosts.
# The script will try these in order.
$AdobeDownloadBaseUrls = @(
    "https://ardownload3.adobe.com/pub/adobe/acrobat/win/AcrobatDC",
    "https://ardownload3.adobe.com/pub/adobe/reader/win/AcrobatDC",
    "https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC",
    "https://ardownload2.adobe.com/pub/adobe/reader/win/AcrobatDC"
)

# Reader MUI detection is not always obvious from registry.
# AutoTryBoth tries the likely Reader MSP first, then tries the alternate
# Reader MSP only if MSI says the patch is not applicable.
#
# Valid values:
#   AutoTryBoth
#   ForceMUI
#   ForceSingleLanguage
$ReaderPatchPreference = "AutoTryBoth"

# Set to $true only for testing download logic without installing.
$DownloadOnly = $false

# Remove downloaded MSP files after successful use.
$CleanupDownloadedPatches = $true

# Web timeout/retry settings.
$WebRequestTimeoutSeconds = 120
$WebRequestRetries = 3
$WebRequestRetryDelaySeconds = 10

# Installer timeout.
$InstallerTimeoutMinutes = 45

$AdobeWebHeaders = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
    "Accept"     = "*/*"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
catch {
    # Ignore on newer PowerShell versions.
}

New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null

$LogFile = Join-Path $WorkingDirectory "AdobeAcrobatAdjacentUpdate.log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "$(Get-Date -Format s) $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Test-AdobeVersionFormat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    return $Version -match "^\d{2}\.\d{3}\.\d{5}$"
}

function Invoke-AdobeWebRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )

    for ($attempt = 1; $attempt -le $WebRequestRetries; $attempt++) {
        try {
            Write-Log ("Web download attempt {0} of {1}: {2}" -f $attempt, $WebRequestRetries, $Uri)

            Invoke-WebRequest `
                -UseBasicParsing `
                -Uri $Uri `
                -Headers $AdobeWebHeaders `
                -TimeoutSec $WebRequestTimeoutSeconds `
                -OutFile $OutFile `
                -ErrorAction Stop

            return $true
        }
        catch {
            Write-Log ("Web download failed on attempt {0} of {1}: {2}" -f $attempt, $WebRequestRetries, $_.Exception.Message)

            if (Test-Path $OutFile) {
                try {
                    Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue
                }
                catch {
                    # Ignore cleanup failure for partial download.
                }
            }

            if ($attempt -lt $WebRequestRetries) {
                Write-Log "Waiting $WebRequestRetryDelaySeconds second(s) before retrying web download."
                Start-Sleep -Seconds $WebRequestRetryDelaySeconds
            }
        }
    }

    throw "Web download failed after $WebRequestRetries attempt(s): $Uri"
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Compare-VersionSafe {
    param(
        [string]$InstalledVersion,
        [string]$LatestVersion
    )

    try {
        return ([version]$InstalledVersion).CompareTo([version]$LatestVersion)
    }
    catch {
        return $null
    }
}

function Remove-DownloadedPatchFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PatchPath
    )

    if (-not $CleanupDownloadedPatches) {
        Write-Log "Cleanup is disabled. Leaving downloaded patch file in place: $PatchPath"
        return
    }

    if (-not (Test-Path $PatchPath)) {
        return
    }

    try {
        Remove-Item -Path $PatchPath -Force -ErrorAction Stop
        Write-Log "Removed downloaded patch file: $PatchPath"
    }
    catch {
        Write-Log "Could not remove downloaded patch file '$PatchPath': $($_.Exception.Message)"
    }
}

function Get-AdobeProcessesByName {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ProcessNames
    )

    $running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $ProcessNames -contains $_.Name }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($process in $running) {
        $ownerName = "Unknown"

        try {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction SilentlyContinue

            if ($owner -and $owner.User) {
                if ($owner.Domain) {
                    $ownerName = "$($owner.Domain)\$($owner.User)"
                }
                else {
                    $ownerName = $owner.User
                }
            }
        }
        catch {
            $ownerName = "Unknown"
        }

        $results.Add([PSCustomObject]@{
            Name        = $process.Name
            ProcessId   = $process.ProcessId
            SessionId   = $process.SessionId
            Owner       = $ownerName
            CommandLine = $process.CommandLine
        })
    }

    return $results
}

function Stop-AdobeBackgroundProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Processes
    )

    foreach ($process in $Processes) {
        try {
            Write-Log "Closing Adobe background process: $($process.Name) | PID: $($process.ProcessId) | Session: $($process.SessionId) | Owner: $($process.Owner)"
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
        catch {
            Write-Log "Could not close Adobe background process $($process.Name) PID $($process.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Get-InstalledAdobeAcrobatAdjacentProducts {
    $uninstallRoots = @(
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
            RegistryArchitecture = "x64"
        },
        @{
            Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            RegistryArchitecture = "x86"
        }
    )

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($root in $uninstallRoots) {
        $items = Get-ItemProperty -Path $root.Path -ErrorAction SilentlyContinue

        foreach ($item in $items) {
            $displayName = Get-PropertyValue -Object $item -Name "DisplayName"

            if ([string]::IsNullOrWhiteSpace($displayName)) {
                continue
            }

            $isAcrobatFamily =
                $displayName -match "^Adobe\s+Acrobat(\s+Reader)?\b" -or
                $displayName -match "^Adobe\s+Reader\b"

            if (-not $isAcrobatFamily) {
                continue
            }

            if ($displayName -match "(Update\s+Service|Refresh\s+Manager|Synchronizer|Genuine|ARM|Notification|Collaboration|Core\s+Sync)") {
                continue
            }

            $publisher       = Get-PropertyValue -Object $item -Name "Publisher"
            $displayVersion  = Get-PropertyValue -Object $item -Name "DisplayVersion"
            $installLocation = Get-PropertyValue -Object $item -Name "InstallLocation"
            $uninstallString = Get-PropertyValue -Object $item -Name "UninstallString"
            $psPath          = Get-PropertyValue -Object $item -Name "PSPath"

            if ($publisher -and $publisher -notmatch "Adobe") {
                continue
            }

            $productType = "Acrobat"

            if ($displayName -match "Reader" -or $displayName -match "^Adobe\s+Reader\b") {
                $productType = "Reader"
            }

            $architecture = $null

            if ($displayName -match "(64-bit|x64)") {
                $architecture = "x64"
            }
            elseif ($displayName -match "(32-bit|x86)") {
                $architecture = "x86"
            }
            elseif ($installLocation -match "\(x86\)" -or $uninstallString -match "\(x86\)" -or $psPath -match "WOW6432Node") {
                $architecture = "x86"
            }
            elseif ($root.RegistryArchitecture -eq "x86") {
                $architecture = "x86"
            }
            else {
                $architecture = "x64"
            }

            $track = "ContinuousAssumed"

            if (
                $displayName -match "(Classic|2020|2024|2017|2015| XI\b| X\b)" -or
                $installLocation -match "(Acrobat\s+2020|Acrobat\s+2024|Acrobat\s+2017|Acrobat\s+2015|Acrobat\s+XI|Acrobat\s+X)"
            ) {
                $track = "UnsupportedOrClassic"
            }

            $isMui = $false

            if (
                $displayName -match "\bMUI\b" -or
                $installLocation -match "\bMUI\b" -or
                $uninstallString -match "\bMUI\b"
            ) {
                $isMui = $true
            }

            $results.Add([PSCustomObject]@{
                DisplayName      = $displayName
                DisplayVersion   = $displayVersion
                ProductType      = $productType
                Architecture     = $architecture
                Track            = $track
                IsMUI            = $isMui
                InstallLocation  = $installLocation
                UninstallString  = $uninstallString
                RegistryPath     = $psPath
            })
        }
    }

    $results |
        Sort-Object ProductType, Architecture, DisplayName, DisplayVersion -Unique
}

function Get-AcrobatPatchFileName {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("x86", "x64")]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $versionNoDots = $Version.Replace(".", "")
    $archText = ""

    if ($Architecture -eq "x64") {
        $archText = "x64"
    }

    return "AcrobatDC$($archText)Upd$versionNoDots.msp"
}

function Get-ReaderPatchFileNames {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("x86", "x64")]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [bool]$DetectedMUI
    )

    $versionNoDots = $Version.Replace(".", "")
    $archText = ""

    if ($Architecture -eq "x64") {
        $archText = "x64"
    }

    $singleLanguagePatch = "AcroRdrDC$($archText)Upd$versionNoDots.msp"
    $muiPatch = "AcroRdrDC$($archText)Upd$($versionNoDots)_MUI.msp"

    switch ($ReaderPatchPreference) {
        "ForceMUI" {
            return @($muiPatch)
        }
        "ForceSingleLanguage" {
            return @($singleLanguagePatch)
        }
        default {
            if ($DetectedMUI) {
                return @($muiPatch, $singleLanguagePatch)
            }
            else {
                return @($singleLanguagePatch, $muiPatch)
            }
        }
    }
}

function Get-DirectAdobePatchUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$PatchFileName
    )

    $versionNoDots = $Version.Replace(".", "")

    foreach ($baseUrl in $AdobeDownloadBaseUrls) {
        "$baseUrl/$versionNoDots/$PatchFileName"
    }
}

function Download-AdobePatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$PatchFileName,

        [Parameter(Mandatory = $true)]
        [string]$PatchPath
    )

    $candidateUrls = @(Get-DirectAdobePatchUrls -Version $Version -PatchFileName $PatchFileName)

    foreach ($url in $candidateUrls) {
        try {
            Write-Log "Trying Adobe direct download URL: $url"
            Invoke-AdobeWebRequest -Uri $url -OutFile $PatchPath

            if (Test-Path $PatchPath) {
                Write-Log "Patch downloaded successfully from: $url"
                return $true
            }
        }
        catch {
            Write-Log "Download failed from '$url': $($_.Exception.Message)"

            if (Test-Path $PatchPath) {
                try {
                    Remove-Item -Path $PatchPath -Force -ErrorAction SilentlyContinue
                }
                catch {
                    # Ignore partial cleanup failure.
                }
            }
        }
    }

    throw "Failed to download patch '$PatchFileName' from all configured Adobe download hosts."
}

function Install-AdobePatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PatchPath
    )

    $msiLog = Join-Path $WorkingDirectory ("msiexec-" + [IO.Path]::GetFileNameWithoutExtension($PatchPath) + ".log")

    $arguments = "/p `"$PatchPath`" /qn /norestart /L*v `"$msiLog`""

    Write-Log "Running: msiexec.exe $arguments"
    Write-Log "Installer timeout is set to $InstallerTimeoutMinutes minute(s)."

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -PassThru

    $timeoutMilliseconds = [int]([TimeSpan]::FromMinutes($InstallerTimeoutMinutes).TotalMilliseconds)
    $completed = $process.WaitForExit($timeoutMilliseconds)

    if (-not $completed) {
        Write-Log "msiexec did not finish within $InstallerTimeoutMinutes minute(s). Attempting to stop installer process."

        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Write-Log "Stopped timed-out msiexec process. PID: $($process.Id)"
        }
        catch {
            Write-Log "Could not stop timed-out msiexec process. PID: $($process.Id). Error: $($_.Exception.Message)"
        }

        Write-Log "MSI log may contain more detail: $msiLog"

        # 1460 = timeout
        return 1460
    }

    $process.Refresh()

    Write-Log "msiexec exit code: $($process.ExitCode)"
    Write-Log "MSI log: $msiLog"

    return $process.ExitCode
}

function Test-MsiSuccessCode {
    param([int]$ExitCode)

    return $ExitCode -in @(0, 3010, 1641)
}

# =========================
# Main execution
# =========================

try {
    Write-Log "Starting Adobe Acrobat/Reader update process."

    if (-not (Test-AdobeVersionFormat -Version $AdobeTargetVersion)) {
        throw "AdobeTargetVersion '$AdobeTargetVersion' is not valid. Expected format is ##.###.##### such as 26.001.21563."
    }

    Write-Log "Manual Adobe target version: $AdobeTargetVersion"
    Write-Log "No Adobe release-note lookup will be performed."

    $products = @(Get-InstalledAdobeAcrobatAdjacentProducts)

    if ($products.Count -eq 0) {
        Write-Log "No Adobe Acrobat or Adobe Acrobat Reader products detected. Nothing to update."
        exit 0
    }

    Write-Log "Detected $($products.Count) Acrobat-adjacent product(s)."

    foreach ($product in $products) {
        Write-Log "Detected product: $($product.DisplayName) | Version: $($product.DisplayVersion) | Type: $($product.ProductType) | Arch: $($product.Architecture) | Track: $($product.Track) | MUI detected: $($product.IsMUI)"
    }

    # =========================
    # Adobe in-use safety check
    # =========================

    $AdobeUserAppProcesses = @(
        "Acrobat.exe",
        "AcroRd32.exe"
    )

    $AdobeBackgroundProcesses = @(
        "AcroCEF.exe",
        "RdrCEF.exe",
        "AdobeCollabSync.exe"
    )

    $runningAdobeUserApps = @(Get-AdobeProcessesByName -ProcessNames $AdobeUserAppProcesses)

    if ($runningAdobeUserApps.Count -gt 0) {
        Write-Log "Adobe Acrobat/Reader is actively open. Skipping update to avoid closing user documents."

        foreach ($process in $runningAdobeUserApps) {
            Write-Log "Open Adobe app detected: $($process.Name) | PID: $($process.ProcessId) | Session: $($process.SessionId) | Owner: $($process.Owner)"
        }

        Write-Log "Exiting without installing. ConnectWise can retry on the next scheduled run."
        exit 0
    }

    $runningAdobeBackgroundProcesses = @(Get-AdobeProcessesByName -ProcessNames $AdobeBackgroundProcesses)

    if ($runningAdobeBackgroundProcesses.Count -gt 0) {
        Write-Log "No Acrobat/Reader user app is open, but Adobe background helper processes are running."
        Write-Log "Closing Adobe background helper processes before applying MSP update."

        Stop-AdobeBackgroundProcesses -Processes $runningAdobeBackgroundProcesses

        Start-Sleep -Seconds 3
    }
    else {
        Write-Log "No active Acrobat/Reader user app or Adobe background helper processes detected."
    }

    # =========================
    # Update process
    # =========================

    $overallExitCode = 0
    $updatedSomething = $false

    foreach ($product in $products) {
        Write-Log "Evaluating product: $($product.DisplayName)"

        if ($product.Track -eq "UnsupportedOrClassic") {
            Write-Log "Skipping '$($product.DisplayName)' because it appears to be Classic/2020/2024/legacy or otherwise unsupported by this Continuous Track MSP script."
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($product.DisplayVersion)) {
            $comparison = Compare-VersionSafe -InstalledVersion $product.DisplayVersion -LatestVersion $AdobeTargetVersion

            if ($null -eq $comparison) {
                Write-Log "Could not compare installed version '$($product.DisplayVersion)' to target '$AdobeTargetVersion'. Continuing with update attempt."
            }
            elseif ($comparison -ge 0) {
                Write-Log "'$($product.DisplayName)' is already current or newer. Installed: $($product.DisplayVersion), target: $AdobeTargetVersion."
                continue
            }
            else {
                Write-Log "'$($product.DisplayName)' requires update. Installed: $($product.DisplayVersion), target: $AdobeTargetVersion."
            }
        }
        else {
            Write-Log "Installed version is missing for '$($product.DisplayName)'. Continuing with update attempt."
        }

        if ($product.ProductType -eq "Acrobat") {
            $candidatePatchFiles = @(
                Get-AcrobatPatchFileName -Architecture $product.Architecture -Version $AdobeTargetVersion
            )
        }
        else {
            $candidatePatchFiles = @(
                Get-ReaderPatchFileNames `
                    -Architecture $product.Architecture `
                    -Version $AdobeTargetVersion `
                    -DetectedMUI ([bool]$product.IsMUI)
            )
        }

        $productUpdated = $false
        $lastExitCode = 0

        foreach ($patchFileName in $candidatePatchFiles) {
            Write-Log "Trying patch candidate for '$($product.DisplayName)': $patchFileName"

            $patchPath = Join-Path $WorkingDirectory $patchFileName

            try {
                Download-AdobePatch `
                    -Version $AdobeTargetVersion `
                    -PatchFileName $patchFileName `
                    -PatchPath $patchPath
            }
            catch {
                Write-Log "Failed to download patch '$patchFileName': $($_.Exception.Message)"
                $lastExitCode = 1
                continue
            }

            if (-not (Test-Path $patchPath)) {
                Write-Log "Patch download did not create expected file: $patchPath"
                $lastExitCode = 1
                continue
            }

            Write-Log "Patch ready for installation: $patchPath"

            if ($DownloadOnly) {
                Write-Log "DownloadOnly is enabled. Skipping installation and leaving patch file in place: $patchPath"
                $productUpdated = $true
                break
            }

            try {
                $exitCode = Install-AdobePatch -PatchPath $patchPath
                $lastExitCode = $exitCode

                if (Test-MsiSuccessCode -ExitCode $exitCode) {
                    Write-Log "Patch succeeded for '$($product.DisplayName)' using '$patchFileName'."
                    Remove-DownloadedPatchFile -PatchPath $patchPath

                    $updatedSomething = $true
                    $productUpdated = $true
                    break
                }

                if ($exitCode -eq 1460) {
                    Write-Log "Installer timed out. Leaving downloaded patch file for troubleshooting: $patchPath"
                    $overallExitCode = 1460
                    break
                }

                if ($exitCode -eq 1618) {
                    Write-Log "Another Windows Installer operation is already in progress. Exiting cleanly so ConnectWise can retry later."
                    Remove-DownloadedPatchFile -PatchPath $patchPath
                    exit 0
                }

                if ($product.ProductType -eq "Reader" -and $exitCode -eq 1642) {
                    Write-Log "MSI exit code 1642 means this patch is not applicable. For Reader, trying the alternate MUI/non-MUI patch if available."
                    Remove-DownloadedPatchFile -PatchPath $patchPath
                    continue
                }

                Write-Log "Patch failed for '$($product.DisplayName)' using '$patchFileName' with exit code $exitCode."
                Write-Log "Leaving downloaded patch file for troubleshooting: $patchPath"
            }
            catch {
                Write-Log "Exception while installing '$patchFileName': $($_.Exception.Message)"
                Write-Log "Leaving downloaded patch file for troubleshooting: $patchPath"
                $lastExitCode = 1
            }
        }

        if (-not $productUpdated) {
            Write-Log "No patch candidate completed successfully for '$($product.DisplayName)'."

            if ($lastExitCode -ne 0) {
                $overallExitCode = $lastExitCode
            }
            elseif ($overallExitCode -ne 0) {
                # Preserve earlier non-zero exit code.
            }
            else {
                $overallExitCode = 1
            }
        }
    }

    if ($overallExitCode -eq 0) {
        if ($updatedSomething) {
            Write-Log "Adobe Acrobat/Reader update process completed successfully."
        }
        else {
            Write-Log "No applicable Adobe Acrobat/Reader products required installation."
        }

        exit 0
    }

    Write-Log "Adobe Acrobat/Reader update process completed with errors. Exit code: $overallExitCode"
    exit $overallExitCode
}
catch {
    Write-Log "Fatal script error: $($_.Exception.Message)"
    exit 1
}
