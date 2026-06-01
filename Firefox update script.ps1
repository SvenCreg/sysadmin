# Name: Update-AdobeAcrobatAdjacent.ps1
# Description:
#   Detects Adobe Acrobat / Adobe Acrobat Reader only, determines product and architecture,
#   downloads the latest matching Continuous Track MSP update from Adobe, and installs it silently.
#
# Designed for ConnectWise RMM execution as System/elevated PowerShell.
#
# Default safety behavior:
#   - If Acrobat/Reader appears to be running, the script exits 0 and does NOT update.
#   - It does NOT close Adobe apps.
#   - It does NOT require launch flags.
#
# Cleanup behavior:
#   - Downloaded MSP patch files are removed after successful installation.
#   - Reader MSPs that return "patch not applicable" during MUI/non-MUI fallback are also removed.
#   - Logs are kept for troubleshooting.
#
# Scope:
#   - Adobe Acrobat Continuous Track
#   - Adobe Acrobat Reader Continuous Track
#   - x86 and x64
#   - Reader MUI and non-MUI
#
# Does NOT patch:
#   - Photoshop, Illustrator, Creative Cloud, etc.
#   - Adobe Genuine Service
#   - Adobe Acrobat Update Service only
#   - Classic/2020/2024/legacy Acrobat tracks

$ErrorActionPreference = "Stop"

# =========================
# ConnectWise RMM settings
# =========================

$WorkingDirectory = "C:\ProgramData\AdobeAcrobatUpdate"

# No launch flags needed.
# If Acrobat/Reader is running, the script safely exits before download/install.

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
# Logs are still retained.
$CleanupDownloadedPatches = $true

# =========================
# Adobe release notes source
# =========================

$ReleaseNotesIndexUrl = "https://www.adobe.com/devnet-docs/acrobatetk/tools/ReleaseNotesDC/index.html"

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

function Resolve-Url {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Href
    )

    if ($Href -match "^https?://") {
        return $Href
    }

    return ([Uri]::new([Uri]$BaseUrl, $Href)).AbsoluteUri
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

function Get-RunningAdobeUserProcesses {
    # Conservative by design.
    # If any of these are running, Acrobat/Reader may have open user documents.
    $processNames = @(
        "Acrobat.exe",
        "AcroRd32.exe",
        "AcroCEF.exe",
        "RdrCEF.exe"
    )

    $running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $processNames -contains $_.Name }

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

            # Include Adobe Acrobat / Reader only.
            $isAcrobatFamily =
                $displayName -match "^Adobe\s+Acrobat(\s+Reader)?\b" -or
                $displayName -match "^Adobe\s+Reader\b"

            if (-not $isAcrobatFamily) {
                continue
            }

            # Exclude adjacent services/components that are not the app itself.
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

            # Avoid forcing Continuous Track MSPs onto Classic/legacy installs.
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

function Get-LatestAdobeContinuousRelease {
    Write-Log "Checking Adobe Continuous Track release notes."

    $response = Invoke-WebRequest -UseBasicParsing -Uri $ReleaseNotesIndexUrl
    $content = $response.Content

    $matches = [regex]::Matches(
        $content,
        '<a\s+[^>]*href="(?<href>continuous/[^"]+)"[^>]*>.*?(?<version>\d{2}\.\d{3}\.\d{5}).*?</a>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    if ($matches.Count -eq 0) {
        throw "Could not find Continuous Track release links on Adobe release notes page."
    }

    $releases = foreach ($match in $matches) {
        $version = $match.Groups["version"].Value
        $href = $match.Groups["href"].Value

        [PSCustomObject]@{
            Version     = $version
            SortVersion = [version]$version
            Url         = Resolve-Url -BaseUrl $ReleaseNotesIndexUrl -Href $href
        }
    }

    $latest = $releases |
        Sort-Object SortVersion -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "Could not determine latest Adobe Continuous Track version."
    }

    Write-Log "Latest Adobe Continuous Track version detected: $($latest.Version)"
    Write-Log "Latest Adobe release page: $($latest.Url)"

    return $latest
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

function Get-AdobePatchUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$PatchFileName
    )

    Write-Log "Looking for patch file on Adobe release page: $PatchFileName"

    $response = Invoke-WebRequest -UseBasicParsing -Uri $ReleaseUrl

    $escapedFileName = [regex]::Escape($PatchFileName)

    try {
        $link = $response.Links |
            Where-Object { $_.href -match $escapedFileName } |
            Select-Object -First 1

        if ($link -and $link.href) {
            return Resolve-Url -BaseUrl $ReleaseUrl -Href $link.href
        }
    }
    catch {
        # Fall through to raw HTML parsing.
    }

    $hrefMatch = [regex]::Match(
        $response.Content,
        'href="(?<href>[^"]*' + $escapedFileName + '[^"]*)"',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($hrefMatch.Success) {
        return Resolve-Url -BaseUrl $ReleaseUrl -Href $hrefMatch.Groups["href"].Value
    }

    throw "Could not find patch file '$PatchFileName' on Adobe release page."
}

