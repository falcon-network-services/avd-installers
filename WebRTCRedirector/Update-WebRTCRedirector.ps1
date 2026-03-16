<#
.SYNOPSIS
    Updates the Remote Desktop WebRTC Redirector Service for AVD Gold Images.

.DESCRIPTION
    Downloads the latest Remote Desktop WebRTC Redirector Service MSI from
    Microsoft's permanent download link and installs it silently. This component
    provides media optimization for Teams on Azure Virtual Desktop.

    Note: With new Teams (v2) and SlimCore, the WebRTC Redirector acts as a
    fallback optimization path. Microsoft still recommends keeping it installed
    and updated on AVD session hosts.

    No auto-update mechanisms to disable - the WebRTC Redirector does not
    self-update. Updates must be applied manually or via deployment tools.

.PARAMETER SkipUpdate
    If specified, skips the download/install (detection only).

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-WebRTCRedirector.ps1
    Updates the WebRTC Redirector Service to the latest version.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\WebRTCRedirector",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Remote Desktop WebRTC Redirector Service"

# Microsoft's permanent download URL (always latest public release)
$DownloadUrl = "https://aka.ms/msrdcwebrtcsvc/msi"
$MsiFileName = "MsRdcWebRTCSvc_HostSetup_x64.msi"

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
    $logFile = Join-Path $LogPath "WebRTCRedirector-Install.log"
    Add-Content -Path $logFile -Value $entry
}

function Get-InstalledWebRTCVersion {
    <#
    .SYNOPSIS
        Detects the installed WebRTC Redirector Service from the registry.
    #>
    foreach ($regPath in $UninstallPaths) {
        if (-not (Test-Path $regPath)) { continue }

        $keys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            try {
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                $name = $null
                try { $name = $props.DisplayName } catch {}
                if (-not $name) { continue }

                if ($name -match 'Remote Desktop WebRTC Redirector') {
                    $version = $null
                    try { $version = $props.DisplayVersion } catch {}

                    return [PSCustomObject]@{
                        DisplayName    = $name
                        DisplayVersion = $version
                        UninstallKey   = $key.PSPath
                    }
                }
            } catch {
                # Skip keys that can't be read
            }
        }
    }
    return $null
}

function Start-FileDownload {
    param(
        [string]$Uri,
        [string]$OutFile
    )
    Write-Log "Downloading: $Uri"
    Write-Log "Destination: $OutFile"

    try {
        # aka.ms download URL uses redirects, so use Invoke-WebRequest directly
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
    } catch {
        Write-Log "Download failed: $($_.Exception.Message)" -Level ERROR
        throw
    }

    if (-not (Test-Path $OutFile)) {
        throw "Download failed - file not found at $OutFile"
    }
    $size = (Get-Item $OutFile).Length / 1MB
    Write-Log "Download complete: $([math]::Round($size, 1)) MB"

    # WebRTC Redirector MSI should be at least 1 MB
    if ($size -lt 1) {
        Write-Log "Downloaded file is only $([math]::Round($size, 1)) MB - expected >1 MB. File may be invalid." -Level ERROR
        throw "WebRTC Redirector MSI download appears invalid (too small: $([math]::Round($size, 1)) MB)"
    }
}

function Get-MsiProductVersion {
    param([string]$MsiPath)
    try {
        $windowsInstaller = New-Object -ComObject WindowsInstaller.Installer
        $database = $windowsInstaller.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $windowsInstaller, @($MsiPath, 0))
        $view = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $database, @("SELECT Value FROM Property WHERE Property='ProductVersion'"))
        $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null)
        $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)
        $version = $record.GetType().InvokeMember("StringData", "GetProperty", $null, $record, 1)
        $view.GetType().InvokeMember("Close", "InvokeMethod", $null, $view, $null)
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($windowsInstaller) | Out-Null
        return $version
    } catch {
        Write-Log "Could not read MSI version: $($_.Exception.Message)" -Level WARN
        return $null
    }
}

function Install-WebRTCRedirector {
    param([string]$MsiPath)

    Write-Log "Installing WebRTC Redirector Service from: $MsiPath"

    $msiLog = Join-Path $LogPath "WebRTCRedirector-MSI-Install.log"
    $arguments = "/i `"$MsiPath`" /qn /norestart /L*v `"$msiLog`""

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "MSI installer exit code: $($process.ExitCode)"

    if ($process.ExitCode -eq 1603) {
        Write-Log "Exit code 1603 - same version may already be installed, or install requires reboot." -Level WARN
    } elseif ($process.ExitCode -ne 0 -and $process.ExitCode -ne 1618 -and $process.ExitCode -ne 3010) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }
    return $process.ExitCode
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledWebRTCVersion
    if ($installed) {
        Write-Log "Installed: $($installed.DisplayName)"
        Write-Log "Version:   $($installed.DisplayVersion)"
    } else {
        Write-Log "WebRTC Redirector Service not currently installed."
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        if (-not (Test-Path $DownloadPath)) {
            New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
        }

        Write-Log "Downloading latest WebRTC Redirector Service MSI..."
        $msiFile = Join-Path $DownloadPath $MsiFileName
        Start-FileDownload -Uri $DownloadUrl -OutFile $msiFile

        # Read version from the downloaded MSI and compare before installing
        $msiVersion = $null
        try {
            $msiVersionRaw = Get-MsiProductVersion -MsiPath $msiFile
            if ($msiVersionRaw -and $msiVersionRaw -is [string]) {
                $msiVersion = $msiVersionRaw.Trim()
                Write-Log "Downloaded MSI version: $msiVersion"
            } else {
                Write-Log "Could not determine MSI version from file." -Level WARN
            }
        } catch {
            Write-Log "Error reading MSI version: $($_.Exception.Message)" -Level WARN
        }

        $installedVer = $null
        if ($installed -and $installed.DisplayVersion) {
            $installedVer = "$($installed.DisplayVersion)".Trim()
        }

        if ($installedVer -and $msiVersion -and $installedVer -eq $msiVersion) {
            Write-Log "Already at latest version: $installedVer. Skipping install."
        } else {
            $preVersion = if ($installed) { $installed.DisplayVersion } else { "none" }
            $exitCode = Install-WebRTCRedirector -MsiPath $msiFile

            # Check post-install version
            $postInstall = Get-InstalledWebRTCVersion
            if ($postInstall) {
                if ($postInstall.DisplayVersion -ne $preVersion) {
                    Write-Log "Updated: $preVersion -> $($postInstall.DisplayVersion)"
                } else {
                    Write-Log "Version unchanged after install: $($postInstall.DisplayVersion)"
                }
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledWebRTCVersion
    if ($finalVer) {
        Write-Log "Final: $($finalVer.DisplayName) - Version: $($finalVer.DisplayVersion)"
    }

    # Verify the service exists and is running
    try {
        $svc = Get-Service -Name "RDWebRTCSvc" -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Log "Service 'RDWebRTCSvc' status: $($svc.Status), StartType: $($svc.StartType)"
        } else {
            # Try alternate service name
            $svc = Get-Service -Name "MsRdcWebRTCSvc" -ErrorAction SilentlyContinue
            if ($svc) {
                Write-Log "Service 'MsRdcWebRTCSvc' status: $($svc.Status), StartType: $($svc.StartType)"
            } else {
                Write-Log "WebRTC Redirector service not found." -Level WARN
            }
        }
    } catch {
        Write-Log "Could not query WebRTC service status: $($_.Exception.Message)" -Level WARN
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
