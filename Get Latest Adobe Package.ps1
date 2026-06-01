# Name: Update-AdobeAcrobatAdjacent.ps1
# Description:
#   Detects Adobe Acrobat / Adobe Acrobat Reader only, determines product and architecture,
#   downloads the latest matching Continuous Track MSP update from Adobe, and installs it silently.
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
# Timeout behavior:
#   - Adobe web requests have timeout/retry handling.
#   - If Adobe release notes time out, script uses a fallback version and direct MSP URLs.
#   - MSI installer execution has a maximum wait time.
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

# Adobe release notes source.
$ReleaseNotesIndexUrl = "https://www.adobe.com/devnet-docs/acrobatetk/tools/ReleaseNotesDC/index.html"

# Fallback values.
# Update these when Adobe publishes a newer Continuous Track release.
$FallbackAdobeVersion = "26.001.21563"
$FallbackAdobeReleaseUrl = "https://www.adobe.com/devnet-docs/acrobatetk/tools/ReleaseNotesDC/continuous/dccontinuousapr2026qfe2.html"
$DirectAdobeDownloadBaseUrl = "https://ardownload3.adobe.com/pub/adobe/acrobat/win/AcrobatDC"

$AdobeWebHeaders = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
    "Accept"     = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
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

function Invoke-AdobeWebRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [string]$OutFile
    )

    for ($attempt = 1; $attempt -le $WebRequestRetries; $attempt++) {
        try {
            Write-Log ("Web request attempt {0} of {1}: {2}" -f $attempt, $WebRequestRetries, $Uri)

            if ([string]::IsNullOrWhiteSpace($OutFile)) {
                return Invoke-WebRequest `
                    -UseBasicParsing `
                    -Uri $Uri `
                    -Headers $AdobeWebHeaders `
                    -TimeoutSec $WebRequestTimeoutSeconds `
                    -ErrorAction Stop
            }
            else {
                Invoke-WebRequest `
                    -UseBasicParsing `
                    -Uri $Uri `
                    -Headers $AdobeWebHeaders `
                    -TimeoutSec $WebRequestTimeoutSeconds `
                    -OutFile $OutFile `
                    -ErrorAction Stop

                return $true
            }
        }
        catch {
            Write-Log ("Web request failed on attempt {0} of {1}: {2}" -f $attempt, $WebRequestRetries, $_.Exception.Message)

            if ($attempt -lt $WebRequestRetries) {
                Write-Log "Waiting $WebRequestRetryDelaySeconds second(s) before retrying web request."
                Start-Sleep -Seconds $WebRequestRetryDelaySeconds
            }
        }
    }

    throw "Web request failed after $WebRequestRetries attempt(s): $Uri"
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

function Get-LatestAdobeContinuousRelease {
    Write-Log "Checking Adobe Continuous Track release notes."

    $response = Invoke-AdobeWebRequest -Uri $ReleaseNotesIndexUrl
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
            Version      = $version
            SortVersion  = [version]$version
            Url          = Resolve-Url -BaseUrl $ReleaseNotesIndexUrl -Href $href
            UsedFallback = $false
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

function Get-FallbackAdobeContinuousRelease {
    Write-Log "Using fallback Adobe Continuous Track version: $FallbackAdobeVersion"
    Write-Log "Fallback release page reference: $FallbackAdobeReleaseUrl"

    return [PSCustomObject]@{
        Version      = $FallbackAdobeVersion
        SortVersion  = [version]$FallbackAdobeVersion
        Url          = $FallbackAdobeReleaseUrl
        UsedFallback = $true
    }
}

function Get-DirectAdobePatchUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$PatchFileName
    )

    $versionNoDots = $Version.Replace(".", "")

    return "$DirectAdobeDownloadBaseUrl/$versionNoDots/$PatchFileName"
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
        [object]$Release,

        [Parameter(Mandatory = $true)]
        [string]$PatchFileName
    )

    $directUrl = Get-DirectAdobePatchUrl -Version $Release.Version -PatchFileName $PatchFileName

    if ($Release.UsedFallback) {
        Write-Log "Release notes lookup used fallback. Using direct Adobe download URL: $directUrl"
        return $directUrl
    }

    try {
        Write-Log "Looking for patch file on Adobe release page: $PatchFileName"

        $response = Invoke-AdobeWebRequest -Uri $Release.Url
        $escapedFileName = [regex]::Escape($PatchFileName)

        try {
            $link = $response.Links |
                Where-Object { $_.href -match $escapedFileName } |
                Select-Object -First 1

            if ($link -and $link.href) {
                $resolvedUrl = Resolve-Url -BaseUrl $Release.Url -Href $link.href
                Write-Log "Resolved patch URL from release page: $resolvedUrl"
                return $resolvedUrl
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
            $resolvedUrl = Resolve-Url -BaseUrl $Release.Url -Href $hrefMatch.Groups["href"].Value
            Write-Log "Resolved patch URL from release page HTML: $resolvedUrl"
            return $resolvedUrl
        }

        Write-Log "Could not find patch file '$PatchFileName' on release page. Falling back to direct URL: $directUrl"
        return $directUrl
    }
    catch {
        Write-Log "Could not query Adobe release page for '$PatchFileName': $($_.Exception.Message)"
        Write-Log "Falling back to direct Adobe download URL: $directUrl"
        return $directUrl
    }
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
    # If Acrobat.exe or AcroRd32.exe is open, skip.
    # If only helper/background Adobe processes are running, close them before patching.

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
    # Determine update version
    # =========================

    try {
        $latestRelease = Get-LatestAdobeContinuousRelease
    }
    catch {
        Write-Log "Could not retrieve Adobe Continuous Track release notes: $($_.Exception.Message)"
        Write-Log "Continuing with fallback version instead of failing the script."
        $latestRelease = Get-FallbackAdobeContinuousRelease
    }

    $latestVersion = $latestRelease.Version

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

            $patchUrl = Get-AdobePatchUrl -Release $latestRelease -PatchFileName $patchFileName
            $patchPath = Join-Path $WorkingDirectory $patchFileName

            try {
                Write-Log "Downloading patch: $patchUrl"
                Invoke-AdobeWebRequest -Uri $patchUrl -OutFile $patchPath
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