function Install-AdobePatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PatchPath
    )

    $msiLog = Join-Path $WorkingDirectory ("msiexec-" + [IO.Path]::GetFileNameWithoutExtension($PatchPath) + ".log")

    # /p applies the MSP patch.
    # /qn runs silently.
    # /norestart prevents surprise reboot.
    # /L*v creates a verbose MSI log.
    $arguments = "/p `"$PatchPath`" /qn /norestart /L*v `"$msiLog`""

    Write-Log "Running: msiexec.exe $arguments"

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru

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

Write-Log "Starting Adobe Acrobat/Reader update process."

$products = @(Get-InstalledAdobeAcrobatAdjacentProducts)

if ($products.Count -eq 0) {
    Write-Log "No Adobe Acrobat or Adobe Acrobat Reader products detected. Nothing to update."
    exit 0
}

Write-Log "Detected $($products.Count) Acrobat-adjacent product(s)."

foreach ($product in $products) {
    Write-Log "Detected product: $($product.DisplayName) | Version: $($product.DisplayVersion) | Type: $($product.ProductType) | Arch: $($product.Architecture) | Track: $($product.Track) | MUI detected: $($product.IsMUI)"
}

# Safety check: do not update while Adobe is running.
$runningAdobeProcesses = @(Get-RunningAdobeUserProcesses)

if ($runningAdobeProcesses.Count -gt 0) {
    Write-Log "Adobe Acrobat/Reader appears to be in use. Skipping update to avoid closing user documents."

    foreach ($process in $runningAdobeProcesses) {
        Write-Log "Running Adobe process detected: $($process.Name) | PID: $($process.ProcessId) | Session: $($process.SessionId) | Owner: $($process.Owner)"
    }

    Write-Log "Exiting without installing. ConnectWise can retry on the next scheduled run."
    exit 0
}

$latestRelease = Get-LatestAdobeContinuousRelease
$latestVersion = $latestRelease.Version

$overallExitCode = 0
$updatedSomething = $false

foreach ($product in $products) {
    Write-Log "Evaluating product: $($product.DisplayName)"

    if ($product.Track -eq "UnsupportedOrClassic") {
        Write-Log "Skipping '$($product.DisplayName)' because it appears to be Classic/2020/2024/legacy or otherwise unsupported by this Continuous Track MSP script."
        continue
    }

    if (-not [string]::IsNullOrWhiteSpace($product.DisplayVersion)) {
        $comparison = Compare-VersionSafe -InstalledVersion $product.DisplayVersion -LatestVersion $latestVersion

        if ($null -eq $comparison) {
            Write-Log "Could not compare installed version '$($product.DisplayVersion)' to latest '$latestVersion'. Continuing with update attempt."
        }
        elseif ($comparison -ge 0) {
            Write-Log "'$($product.DisplayName)' is already current or newer. Installed: $($product.DisplayVersion), latest: $latestVersion."
            continue
        }
        else {
            Write-Log "'$($product.DisplayName)' requires update. Installed: $($product.DisplayVersion), latest: $latestVersion."
        }
    }
    else {
        Write-Log "Installed version is missing for '$($product.DisplayName)'. Continuing with update attempt."
    }

    if ($product.ProductType -eq "Acrobat") {
        $candidatePatchFiles = @(
            Get-AcrobatPatchFileName -Architecture $product.Architecture -Version $latestVersion
        )
    }
    else {
        $candidatePatchFiles = @(
            Get-ReaderPatchFileNames `
                -Architecture $product.Architecture `
                -Version $latestVersion `
                -DetectedMUI ([bool]$product.IsMUI)
        )
    }

    $productUpdated = $false
    $lastExitCode = 0

    foreach ($patchFileName in $candidatePatchFiles) {
        Write-Log "Trying patch candidate for '$($product.DisplayName)': $patchFileName"

        try {
            $patchUrl = Get-AdobePatchUrl -ReleaseUrl $latestRelease.Url -PatchFileName $patchFileName
        }
        catch {
            Write-Log "Could not resolve patch URL for '$patchFileName': $($_.Exception.Message)"
            $lastExitCode = 1
            continue
        }

        $patchPath = Join-Path $WorkingDirectory $patchFileName

        try {
            Write-Log "Downloading patch: $patchUrl"
            Invoke-WebRequest -UseBasicParsing -Uri $patchUrl -OutFile $patchPath
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

        Write-Log "Patch downloaded successfully: $patchPath"

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
