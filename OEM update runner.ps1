<#
ConnectWise RMM-safe OEM update runner
- Dell Command | Update
- Lenovo System Update
- HP Image Assistant

Paste directly into a ConnectWise RMM PowerShell script.
Run as System/Admin.
Do not enable auto reboot.
Recommended timeout: 120 minutes or higher.

Notes:
- Dell BIOS/Firmware are excluded by default.
- Lenovo reboot-required packages are excluded by default.
- HP BIOS/Firmware are excluded by default unless HPCategoryMode is set to All.
- Dell, Lenovo, and HP tools can be downloaded/installed automatically if missing.
- Lenovo history parsing is best-effort because Lenovo log/WMI output varies by System Update version.
- Lenovo artifact discovery inventories recent Lenovo-related files after TVSU runs.
- Lenovo key artifacts are copied into the RMM log folder for review.
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

$IncludeDellBiosFirmware = $false
$IncludeLenovoRebootPackages = $false

# Lenovo debug/history discovery settings
$EnableLenovoDebugLogging = $true
$LenovoArtifactLookbackMinutes = 15
$LenovoArtifactInventoryMaxItems = 300
$LenovoArtifactParseMaxDetailLines = 40

# If true, Dell will retry /applyUpdates without -updateType if Dell rejects all filtered attempts with exit code 107.
# Warning: unfiltered Dell apply may include BIOS/firmware updates. The script still uses -reboot=disable.
$AllowDellNoUpdateTypeFallback = $false

$VendorTimeoutMinutes = 120
$LenovoPostProcessWaitMinutes = 90

$WhatIfOnly = $false
$ReturnNonZeroOnVendorFailure = $false

$DellCommandUpdateInstallerUrl = "https://dl.dell.com/FOLDER14424601M/1/Dell-Command-Update-Windows-Universal-Application_FGK9X_WIN64_5.7.0_A00.EXE"
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

$global:LenovoToolFound = $false
$global:LenovoApplyRan = $false
$global:LenovoToolBootstrapped = $false
$global:LenovoLikelyNoApplicableUpdates = $false

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
    $copiedFiles = New-Object System.Collections.Generic.List[string]

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

    $samples = New-Object System.Collections.Generic.List[string]

    $taskListFile = @($Files |
        Where-Object { $_.FullName -match "(?i)\\UpdateTaskList\.xml$" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1)

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

        $taskLikeElements = @($childElements | Where-Object {
            $_.LocalName -match "(?i)task|update|package|install|driver|firmware|software|reboot|dependency"
        })

        $taskLikeElementCount = $taskLikeElements.Count

        foreach ($node in $taskLikeElements) {
            if ($samples.Count -ge $MaxSamples) {
                break
            }

            $sampleParts = New-Object System.Collections.Generic.List[string]
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

        if ($childElementCount -eq 0) {
            $isEmpty = $true
        }
        elseif ($taskLikeElementCount -eq 0 -and $sizeBytes -lt 2048) {
            $isEmpty = $true
        }
        else {
            $isEmpty = $false
        }

        if ($isEmpty) {
            $likelyNoApplicableUpdates = $true
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
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$DetailList,

        [Parameter(Mandatory = $true)]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$SourceFile,

        [Parameter(Mandatory = $true)]
        [string]$Line,

        [int]$MaxDetailLines = 40
    )

    if ($DetailList.Count -lt $MaxDetailLines) {
        [void]$DetailList.Add("${Type}: [$SourceFile] $Line")
    }
}

function Get-LenovoUpdateHistorySummary {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$RunStartTime,

        [int]$MaxDetailLines = 40
    )

    $detailLines = New-Object System.Collections.Generic.List[string]
    $logFilesReviewed = New-Object System.Collections.Generic.List[string]
    $wmiItems = New-Object System.Collections.Generic.List[string]

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
        "${env: = Get-ProgramFiles64

    return Get-FirstExistingPath -Paths @(
        "$pf64\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
    )
}

