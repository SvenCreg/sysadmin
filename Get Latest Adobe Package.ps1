# Name: Update-AdobeAcrobatAdjacent-ManualVersion.ps1
# Description:
#   Detects Adobe Acrobat / Adobe Acrobat Reader only, determines product and architecture,
#   downloads the manually specified Continuous Track MSP update from Adobe, and installs it silently.
#
# Designed for ConnectWise RMM execution as System/elevated PowerShell.
#
# Important behavior:
#   - Uses the actual Acrobat.exe / AcroRd32.exe version as the source of truth when available.
#   - Fixes uninstall registry DisplayVersion for ConnectWise inventory if Adobe is already updated.
#   - Only runs the MSP if the actual executable version is older than the target.
#
# Safety behavior:
#   - If Acrobat.exe or AcroRd32.exe is open and an update is needed, the script exits 0 and does NOT update.
#   - If only Adobe background helper processes are running, it closes them before patching.
#   - It does NOT close Acrobat.exe or AcroRd32.exe.
#   - It does NOT reopen Adobe helper processes afterward.
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

# Update Windows uninstall registry DisplayVersion after successful verification/install.
# This helps ConnectWise RMM software inventory report the patched version.
$UpdateInventoryDisplayVersion = $true

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

function Normalize-AdobeVersion {
    param(
        [string]$VersionText
    )

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $match = [regex]::Match($VersionText, "\b(?<major>\d{2})\.(?<minor>\d{1,3})\.(?<build>\d{1,5})(?:\.\d+)?\b")

    if (-not $match.Success) {
        return $null
    }

    $major = [int]$match.Groups["major"].Value
    $minor = [int]$match.Groups["minor"].Value
    $build = [int]$match.Groups["build"].Value

    return ("{0:00}.{1:000}.{2:00000}" -f $major, $minor, $build)
}

function Compare-VersionSafe {
    param(
        [string]$InstalledVersion,
        [string]$LatestVersion
    )

    $installedNormalized = Normalize-AdobeVersion -VersionText $InstalledVersion
    $latestNormalized = Normalize-AdobeVersion -VersionText $LatestVersion

    if (-not $installedNormalized -or -not $latestNormalized) {
        return $null
    }

    try {
        return ([version]$installedNormalized).CompareTo([version]$latestNormalized)
    }
    catch {
        return $null
    }
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

function Update-AdobeUninstallDisplayVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Product,

        [Parameter(Mandatory = $true)]
        [string]$VersionToWrite
    )

    if (-not $UpdateInventoryDisplayVersion) {
        Write-Log "Inventory DisplayVersion update is disabled."
        return
    }

    if ([string]::IsNullOrWhiteSpace($Product.RegistryPath)) {
        Write-Log "Cannot update uninstall DisplayVersion because RegistryPath is missing for '$($Product.DisplayName)'."
        return
    }

    $normalizedVersionToWrite = Normalize-AdobeVersion -VersionText $VersionToWrite

    if (-not $normalizedVersionToWrite) {
        Write-Log "Cannot update uninstall DisplayVersion because '$VersionToWrite' is not a valid Adobe version."
        return
    }

    try {
        $currentItem = Get-ItemProperty -Path $Product.RegistryPath -ErrorAction Stop
        $currentDisplayVersion = Normalize-AdobeVersion -VersionText $currentItem.DisplayVersion

        if ($currentDisplayVersion -eq $normalizedVersionToWrite) {
            Write-Log "Uninstall registry DisplayVersion for '$($Product.DisplayName)' is already '$normalizedVersionToWrite'."
            return
        }

        Write-Log "Updating uninstall registry DisplayVersion for '$($Product.DisplayName)'. Current: '$($currentItem.DisplayVersion)' Target: '$normalizedVersionToWrite'."

        Set-ItemProperty `
            -Path $Product.RegistryPath `
            -Name "DisplayVersion" `
            -Value $normalizedVersionToWrite `
            -ErrorAction Stop

        $updatedItem = Get-ItemProperty -Path $Product.RegistryPath -ErrorAction Stop
        Write-Log "Updated uninstall registry DisplayVersion for '$($Product.DisplayName)' to '$($updatedItem.DisplayVersion)'."
    }
    catch {
        Write-Log "Could not update uninstall registry DisplayVersion for '$($Product.DisplayName)': $($_.Exception.Message)"
    }
}

