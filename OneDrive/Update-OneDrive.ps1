<#
.SYNOPSIS
    Updates OneDrive and disables auto-update for AVD Gold Images.

.DESCRIPTION
    Downloads the latest OneDrive per-machine installer from Microsoft,
    installs it silently, then locks down auto-update mechanisms so OneDrive
    remains at the version baked into the Gold Image.

    Auto-update lockdown:
    - Disables OneDrive Updater Service
    - Disables OneDrive update scheduled tasks
    - Sets registry policy to prevent self-update
    - Configures OneDrive for AVD/VDI (silent sign-in, per-machine mode)

.PARAMETER TenantId
    Azure AD / Entra ID tenant ID for OneDrive Known Folder Move.
    If omitted, KFM silent opt-in is skipped.

.PARAMETER SkipUpdate
    If specified, skips the OneDrive update and only applies customizations.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-OneDrive.ps1
    Updates OneDrive to latest and disables auto-update.

.EXAMPLE
    .\Update-OneDrive.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Updates OneDrive and configures KFM for the specified tenant.

.EXAMPLE
    .\Update-OneDrive.ps1 -SkipUpdate
    Only applies AVD customizations without updating.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    OneDrive should be installed per-machine for AVD.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [string]$TenantId,

    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\OneDrive",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Microsoft OneDrive"

# Direct download URL for the latest OneDrive per-machine installer
$DownloadUrl = "https://go.microsoft.com/fwlink/?linkid=844652"
$InstallerFileName = "OneDriveSetup.exe"

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "OneDrive-Update.log"
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

