# Run this in an elevated PowerShell (Run as Administrator)
 
$kbUrl  = "https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/fa84cc49-18b2-4c26-b389-90c96e6ae0d2/public/windows11.0-kb5054156-x64_a0c1638cbcf4cf33dbe9a5bef69db374b4786974.msu%22
$kbName = "windows11.0-kb5054156-x64.msu"
$downloadPath = Join-Path $env:TEMP $kbName
$logPath = Join-Path $env:TEMP "KB5054156_install.log"
 
Write-Host "Downloading KB5054156 to $downloadPath ..."
 
try {
    # Remove any previous copy
    if (Test-Path $downloadPath) {
        Remove-Item $downloadPath -Force
    }
 
    # Download the .msu file
    Invoke-WebRequest -Uri $kbUrl -OutFile $downloadPath
 
    Write-Host "Download complete. Starting installation..."
 
    # Install using wusa.exe with no automatic reboot
    $wusaArgs = "`"$downloadPath`" /quiet /norestart /log:$logPath"
 
    $process = Start-Process -FilePath "wusa.exe" -ArgumentList $wusaArgs -Wait -PassThru
 
    Write-Host "Installer exit code: $($process.ExitCode)"
 
    switch ($process.ExitCode) {
        0     { Write-Host "Installation completed successfully." }
        3010  { Write-Host "Installation succeeded and a reboot is REQUIRED, but was NOT forced. Reboot when convenient." }
        default { Write-Warning "Installation returned exit code $($process.ExitCode). Check the log at $logPath for details." }
    }
 
} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
} finally {
    if (Test-Path $downloadPath) {
        Write-Host "Deleting installer file..."
        Remove-Item $downloadPath -Force
    }
}
 
Write-Host "Done."
