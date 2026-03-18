<#
.SYNOPSIS
    Installs or updates Bitwarden Desktop for AVD Gold Images.

.DESCRIPTION
    Downloads the latest Bitwarden Desktop installer from the GitHub releases API,
    installs it silently per-machine, then disables the Electron/Squirrel auto-update
    mechanism so Bitwarden remains at the version baked into the Gold Image.

    Auto-update lockdown:
    - Sets ELECTRON_NO_UPDATER=1 system environment variable
    - Removes desktop shortcuts

.PARAMETER SkipUpdate
    If specified, skips the download/install and only applies customizations.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-Bitwarden.ps1
    Updates Bitwarden to the latest version and disables auto-update.

.EXAMPLE
    .\Update-Bitwarden.ps1 -SkipUpdate
    Only disables auto-update and applies customizations.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\Bitwarden",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Bitwarden"

# GitHub releases API for the bitwarden/clients repo (desktop releases)
$GitHubReleasesApi = "https://api.github.com/repos/bitwarden/clients/releases"

$InstallPaths = @(
    "C:\Program Files\Bitwarden",
    "C:\Program Files (x86)\Bitwarden"
)

# System environment variable registry path
$EnvRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "Bitwarden-Install.log"
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

function Get-NormalizedVersion {
    param([string]$Version)
    # Trim trailing .0 segments so "2025.10.0.0" matches "2025.10.0"
    while ($Version -match '\.0$') {
        $Version = $Version -replace '\.0$', ''
    }
    return $Version
}

function Get-InstalledBitwardenVersion {
    <#
    .SYNOPSIS
        Detects the installed Bitwarden version by checking known install paths.
    #>
    foreach ($p in $InstallPaths) {
        $exe = Join-Path $p "Bitwarden.exe"
        if (Test-Path $exe) {
            $ver = (Get-Item $exe).VersionInfo.ProductVersion
            return [PSCustomObject]@{
                Version = $ver
                Path    = $p
                ExePath = $exe
            }
        }
    }
    return $null
}

function Get-LatestBitwardenRelease {
    <#
    .SYNOPSIS
        Queries the GitHub releases API for the latest Bitwarden desktop release
        and returns the download URL for the Windows installer EXE.
    #>
    Write-Log "Querying GitHub for latest Bitwarden desktop release..."
    try {
        $headers = @{ "User-Agent" = "PowerShell-AVD-GoldImage" }
        # Get recent releases and find the latest desktop release
        $response = Invoke-WebRequest -Uri $GitHubReleasesApi -UseBasicParsing -Headers $headers -TimeoutSec 30
        $releases = $response.Content | ConvertFrom-Json

        # Find the first release with a desktop tag (desktop-v*)
        $desktopRelease = $null
        foreach ($rel in $releases) {
            $tagName = $null
            try { $tagName = $rel.tag_name } catch {}
            if ($tagName -and $tagName -match '^desktop-v') {
                $desktopRelease = $rel
                break
            }
        }

        if (-not $desktopRelease) {
            Write-Log "Could not find a desktop release in GitHub API response." -Level WARN
            return $null
        }

        $tagName = $desktopRelease.tag_name  # e.g., "desktop-v2026.1.0"
        $version = $tagName -replace '^desktop-v', ''

        # Find the Windows installer asset (e.g., Bitwarden-Installer-2026.1.0.exe)
        $asset = $desktopRelease.assets | Where-Object {
            $_.name -match '^Bitwarden-Installer-.*\.exe$'
        } | Select-Object -First 1

        if (-not $asset) {
            Write-Log "Could not find Windows installer asset in release $tagName." -Level WARN
            return $null
        }

        Write-Log "Latest Bitwarden Desktop: $version"
        Write-Log "Installer asset: $($asset.name) ($([math]::Round($asset.size / 1KB, 0)) KB)"
        return [PSCustomObject]@{
            Version     = $version
            DownloadUrl = $asset.browser_download_url
            FileName    = $asset.name
            SizeBytes   = $asset.size
        }
    } catch {
        Write-Log "Failed to query GitHub releases: $($_.Exception.Message)" -Level WARN
        return $null
    }
}

