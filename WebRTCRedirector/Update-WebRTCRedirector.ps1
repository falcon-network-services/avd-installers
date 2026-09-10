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

    Microsoft publishes this MSI behind a permanent redirect with no version API, so
    the ProductVersion is read from the downloaded package and compared against the
    installed version. Where that comparison is available and equal, no install is
    attempted: reinstalling the same package is what produces exit code 1603 on this
    MSI, and 1603 is a fatal installer error rather than an "already installed"
    signal. Where the version cannot be read and the component is already installed,
    the install is skipped rather than attempted blindly.

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

$ServiceNames = @("RDWebRTCSvc", "MsRdcWebRTCSvc")

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
                        DisplayVersion = if ($version) { "$version".Trim() } else { $null }
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
    <#
    .SYNOPSIS
        Reads ProductVersion from an MSI's Property table.
    .DESCRIPTION
        The WindowsInstaller COM API is invoked through InvokeMember because the
        interfaces are not exposed to PowerShell directly. Each InvokeMember call
        needs its arguments as an array, and every COM object created along the way
        is released in the finally block: a leaked database handle keeps a lock on
        the MSI file and makes the later cleanup of the download directory fail.
    #>
    param([string]$MsiPath)

    $installer = $null
    $database = $null
    $view = $null
    $record = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer

        # 0 = read-only open mode
        $database = $installer.GetType().InvokeMember(
            "OpenDatabase", "InvokeMethod", $null, $installer, @($MsiPath, 0))

        $query = "SELECT Value FROM Property WHERE Property = 'ProductVersion'"
        $view = $database.GetType().InvokeMember(
            "OpenView", "InvokeMethod", $null, $database, @($query))

        $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null) | Out-Null

        $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)
        if (-not $record) {
            Write-Log "The MSI Property table returned no ProductVersion row." -Level WARN
            return $null
        }

        $value = $record.GetType().InvokeMember(
            "StringData", "GetProperty", $null, $record, @(1))

        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            Write-Log "The MSI ProductVersion value is empty." -Level WARN
            return $null
        }

        return ([string]$value).Trim()
    } catch {
        Write-Log "Could not read the MSI ProductVersion: $($_.Exception.Message)" -Level WARN
        return $null
    } finally {
        foreach ($obj in @($record, $view, $database, $installer)) {
            if ($obj) {
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null } catch {}
            }
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

function Install-WebRTCRedirector {
    param([string]$MsiPath)

    Write-Log "Installing WebRTC Redirector Service from: $MsiPath"

    $msiLog = Join-Path $LogPath "WebRTCRedirector-MSI-Install.log"
    $arguments = "/i `"$MsiPath`" /qn /norestart /L*v `"$msiLog`""

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "MSI installer exit code: $($process.ExitCode)"

    # 3010 is success with a reboot required. 1618 is another install in progress and
    # is non-fatal, though nothing was installed. Everything else, 1603 included, is a
    # failure: 1603 means the installer aborted, and the verbose MSI log says why.
    if ($process.ExitCode -eq 1618) {
        Write-Log "Another installation is in progress (1618). The WebRTC Redirector was not installed on this run." -Level WARN
    } elseif ($process.ExitCode -notin @(0, 3010)) {
        throw "$AppName installation failed with exit code $($process.ExitCode). See the verbose MSI log at $msiLog"
    }

    return $process.ExitCode
}

function Test-WebRTCService {
    <#
    .SYNOPSIS
        Returns the WebRTC Redirector service under either of its known names.
    #>
    foreach ($name in $ServiceNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) { return $svc }
    }
    return $null
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
        $msiVersion = Get-MsiProductVersion -MsiPath $msiFile
        if ($msiVersion) {
            Write-Log "Downloaded MSI version: $msiVersion"
        }

        $installedVer = if ($installed) { $installed.DisplayVersion } else { $null }

        if ($installedVer -and $msiVersion -and $installedVer -eq $msiVersion) {
            Write-Log "Already at latest version: $installedVer. Skipping install."
        } elseif (-not $msiVersion -and $installedVer) {
            # Without a version to compare, reinstalling the same package is what
            # produces 1603 on this MSI. The installed component is left alone and the
            # run is flagged rather than gambling on a reinstall.
            Write-Log "Could not determine the MSI version, and version $installedVer is already installed. Skipping install; this run did not verify that the installed version is current." -Level WARN
        } else {
            $preVersion = if ($installed) { $installed.DisplayVersion } else { "none" }
            $exitCode = Install-WebRTCRedirector -MsiPath $msiFile

            $postInstall = Get-InstalledWebRTCVersion
            if (-not $postInstall) {
                throw "$AppName is not detected after an install that reported success. See the verbose MSI log in $LogPath"
            }
            if ($postInstall.DisplayVersion -ne $preVersion) {
                Write-Log "Updated: $preVersion -> $($postInstall.DisplayVersion)"
            } elseif ($exitCode -eq 1618) {
                # The installer never ran, so an unchanged version is expected here.
                Write-Log "Version unchanged: $($postInstall.DisplayVersion). No install was attempted (1618)." -Level WARN
            } else {
                throw "The installer reported success but the installed version is unchanged at $($postInstall.DisplayVersion). Expected $msiVersion."
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledWebRTCVersion
    if (-not $finalVer) {
        throw "$AppName is not installed at completion."
    }
    Write-Log "Final: $($finalVer.DisplayName) - Version: $($finalVer.DisplayVersion)"

    # Verify the service exists and is running. The redirector is a service component,
    # so an installed package with a dead service is not a working install.
    $svc = Test-WebRTCService
    if (-not $svc) {
        throw "The WebRTC Redirector service was not found under any of: $($ServiceNames -join ', ')"
    }
    Write-Log "Service '$($svc.Name)' status: $($svc.Status), StartType: $($svc.StartType)"
    if ($svc.Status -ne "Running") {
        Write-Log "Service '$($svc.Name)' is $($svc.Status). Starting it..." -Level WARN
        try {
            Start-Service -Name $svc.Name -ErrorAction Stop
            $svc = Test-WebRTCService
            Write-Log "Service '$($svc.Name)' status: $($svc.Status)"
        } catch {
            throw "Could not start the WebRTC Redirector service '$($svc.Name)': $($_.Exception.Message)"
        }
    }

    # Cleanup
    if (-not $KeepInstallers -and (Test-Path -LiteralPath $DownloadPath)) {
        # Use .NET Directory.Delete instead of Remove-Item: when $env:TEMP resolves to an
        # 8.3 short path (e.g. C:\Users\FNS~1.TEC\...), Remove-Item throws a terminating
        # PSArgumentException that -ErrorAction cannot suppress. The .NET API bypasses the
        # PowerShell provider and handles short paths correctly. Retry briefly in case an
        # installer process (e.g. msiexec) still holds a file lock right after install.
        $cleaned = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                [System.IO.Directory]::Delete($DownloadPath, $true)
                $cleaned = $true
                break
            }
            catch {
                if ($attempt -lt 3) {
                    Start-Sleep -Seconds 2
                }
                else {
                    Write-Log "Could not remove download directory '$DownloadPath': $($_.Exception.Message)" -Level WARN
                }
            }
        }
        if ($cleaned) {
            Write-Log "Cleaned up download directory."
        }
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