function Get-InstalledOneDriveVersion {
    <#
    .SYNOPSIS
        Detects the installed OneDrive version (per-machine).
    #>
    $paths = @(
        "C:\Program Files\Microsoft OneDrive\OneDrive.exe",
        "C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $ver = (Get-Item $p).VersionInfo.ProductVersion
            return [PSCustomObject]@{
                Version = $ver
                Path    = $p
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
        # OneDrive download URL uses redirects, so use Invoke-WebRequest directly
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
    } catch {
        Write-Log "Download failed: $($_.Exception.Message)" -Level ERROR
        throw
    }

    if (-not (Test-Path $OutFile)) {
        throw "Download failed - file not found at $OutFile"
    }
    $size = (Get-Item $OutFile).Length / 1MB
    Write-Log "Download complete: $([math]::Round($size, 1)) MB"
}

function Install-OneDrive {
    param([string]$InstallerPath)

    Write-Log "Installing OneDrive from: $InstallerPath"

    # Close OneDrive if running
    $odProcs = Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue
    if ($odProcs) {
        Write-Log "Closing OneDrive..."
        $odProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    # /allusers installs per-machine, /silent suppresses UI
    $arguments = "/allusers /silent"

    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "Installer exit code: $($process.ExitCode)"

    # OneDrive installer can return 0 (success) or other codes
    if ($process.ExitCode -ne 0) {
        Write-Log "OneDrive installer returned exit code $($process.ExitCode) (may still be OK)." -Level WARN
    }

    # The installer may spawn a background process - give it time to finish
    Write-Log "Waiting for OneDrive installation to settle..."
    Start-Sleep -Seconds 15

    return $process.ExitCode
}

function Set-OneDriveAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for OneDrive..."

    $oneDrivePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive"

    # -- Disable OneDrive self-update --
    # GPOSetUpdateRing: 0 = Deferred, 4 = Production, 5 = Insider, 0 with EnableEnterpriseUpdate = 0 disables
    Set-RegistryValue -Path $oneDrivePolicyPath -Name "EnableEnterpriseUpdate" -Value 0

    # Prevent OneDrive from generating network traffic until the user signs in
    Set-RegistryValue -Path $oneDrivePolicyPath -Name "PreventNetworkTrafficPreUserSignIn" -Value 1

    # -- Silent account configuration --
    Set-RegistryValue -Path $oneDrivePolicyPath -Name "SilentAccountConfig" -Value 1

    # -- Known Folder Move (if TenantId provided) --
    if ($TenantId) {
        Set-RegistryValue -Path $oneDrivePolicyPath -Name "KFMSilentOptIn" -Value $TenantId -Type String
        Set-RegistryValue -Path $oneDrivePolicyPath -Name "KFMSilentOptInWithNotification" -Value 0
        Write-Log "OneDrive KFM configured for tenant: $TenantId"
    }

    # -- Files On-Demand (essential for VDI to save disk/profile space) --
    Set-RegistryValue -Path $oneDrivePolicyPath -Name "FilesOnDemandEnabled" -Value 1

    # -- Disable OneDrive Updater Service --
    try {
        $svc = Get-Service -Name "OneDrive Updater Service" -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service -Name "OneDrive Updater Service" -Force -ErrorAction Stop
            Set-Service -Name "OneDrive Updater Service" -StartupType Disabled -ErrorAction Stop
            Write-Log "OneDrive Updater Service stopped and set to Disabled."
        }
    } catch {
        Write-Log "Failed to disable OneDrive Updater Service: $($_.Exception.Message)" -Level WARN
    }

    # -- Disable OneDrive scheduled tasks --
    $tasks = Get-ScheduledTask -TaskName "*OneDrive*" -ErrorAction SilentlyContinue
    foreach ($task in $tasks) {
        # Only disable update-related tasks; leave startup tasks alone
        if ($task.TaskName -match "Update|Reporting") {
            try {
                if ($task.State -ne "Disabled") {
                    $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null
                    Write-Log "Disabled scheduled task: $($task.TaskName)"
                }
            } catch {
                Write-Log "Failed to disable task '$($task.TaskName)': $($_.Exception.Message)" -Level WARN
            }
        }
    }

    Write-Log "OneDrive AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledOneDriveVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.Path)"
    } else {
        Write-Log "OneDrive per-machine installation not detected." -Level WARN
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        # Resolve the redirect URL to extract the latest version without downloading
        $latestVersion = $null
        try {
            $headResponse = Invoke-WebRequest -Uri $DownloadUrl -Method Head -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
            $resolvedUrl = $headResponse.BaseResponse.ResponseUri.AbsoluteUri
            if (-not $resolvedUrl) {
                # PowerShell 7 uses RequestMessage.RequestUri instead
                $resolvedUrl = $headResponse.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
            }
            if ($resolvedUrl -match '/(\d+\.\d+\.\d+\.\d+)/') {
                $latestVersion = $Matches[1]
                Write-Log "Latest OneDrive version: $latestVersion"
            }
        } catch {
            Write-Log "Could not resolve latest version from URL: $($_.Exception.Message)" -Level WARN
        }

        # Skip download if already at latest version
        if ($installed -and $latestVersion -and $installed.Version -eq $latestVersion) {
            Write-Log "Already at latest version: $($installed.Version). Skipping download."
        } else {
            Write-Log "Downloading latest OneDrive installer..."

            if (-not (Test-Path $DownloadPath)) {
                New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
            }

            $installerFile = Join-Path $DownloadPath $InstallerFileName
            Start-FileDownload -Uri $DownloadUrl -OutFile $installerFile

            $preVersion = if ($installed) { $installed.Version } else { "none" }
            $exitCode = Install-OneDrive -InstallerPath $installerFile

            $postInstall = Get-InstalledOneDriveVersion
            if ($postInstall) {
                if ($postInstall.Version -ne $preVersion) {
                    Write-Log "Updated: $preVersion -> $($postInstall.Version)"
                } else {
                    Write-Log "Already at latest version: $($postInstall.Version)"
                }
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    # Apply AVD customizations
    Write-Log "-----------------------------------------------------------------"
    Set-OneDriveAVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledOneDriveVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Version)"
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
    Write-Log "$AppName update and customization completed successfully."
    Write-Log "================================================================="
    exit 0

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
