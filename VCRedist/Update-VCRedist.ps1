<#
.SYNOPSIS
    Updates Microsoft Visual C++ 2015-2022 Redistributable for AVD Gold Images.

.DESCRIPTION
    Downloads the latest Visual C++ 2015-2022 Redistributable installers (x64 and
    x86) from Microsoft's permanent download links and installs them silently.
    The installer handles in-place upgrades automatically.

    No auto-update mechanisms to disable - the VC++ Redistributable does not
    self-update. Updates are only delivered via Windows Update or manual install.

.PARAMETER SkipUpdate
    If specified, skips the download/install (detection only).

.PARAMETER x64Only
    If specified, only installs the x64 redistributable (skips x86).

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-VCRedist.ps1
    Updates both x64 and x86 VC++ Redistributables to the latest version.

.EXAMPLE
    .\Update-VCRedist.ps1 -x64Only
    Only updates the x64 VC++ Redistributable.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [switch]$x64Only,

    [string]$DownloadPath = "$env:TEMP\VCRedist",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Microsoft Visual C++ 2015-2022 Redistributable"

# Microsoft's permanent download URLs (always latest build)
$Downloads = @(
    [PSCustomObject]@{
        Architecture = "x64"
        Url          = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
        FileName     = "vc_redist.x64.exe"
    },
    [PSCustomObject]@{
        Architecture = "x86"
        Url          = "https://aka.ms/vs/17/release/vc_redist.x86.exe"
        FileName     = "vc_redist.x86.exe"
    }
)

# Registry uninstall key paths for detection
$UninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "VCRedist-Install.log"
    Add-Content -Path $logFile -Value $entry
}

function Get-InstalledVCRedist {
    <#
    .SYNOPSIS
        Detects installed Visual C++ 2015-2022 Redistributables from the registry.
        Returns an array of objects with DisplayName, DisplayVersion, and Architecture.
    #>
    $results = @()

    foreach ($regPath in $UninstallPaths) {
        if (-not (Test-Path $regPath)) { continue }

        $keys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            try {
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                $name = $null
                try { $name = $props.DisplayName } catch {}
                if (-not $name) { continue }

                # Match "Microsoft Visual C++ 2015-2022 Redistributable" entries
                if ($name -match 'Visual C\+\+.*2015-20(22|24|25|26).*Redistributable') {
                    $version = $null
                    try { $version = $props.DisplayVersion } catch {}

                    $arch = "unknown"
                    if ($name -match 'x64') { $arch = "x64" }
                    elseif ($name -match 'x86') { $arch = "x86" }

                    $results += [PSCustomObject]@{
                        DisplayName    = $name
                        DisplayVersion = $version
                        Architecture   = $arch
                    }
                }
            } catch {
                # Skip keys that can't be read
            }
        }
    }

    return $results
}

function Start-FileDownload {
    param(
        [string]$Uri,
        [string]$OutFile
    )
    Write-Log "Downloading: $Uri"
    Write-Log "Destination: $OutFile"

    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $Uri -Destination $OutFile -Priority High -ErrorAction Stop
        } else {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
        }
    } catch {
        Write-Log "BITS failed, falling back to Invoke-WebRequest: $($_.Exception.Message)" -Level WARN
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
    }

    if (-not (Test-Path $OutFile)) {
        throw "Download failed - file not found at $OutFile"
    }
    $size = (Get-Item $OutFile).Length / 1MB
    Write-Log "Download complete: $([math]::Round($size, 1)) MB"

    # VC++ Redist EXE should be at least 10 MB
    if ($size -lt 10) {
        Write-Log "Downloaded file is only $([math]::Round($size, 1)) MB - expected >10 MB. File may be invalid." -Level ERROR
        throw "VC++ Redistributable download appears invalid (too small: $([math]::Round($size, 1)) MB)"
    }
}

function Install-VCRedist {
    param(
        [string]$InstallerPath,
        [string]$Architecture
    )

    Write-Log "Installing VC++ Redistributable ($Architecture) from: $InstallerPath"

    $vcLog = Join-Path $LogPath "VCRedist-$Architecture-Install.log"
    $arguments = "/install /quiet /norestart /log `"$vcLog`""

    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "Installer exit code: $($process.ExitCode)"

    # Exit codes: 0 = success, 1638 = already installed (same or newer), 3010 = reboot needed
    if ($process.ExitCode -eq 0) {
        Write-Log "VC++ Redistributable ($Architecture) installed/updated successfully."
    } elseif ($process.ExitCode -eq 1638) {
        Write-Log "VC++ Redistributable ($Architecture) - same or newer version already installed."
    } elseif ($process.ExitCode -eq 3010) {
        Write-Log "VC++ Redistributable ($Architecture) installed. Reboot may be required." -Level WARN
    } else {
        throw "VC++ Redistributable ($Architecture) installation failed with exit code $($process.ExitCode)"
    }

    return $process.ExitCode
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installations
    $installed = Get-InstalledVCRedist
    if ($installed.Count -gt 0) {
        Write-Log "Currently installed VC++ Redistributables:"
        foreach ($vc in $installed) {
            Write-Log "  $($vc.DisplayName) - Version: $($vc.DisplayVersion)"
        }
    } else {
        Write-Log "No Visual C++ 2015-2022 Redistributable detected."
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        if (-not (Test-Path $DownloadPath)) {
            New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
        }

        $toInstall = if ($x64Only) { $Downloads | Where-Object { $_.Architecture -eq "x64" } } else { $Downloads }

        foreach ($pkg in $toInstall) {
            Write-Log "-----------------------------------------------------------------"
            Write-Log "Processing VC++ Redistributable ($($pkg.Architecture))..."

            # Check if installed version already matches latest before downloading
            $installedEntry = $installed | Where-Object { $_.Architecture -eq $pkg.Architecture } | Select-Object -First 1
            if ($installedEntry) {
                # Get the latest version number from the download URL's redirected file metadata
                # by downloading to temp and checking ProductVersion before running the installer
                $installerFile = Join-Path $DownloadPath $pkg.FileName
                Start-FileDownload -Uri $pkg.Url -OutFile $installerFile

                $downloadedVersion = (Get-Item $installerFile).VersionInfo.ProductVersion
                if ($downloadedVersion -and $installedEntry.DisplayVersion -and
                    $downloadedVersion -eq $installedEntry.DisplayVersion) {
                    Write-Log "Already at latest version: $downloadedVersion ($($pkg.Architecture)). Skipping install."
                    continue
                }
                Write-Log "Installed: $($installedEntry.DisplayVersion), Downloaded: $downloadedVersion"
                $exitCode = Install-VCRedist -InstallerPath $installerFile -Architecture $pkg.Architecture
            } else {
                $installerFile = Join-Path $DownloadPath $pkg.FileName
                Start-FileDownload -Uri $pkg.Url -OutFile $installerFile
                $exitCode = Install-VCRedist -InstallerPath $installerFile -Architecture $pkg.Architecture
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    Write-Log "Post-install verification:"
    $finalInstalled = Get-InstalledVCRedist
    if ($finalInstalled.Count -gt 0) {
        foreach ($vc in $finalInstalled) {
            Write-Log "  $($vc.DisplayName) - Version: $($vc.DisplayVersion)"
        }
    } else {
        Write-Log "WARNING: No VC++ Redistributable detected after install." -Level WARN
    }

    # Cleanup
    if (-not $KeepInstallers -and (Test-Path $DownloadPath)) {
        Remove-Item -Path $DownloadPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned up download directory."
    }

    Write-Log "================================================================="
    Write-Log "$AppName update completed successfully."
    Write-Log "================================================================="
    exit 0

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