function Start-FileDownload {
    param(
        [string]$Uri,
        [string]$OutFile
    )
    Write-Log "Downloading: $Uri"
    Write-Log "Destination: $OutFile"

    try {
        $headers = @{ "User-Agent" = "PowerShell-AVD-GoldImage" }
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers $headers -TimeoutSec 600
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

function Install-Bitwarden {
    param([string]$InstallerPath)

    Write-Log "Installing Bitwarden from: $InstallerPath"

    # Close Bitwarden if running
    $bwProcs = Get-Process -Name "Bitwarden" -ErrorAction SilentlyContinue
    if ($bwProcs) {
        Write-Log "Closing Bitwarden..."
        $bwProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    # /allusers = per-machine install to Program Files
    # /S = silent (NSIS flag)
    $arguments = "/allusers /S"

    # The NSIS stub installer downloads the full app, so allow extended time
    Write-Log "Running installer (this may take a few minutes as the stub downloads the full application)..."
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "Installer exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }

    # Allow post-install settle time (Squirrel unpacking)
    Write-Log "Waiting for post-install finalization..."
    Start-Sleep -Seconds 10

    return $process.ExitCode
}

function Set-BitwardenAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for Bitwarden..."

    # -- Disable Electron/Squirrel auto-updater via system environment variable --
    Set-RegistryValue -Path $EnvRegPath -Name "ELECTRON_NO_UPDATER" -Value "1" -Type String
    Write-Log "  ELECTRON_NO_UPDATER = 1 (system environment variable)"

    # Broadcast WM_SETTINGCHANGE so running processes pick up the new env var
    try {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
            [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
            public static extern IntPtr SendMessageTimeout(
                IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
                uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@ -ErrorAction SilentlyContinue

        $HWND_BROADCAST = [IntPtr]0xFFFF
        $WM_SETTINGCHANGE = 0x001A
        $result = [UIntPtr]::Zero
        [Win32.NativeMethods]::SendMessageTimeout(
            $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero,
            "Environment", 2, 5000, [ref]$result
        ) | Out-Null
        Write-Log "  Broadcast WM_SETTINGCHANGE for environment update."
    } catch {
        Write-Log "  Could not broadcast environment change: $($_.Exception.Message)" -Level WARN
    }

    # -- Disable any Bitwarden scheduled tasks --
    $tasks = Get-ScheduledTask -TaskName "*Bitwarden*" -ErrorAction SilentlyContinue
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

    # -- Disable any Bitwarden services --
    $services = Get-Service -Name "*Bitwarden*" -ErrorAction SilentlyContinue
    foreach ($svc in $services) {
        try {
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
            Write-Log "  Service '$($svc.Name)' stopped and set to Disabled."
        } catch {
            Write-Log "  Failed to disable service '$($svc.Name)': $($_.Exception.Message)" -Level WARN
        }
    }

    # -- Remove Desktop Shortcuts --
    $shortcuts = @(
        "$env:PUBLIC\Desktop\Bitwarden.lnk",
        "C:\Users\Default\Desktop\Bitwarden.lnk"
    )
    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed shortcut: $shortcut"
        }
    }

    Write-Log "Bitwarden AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Desktop Installer/Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledBitwardenVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.Path)"
    } else {
        Write-Log "Bitwarden not currently installed."
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $release = Get-LatestBitwardenRelease
        if (-not $release) {
            Write-Log "Could not resolve download URL. Skipping update, applying customizations only." -Level WARN
        } else {
            # Check if already at latest (normalize to handle 4-segment vs 3-segment mismatch)
            $releaseNorm = Get-NormalizedVersion $release.Version
            if ($installed) { $installedNorm = Get-NormalizedVersion $installed.Version } else { $installedNorm = "" }
            if ($installed -and $installedNorm -eq $releaseNorm) {
                Write-Log "Already at latest version: $($installed.Version) (matches $($release.Version)). Skipping download."
            } else {
                Write-Log "Downloading Bitwarden $($release.Version)..."

                if (-not (Test-Path $DownloadPath)) {
                    New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
                }

                $installerFile = Join-Path $DownloadPath $release.FileName
                Start-FileDownload -Uri $release.DownloadUrl -OutFile $installerFile

                $preVersion = if ($installed) { $installed.Version } else { "none" }
                $exitCode = Install-Bitwarden -InstallerPath $installerFile

                $postInstall = Get-InstalledBitwardenVersion
                if ($postInstall) {
                    if ($postInstall.Version -ne $preVersion) {
                        Write-Log "Updated: $preVersion -> $($postInstall.Version)"
                    } else {
                        Write-Log "Version unchanged after install: $($postInstall.Version)"
                    }
                } else {
                    Write-Log "Could not detect Bitwarden after install." -Level WARN
                }
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    # Apply AVD customizations
    Write-Log "-----------------------------------------------------------------"
    Set-BitwardenAVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledBitwardenVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Version)"
    }

    # Verify environment variable
    $envCheck = [System.Environment]::GetEnvironmentVariable("ELECTRON_NO_UPDATER", "Machine")
    if ($envCheck -eq "1") {
        Write-Log "Verified: ELECTRON_NO_UPDATER = 1 (Machine scope)"
    } else {
        Write-Log "WARNING: ELECTRON_NO_UPDATER not set at Machine scope." -Level WARN
    }

    # Cleanup
    if (-not $KeepInstallers -and (Test-Path $DownloadPath)) {
        Remove-Item -Path $DownloadPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned up download directory."
    }

    Write-Log "================================================================="
    Write-Log "$AppName installation/update completed successfully."
    Write-Log "================================================================="
    exit 0

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
