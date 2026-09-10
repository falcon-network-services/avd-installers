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

    Version handling: the published download link serves the Production ring build,
    which can be older than the OneDrive shipped in a current Windows multi-session
    Marketplace image. Versions are therefore compared numerically and the install is
    skipped when the installed build is the same or newer. An equality-only check
    downloads and runs an installer that then declines to downgrade, which looks like
    a successful update but changes nothing.

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
                Version = if ($ver) { "$ver".Trim() } else { $null }
                Path    = $p
            }
        }
    }
    return $null
}

function Compare-OneDriveVersion {
    <#
    .SYNOPSIS
        Compares two OneDrive version strings numerically.
    .DESCRIPTION
        Returns -1 when Installed is older, 0 when equal, 1 when Installed is newer,
        and $null when either value cannot be parsed. String comparison is not usable
        here: OneDrive build segments are zero-padded, so "26.153.0809.0004" sorts
        before "26.150.0804.0011" as text while being the newer build.
    #>
    param(
        [string]$Installed,
        [string]$Candidate
    )

    try {
        $a = [version]$Installed
        $b = [version]$Candidate
    } catch {
        Write-Log "Could not parse versions for comparison ('$Installed' and '$Candidate'): $($_.Exception.Message)" -Level WARN
        return $null
    }

    return $a.CompareTo($b)
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

function Get-LatestOneDriveVersion {
    <#
    .SYNOPSIS
        Resolves the download redirect to read the published version from its URL,
        without downloading the installer.
    #>
    try {
        $headResponse = Invoke-WebRequest -Uri $DownloadUrl -Method Head -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop

        $resolvedUrl = $null
        try { $resolvedUrl = $headResponse.BaseResponse.ResponseUri.AbsoluteUri } catch {}
        if (-not $resolvedUrl) {
            # PowerShell 7 exposes the final URI on the request message instead
            try { $resolvedUrl = $headResponse.BaseResponse.RequestMessage.RequestUri.AbsoluteUri } catch {}
        }

        if (-not $resolvedUrl) {
            Write-Log "Could not read the resolved download URL from the response." -Level WARN
            return $null
        }

        if ($resolvedUrl -match '/(\d+\.\d+\.\d+\.\d+)/') {
            return $Matches[1]
        }

        Write-Log "No version found in the resolved download URL: $resolvedUrl" -Level WARN
        return $null
    } catch {
        Write-Log "Could not resolve the latest version from the download URL: $($_.Exception.Message)" -Level WARN
        return $null
    }
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

    # A non-zero exit code is a failure. OneDriveSetup.exe returns 0 on a successful
    # per-machine install, so anything else means the install did not complete.
    if ($process.ExitCode -ne 0) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
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

    $installAttempted = $false

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $latestVersion = Get-LatestOneDriveVersion
        if ($latestVersion) {
            Write-Log "Published OneDrive version: $latestVersion"
        }

        # Decide whether an install is needed. The published build can be older than
        # the build shipped in the OS image, so compare numerically rather than for
        # equality alone.
        $needsInstall = $true
        $skipReason = $null

        if (-not $installed) {
            $needsInstall = $true
        } elseif (-not $latestVersion) {
            $needsInstall = $false
            $skipReason = "Could not determine the published version. Keeping the installed version $($installed.Version); this run did not verify that it is current."
        } else {
            $comparison = Compare-OneDriveVersion -Installed $installed.Version -Candidate $latestVersion
            if ($null -eq $comparison) {
                $needsInstall = $true
            } elseif ($comparison -eq 0) {
                $needsInstall = $false
                $skipReason = "Already at the published version: $($installed.Version). Skipping download."
            } elseif ($comparison -gt 0) {
                $needsInstall = $false
                $skipReason = "Installed version $($installed.Version) is newer than the published version $latestVersion. The download link serves the Production ring, which trails the build shipped in current Windows images. Skipping download."
            }
        }

        if (-not $needsInstall) {
            if ($skipReason -match 'did not verify') {
                Write-Log $skipReason -Level WARN
            } else {
                Write-Log $skipReason
            }
        } else {
            Write-Log "Downloading latest OneDrive installer..."

            if (-not (Test-Path $DownloadPath)) {
                New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
            }

            $installerFile = Join-Path $DownloadPath $InstallerFileName
            Start-FileDownload -Uri $DownloadUrl -OutFile $installerFile

            $preVersion = if ($installed) { $installed.Version } else { "none" }
            $installAttempted = $true
            Install-OneDrive -InstallerPath $installerFile | Out-Null

            $postInstall = Get-InstalledOneDriveVersion
            if (-not $postInstall) {
                throw "$AppName is not detected after an install that reported success."
            }
            if ($postInstall.Version -ne $preVersion) {
                Write-Log "Updated: $preVersion -> $($postInstall.Version)"
            } else {
                throw "The installer reported success but the installed version is unchanged at $($postInstall.Version). Expected $latestVersion."
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
    } elseif ($installAttempted) {
        throw "$AppName is not installed at completion."
    } else {
        Write-Log "No per-machine OneDrive installation detected at completion. Customizations were applied and will take effect once OneDrive is installed per-machine." -Level WARN
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
    Write-Log "$AppName update and customization completed successfully."
    Write-Log "================================================================="
    exit 0

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