function Get-AdobeExecutableInfo {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Product
    )

    $candidatePaths = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($Product.InstallLocation)) {
        if ($Product.ProductType -eq "Reader") {
            $candidatePaths.Add((Join-Path $Product.InstallLocation "AcroRd32.exe"))
            $candidatePaths.Add((Join-Path $Product.InstallLocation "Reader\AcroRd32.exe"))
        }
        else {
            $candidatePaths.Add((Join-Path $Product.InstallLocation "Acrobat.exe"))
            $candidatePaths.Add((Join-Path $Product.InstallLocation "Acrobat\Acrobat.exe"))
        }
    }

    if ($Product.ProductType -eq "Reader") {
        $candidatePaths.Add("$env:ProgramFiles\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe")
        $candidatePaths.Add("${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe")
    }
    else {
        $candidatePaths.Add("$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe")
        $candidatePaths.Add("${env:ProgramFiles(x86)}\Adobe\Acrobat DC\Acrobat\Acrobat.exe")
    }

    foreach ($path in ($candidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path $path) {
            try {
                $item = Get-Item $path -ErrorAction Stop
                $fileVersion = $item.VersionInfo.FileVersion
                $productVersion = $item.VersionInfo.ProductVersion

                $normalizedVersion = Normalize-AdobeVersion -VersionText $productVersion

                if (-not $normalizedVersion) {
                    $normalizedVersion = Normalize-AdobeVersion -VersionText $fileVersion
                }

                return [PSCustomObject]@{
                    Path              = $path
                    FileVersion       = $fileVersion
                    ProductVersion    = $productVersion
                    NormalizedVersion = $normalizedVersion
                }
            }
            catch {
                Write-Log "Could not read executable version from '$path': $($_.Exception.Message)"
            }
        }
    }

    return [PSCustomObject]@{
        Path              = $null
        FileVersion       = $null
        ProductVersion    = $null
        NormalizedVersion = $null
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

function Get-ProductUpdateState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Product,

        [Parameter(Mandatory = $true)]
        [string]$TargetVersion
    )

    $exeInfo = Get-AdobeExecutableInfo -Product $Product
    $displayVersionNormalized = Normalize-AdobeVersion -VersionText $Product.DisplayVersion

    if ($exeInfo.NormalizedVersion) {
        $comparison = Compare-VersionSafe -InstalledVersion $exeInfo.NormalizedVersion -LatestVersion $TargetVersion

        return [PSCustomObject]@{
            Source                = "Executable"
            CurrentVersion        = $exeInfo.NormalizedVersion
            DisplayVersion        = $displayVersionNormalized
            ExecutablePath        = $exeInfo.Path
            NeedsUpdate           = ($comparison -lt 0)
            CanDetermineVersion   = ($null -ne $comparison)
        }
    }

    $fallbackComparison = Compare-VersionSafe -InstalledVersion $Product.DisplayVersion -LatestVersion $TargetVersion

    return [PSCustomObject]@{
        Source                = "UninstallRegistry"
        CurrentVersion        = $displayVersionNormalized
        DisplayVersion        = $displayVersionNormalized
        ExecutablePath        = $null
        NeedsUpdate           = ($fallbackComparison -lt 0)
        CanDetermineVersion   = ($null -ne $fallbackComparison)
    }
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

    $productStates = New-Object System.Collections.Generic.List[object]

    foreach ($product in $products) {
        $state = Get-ProductUpdateState -Product $product -TargetVersion $AdobeTargetVersion

        Write-Log "Detected product: $($product.DisplayName) | Registry DisplayVersion: $($product.DisplayVersion) | ActualVersionSource: $($state.Source) | ActualVersion: $($state.CurrentVersion) | ExePath: $($state.ExecutablePath) | Type: $($product.ProductType) | Arch: $($product.Architecture) | Track: $($product.Track) | MUI detected: $($product.IsMUI) | RegistryPath: $($product.RegistryPath)"

        # Fix ConnectWise-visible mismatch immediately if executable proves the app is already target/newer.
        if ($product.Track -ne "UnsupportedOrClassic" -and $state.Source -eq "Executable" -and $state.CanDetermineVersion -and -not $state.NeedsUpdate) {
            if ($state.DisplayVersion -ne $state.CurrentVersion) {
                Write-Log "Inventory mismatch detected for '$($product.DisplayName)': registry DisplayVersion '$($product.DisplayVersion)' does not match executable version '$($state.CurrentVersion)'."
                Update-AdobeUninstallDisplayVersion -Product $product -VersionToWrite $state.CurrentVersion
            }
            else {
                Write-Log "No inventory mismatch detected for '$($product.DisplayName)'."
            }
        }

        $productStates.Add([PSCustomObject]@{
            Product = $product
            State   = $state
        })
    }

    $productsNeedingUpdate = @(
        $productStates |
            Where-Object {
                $_.Product.Track -ne "UnsupportedOrClassic" -and
                (
                    ($_.State.CanDetermineVersion -and $_.State.NeedsUpdate) -or
                    (-not $_.State.CanDetermineVersion)
                )
            }
    )

    if ($productsNeedingUpdate.Count -eq 0) {
        Write-Log "No applicable Adobe Acrobat/Reader products require MSP installation. Any detected inventory mismatch has already been corrected."
        exit 0
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
        Write-Log "Adobe Acrobat/Reader is actively open and at least one product requires an update. Skipping update to avoid closing user documents."

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

    foreach ($entry in $productsNeedingUpdate) {
        $product = $entry.Product
        $state = $entry.State

        Write-Log "Evaluating product for MSP install: $($product.DisplayName)"

        if ($product.Track -eq "UnsupportedOrClassic") {
            Write-Log "Skipping '$($product.DisplayName)' because it appears to be Classic/2020/2024/legacy or otherwise unsupported by this Continuous Track MSP script."
            continue
        }

        if ($state.CanDetermineVersion) {
            Write-Log "'$($product.DisplayName)' requires update. Source: $($state.Source). Current: $($state.CurrentVersion), target: $AdobeTargetVersion."
        }
        else {
            Write-Log "Could not determine reliable installed version for '$($product.DisplayName)'. Continuing with update attempt."
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

                    $postInstallExeInfo = Get-AdobeExecutableInfo -Product $product

                    if ($postInstallExeInfo.NormalizedVersion) {
                        Write-Log "Post-install executable version for '$($product.DisplayName)' is '$($postInstallExeInfo.NormalizedVersion)' from '$($postInstallExeInfo.Path)'."
                        Update-AdobeUninstallDisplayVersion -Product $product -VersionToWrite $postInstallExeInfo.NormalizedVersion
                    }
                    else {
                        Write-Log "Could not verify post-install executable version for '$($product.DisplayName)'. Writing target version '$AdobeTargetVersion' to inventory DisplayVersion."
                        Update-AdobeUninstallDisplayVersion -Product $product -VersionToWrite $AdobeTargetVersion
                    }

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
