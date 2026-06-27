<#
.SYNOPSIS
    Updates Microsoft Teams (new/v2) for AVD Gold Images.

.DESCRIPTION
    Downloads the latest Teams bootstrapper from Microsoft and provisions the
    latest Teams MSIX package for all users on the machine. This is the
    Microsoft-recommended approach for AVD/VDI environments.

    The teamsbootstrapper.exe handles:
    - Downloading the latest Teams MSIX from Microsoft
    - Installing/updating Teams for all users (per-machine provisioning)
    - Registry modifications for Office interoperability

    AVD customizations:
    - Disables Teams auto-update (disableAutoUpdate=1 registry key)
    - Removes desktop shortcuts

.PARAMETER SkipUpdate
    If specified, skips the download/install and only applies customizations.

.PARAMETER OfflineMsix
    Path to a local Teams MSIX file for offline installation. If not specified,
    the bootstrapper downloads the latest MSIX from Microsoft.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-MicrosoftTeams.ps1
    Updates Teams to the latest version using the online bootstrapper.

.EXAMPLE
    .\Update-MicrosoftTeams.ps1 -OfflineMsix "C:\Installers\MSTeams-x64.msix"
    Updates Teams using a local MSIX file (offline/bandwidth-saving mode).

.EXAMPLE
    .\Update-MicrosoftTeams.ps1 -SkipUpdate
    Only applies AVD customizations (disable auto-update, remove shortcuts).

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Requires: WebView2 Runtime, Delivery Optimization enabled.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$OfflineMsix,

    [string]$DownloadPath = "$env:TEMP\MicrosoftTeams",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Microsoft Teams"

# Microsoft's permanent download URLs
$BootstrapperUrl = "https://go.microsoft.com/fwlink/?linkid=2243204&clcid=0x409"
$BootstrapperFileName = "teamsbootstrapper.exe"

# Registry path for Teams auto-update policy
$TeamsRegPath = "HKLM:\SOFTWARE\Microsoft\Teams"

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "MicrosoftTeams-Install.log"
    Add-Content -Path $logFile -Value $entry
}

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = "DWord"
    )
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
    } catch {
        Write-Log "  Failed to set $Path\$Name : $($_.Exception.Message)" -Level WARN
    }
}

function Get-InstalledTeamsVersion {
    <#
    .SYNOPSIS
        Detects the installed Microsoft Teams (new/v2) MSIX package.
    #>
    try {
        $pkg = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq "MSTeams" } |
            Select-Object -First 1
        if ($pkg) {
            return [PSCustomObject]@{
                Version     = $pkg.Version
                PackageName = $pkg.PackageName
                Source      = "Provisioned"
            }
        }
    } catch {
        Write-Log "Could not query provisioned packages: $($_.Exception.Message)" -Level WARN
    }

    # Fallback: check installed Appx packages
    try {
        $pkg = Get-AppxPackage -AllUsers -Name "MSTeams" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($pkg) {
            return [PSCustomObject]@{
                Version     = $pkg.Version
                PackageName = $pkg.PackageFullName
                Source      = "AppxPackage"
            }
        }
    } catch {
        Write-Log "Could not query Appx packages: $($_.Exception.Message)" -Level WARN
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
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
    } catch {
        Write-Log "Download failed: $($_.Exception.Message)" -Level ERROR
        throw
    }

    if (-not (Test-Path $OutFile)) {
        throw "Download failed - file not found at $OutFile"
    }
    $size = (Get-Item $OutFile).Length / 1KB
    Write-Log "Download complete: $([math]::Round($size, 0)) KB"
}