function Find-LenovoSystemUpdateCli {
    $pf64 = Get-ProgramFiles64

    return Get-FirstExistingPath -Paths @(
        "$pf64\Lenovo\System Update\Tvsu.exe",
        "${env:ProgramFiles(x86)}\Lenovo\System Update\Tvsu.exe"
    )
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

    $knownPaths = @(
        "$HPImageAssistantInstallDir\HPImageAssistant.exe",
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
            $global:DellToolBootstrapped = $true
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

        if ($IncludeLenovoRebootPackages) {
            $lenovoArgs += @("-includerebootpackages", "1,3,4", "-noreboot")
            Write-Log "IncludeLenovoRebootPackages enabled. Some Lenovo reboot package behavior is vendor controlled; reboot type 3 suppression does not mean every reboot type is suppressed." "WARN"
        }
        else {
            Write-Log "Lenovo reboot-required packages are excluded by default."
        }

        Write-Log "Running Lenovo System Update install step."

        $global:LenovoApplyRan = $true
        $lenovoRunStart = Get-Date

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

        $lenovoHistory = Get-LenovoUpdateHistorySummary `
            -RunStartTime $lenovoRunStart `
            -MaxDetailLines $LenovoArtifactParseMaxDetailLines

        $global:LenovoLikelyNoApplicableUpdates = [bool]$lenovoHistory.LikelyNoApplicableUpdates

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
        Write-Log "Lenovo likely no applicable non-reboot updates: $($lenovoHistory.LikelyNoApplicableUpdates)"

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
            Write-Log "Lenovo history parser found reboot/restart mentions. The script did not restart the endpoint." "WARN"
        }

        if ($lenovoHistory.LikelyNoApplicableUpdates -and $lenovoResult.ExitCode -eq 1) {
            Write-Log "Lenovo returned exit code 1, but UpdateTaskList appears empty and no Lenovo package failures were parsed. This likely means no applicable selected non-reboot updates." "WARN"
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
    Write-Log "Dell tool bootstrapped: $global:DellToolBootstrapped"
    Write-Log "Dell apply ran: $global:DellApplyRan"

    Write-Log "Lenovo tool found: $global:LenovoToolFound"
    Write-Log "Lenovo tool bootstrapped: $global:LenovoToolBootstrapped"
    Write-Log "Lenovo apply ran: $global:LenovoApplyRan"
    Write-Log "Lenovo likely no applicable non-reboot updates: $global:LenovoLikelyNoApplicableUpdates"

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

    Write-Log "Reboot required reported by vendor tool: $global:RebootRequired"
    Write-Log "Vendor warning detected: $global:HadVendorWarning"
    Write-Log "Vendor failure detected: $global:HadVendorFailure"
    Write-Log "OEM update run complete."

    Write-Output "OEMUPDATER_RESULT=Complete"
    Write-Output "OEMUPDATER_SUPPORTED_TOOL_FOUND=$global:SupportedToolFound"

    Write-Output "OEMUPDATER_DELL_TOOL_FOUND=$global:DellToolFound"
    Write-Output "OEMUPDATER_DELL_TOOL_BOOTSTRAPPED=$global:DellToolBootstrapped"
    Write-Output "OEMUPDATER_DELL_APPLY_RAN=$global:DellApplyRan"

    Write-Output "OEMUPDATER_LENOVO_TOOL_FOUND=$global:LenovoToolFound"
    Write-Output "OEMUPDATER_LENOVO_TOOL_BOOTSTRAPPED=$global:LenovoToolBootstrapped"
    Write-Output "OEMUPDATER_LENOVO_APPLY_RAN=$global:LenovoApplyRan"
    Write-Output "OEMUPDATER_LENOVO_LIKELY_NO_APPLICABLE_UPDATES=$global:LenovoLikelyNoApplicableUpdates"

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