function Install-Teams {
    param(
        [string]$BootstrapperPath,
        [string]$MsixPath
    )

    Write-Log "Provisioning Teams for all users via teamsbootstrapper..."

    # Close Teams if running
    $teamsProcs = Get-Process -Name "ms-teams" -ErrorAction SilentlyContinue
    if ($teamsProcs) {
        Write-Log "Closing Microsoft Teams..."
        $teamsProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    # Build arguments
    if ($MsixPath) {
        Write-Log "Using offline MSIX: $MsixPath"
        $arguments = "-p -o `"$MsixPath`""
    } else {
        Write-Log "Using online mode (bootstrapper will download latest MSIX)..."
        $arguments = "-p"
    }

    $process = Start-Process -FilePath $BootstrapperPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "Bootstrapper exit code: $($process.ExitCode) (0x$($process.ExitCode.ToString('X')))"

    if ($process.ExitCode -ne 0) {
        throw "$AppName provisioning failed with exit code $($process.ExitCode) (0x$($process.ExitCode.ToString('X'))). See https://learn.microsoft.com/windows/win32/seccrypto/common-hresult-values"
    }

    # Allow post-install settle time
    Write-Log "Waiting for post-install finalization..."
    Start-Sleep -Seconds 10

    return $process.ExitCode
}

function Set-TeamsAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for Microsoft Teams..."

    # -- Disable auto-updates (Microsoft-recommended for VDI gold images) --
    Set-RegistryValue -Path $TeamsRegPath -Name "disableAutoUpdate" -Value 1
    Write-Log "  disableAutoUpdate = 1"

    # -- Disable any Teams scheduled tasks --
    $tasks = Get-ScheduledTask -TaskName "*Teams*" -ErrorAction SilentlyContinue
    foreach ($task in $tasks) {
        try {
            if ($task.State -ne "Disabled") {
                $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null
                Write-Log "  Disabled scheduled task: $($task.TaskName)"
            } else {
                Write-Log "  Scheduled task already disabled: $($task.TaskName)"
            }
        } catch {
            Write-Log "  Failed to disable task '$($task.TaskName)': $($_.Exception.Message)" -Level WARN
        }
    }

    # -- Remove Desktop Shortcuts --
    $shortcuts = @(
        "$env:PUBLIC\Desktop\Microsoft Teams.lnk",
        "$env:PUBLIC\Desktop\Teams.lnk",
        "C:\Users\Default\Desktop\Microsoft Teams.lnk",
        "C:\Users\Default\Desktop\Teams.lnk"
    )
    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed shortcut: $shortcut"
        }
    }

    Write-Log "Microsoft Teams AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledTeamsVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Package:           $($installed.PackageName)"
        Write-Log "Source:            $($installed.Source)"
    } else {
        Write-Log "Microsoft Teams (new/v2) not currently detected."
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        if (-not (Test-Path $DownloadPath)) {
            New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
        }

        # Always download the latest bootstrapper (Microsoft recommends using the latest)
        $bootstrapperFile = Join-Path $DownloadPath $BootstrapperFileName
        Write-Log "Downloading latest Teams bootstrapper..."
        Start-FileDownload -Uri $BootstrapperUrl -OutFile $bootstrapperFile

        # Get bootstrapper version for logging
        $bsVersion = (Get-Item $bootstrapperFile).VersionInfo.ProductVersion
        Write-Log "Bootstrapper version: $bsVersion"

        $preVersion = if ($installed) { $installed.Version } else { "none" }

        # Run the bootstrapper
        if ($OfflineMsix) {
            if (-not (Test-Path $OfflineMsix)) {
                throw "Offline MSIX not found at: $OfflineMsix"
            }
            $exitCode = Install-Teams -BootstrapperPath $bootstrapperFile -MsixPath $OfflineMsix
        } else {
            $exitCode = Install-Teams -BootstrapperPath $bootstrapperFile
        }

        # Check post-install version
        $postInstall = Get-InstalledTeamsVersion
        if ($postInstall) {
            if ($postInstall.Version -ne $preVersion) {
                Write-Log "Updated: $preVersion -> $($postInstall.Version)"
            } else {
                Write-Log "Version unchanged after install: $($postInstall.Version)"
            }
        } else {
            Write-Log "Could not detect Teams after provisioning." -Level WARN
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    # Apply AVD customizations
    Write-Log "-----------------------------------------------------------------"
    Set-TeamsAVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledTeamsVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Version)"
    }

    # Verify auto-update disabled
    try {
        $regVal = Get-ItemProperty -Path $TeamsRegPath -Name "disableAutoUpdate" -ErrorAction Stop
        if ($regVal.disableAutoUpdate -eq 1) {
            Write-Log "Verified: disableAutoUpdate = 1"
        }
    } catch {
        Write-Log "Could not verify disableAutoUpdate registry value." -Level WARN
    }

    # Cleanup
    if (-not $KeepInstallers -and (Test-Path -LiteralPath $DownloadPath)) {
        # Use .NET Directory.Delete instead of Remove-Item: when $env:TEMP resolves to
        # an 8.3 short path (e.g. C:\Users\FNS~1.TEC\...), Remove-Item throws a terminating
        # PSArgumentException that -ErrorAction cannot suppress. The .NET API bypasses the
        # PowerShell provider and handles short paths correctly.
        try {
            [System.IO.Directory]::Delete($DownloadPath, $true)
            Write-Log "Cleaned up download directory."
        }
        catch {
            Write-Log "Could not remove download directory '$DownloadPath': $($_.Exception.Message)" -Level WARN
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
