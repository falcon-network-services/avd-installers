<#
.SYNOPSIS
    Installs or updates PowerShell 7 for AVD Gold Images.

.DESCRIPTION
    Downloads the latest PowerShell 7 x64 MSI from the GitHub releases API,
    installs it silently, then disables update notifications so the version
    is locked to what's baked into the Gold Image.

    Customizations applied:
    - Sets POWERSHELL_UPDATECHECK=Off system environment variable
    - Installs without Microsoft Update opt-in (USE_MU=0, ENABLE_MU=0)
    - Adds Explorer context menu and PATH registration
    - Removes desktop shortcut

.PARAMETER SkipUpdate
    If specified, skips the download/install and only applies customizations.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Install-PowerShell7.ps1
    Updates PowerShell 7 to the latest version and disables update notifications.

.EXAMPLE
    .\Install-PowerShell7.ps1 -SkipUpdate
    Only disables update notifications and applies customizations.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    This script runs under Windows PowerShell 5.1 or PowerShell 7.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\PowerShell7",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "PowerShell 7"
$GitHubReleasesApi = "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"

$InstallPaths = @(
    "C:\Program Files\PowerShell\7",
    "C:\Program Files (x86)\PowerShell\7"
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
    $logFile = Join-Path $LogPath "PowerShell7-Install.log"
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

function Get-InstalledPwshVersion {
    <#
    .SYNOPSIS
        Detects the installed PowerShell 7 version by checking known install paths.
    #>
    foreach ($p in $InstallPaths) {
        $exe = Join-Path $p "pwsh.exe"
        if (Test-Path $exe) {
            # Use FileVersion (not ProductVersion which includes SHA hash)
            $ver = (Get-Item $exe).VersionInfo.FileVersion
            return [PSCustomObject]@{
                Version = $ver
                Path    = $p
                ExePath = $exe
            }
        }
    }
    return $null
}

function Get-LatestPwshRelease {
    <#
    .SYNOPSIS
        Queries the GitHub releases API for the latest PowerShell 7 release
        and returns the download URL for the Windows x64 MSI installer.
    #>
    Write-Log "Querying GitHub for latest PowerShell 7 release..."
    try {
        $headers = @{ "User-Agent" = "PowerShell-AVD-GoldImage" }
        $response = Invoke-WebRequest -Uri $GitHubReleasesApi -UseBasicParsing -Headers $headers -TimeoutSec 30
        $release = $response.Content | ConvertFrom-Json

        $tagName = $release.tag_name  # e.g., "v7.5.4"
        $version = $tagName -replace '^v', ''

        # Find the Windows x64 MSI asset (e.g., PowerShell-7.5.4-win-x64.msi)
        $asset = $release.assets | Where-Object {
            $_.name -match '-win-x64\.msi$'
        } | Select-Object -First 1

        if (-not $asset) {
            Write-Log "Could not find Windows x64 MSI asset in release." -Level WARN
            return $null
        }

        Write-Log "Latest PowerShell 7: $version"
        Write-Log "MSI asset: $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)"
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

function Get-NormalizedVersion {
    param([string]$Version)
    # Extract first 3 numeric segments for comparison (major.minor.patch)
    # FileVersion "7.5.4.500" -> "7.5.4", GitHub "7.5.4" stays "7.5.4"
    $Version = $Version -replace '-.*$', ''  # remove any pre-release tag
    if ($Version -match '^(\d+\.\d+\.\d+)') {
        return $Matches[1]
    }
    return $Version
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
    $size = (Get-Item $OutFile).Length / 1MB
    Write-Log "Download complete: $([math]::Round($size, 1)) MB"

    # PowerShell 7 MSI should be at least 90 MB
    if ($size -lt 90) {
        Write-Log "Downloaded file is only $([math]::Round($size, 1)) MB - expected >90 MB. File may be invalid." -Level ERROR
        throw "PowerShell 7 MSI download appears invalid (too small: $([math]::Round($size, 1)) MB)"
    }
}

function Install-Pwsh {
    param([string]$MsiPath)

    Write-Log "Installing PowerShell 7 from: $MsiPath"

    # Close PowerShell 7 processes if running (but not the current Windows PowerShell host)
    $pwshProcs = Get-Process -Name "pwsh" -ErrorAction SilentlyContinue
    if ($pwshProcs) {
        Write-Log "Closing PowerShell 7 processes..."
        $pwshProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    $msiLog = Join-Path $LogPath "PowerShell7-MSI-Install.log"

    # Install options:
    # ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 - Add "Open PowerShell" context menu
    # ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 - Add "Run with PowerShell" context menu
    # REGISTER_MANIFEST=1 - Register Windows Event Logging manifest
    # ADD_PATH=1 - Add to PATH
    # ENABLE_PSREMOTING=1 - Enable PS Remoting
    # USE_MU=0 - Do NOT opt into Microsoft Update (we manage updates via Gold Image)
    # ENABLE_MU=0 - Do NOT enable Microsoft Update auto-check
    $arguments = "/i `"$MsiPath`" /qn /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 REGISTER_MANIFEST=1 ADD_PATH=1 ENABLE_PSREMOTING=1 USE_MU=0 ENABLE_MU=0 /L*v `"$msiLog`""

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "MSI installer exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 1618 -and $process.ExitCode -ne 3010) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }
    return $process.ExitCode
}

function Set-PwshAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for PowerShell 7..."

    # -- Disable update notifications via system environment variable --
    # POWERSHELL_UPDATECHECK=Off prevents the GitHub API call on startup
    Set-RegistryValue -Path $EnvRegPath -Name "POWERSHELL_UPDATECHECK" -Value "Off" -Type String
    Write-Log "  POWERSHELL_UPDATECHECK = Off (system environment variable)"

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

    # -- Disable any PowerShell-related scheduled tasks for updates --
    $tasks = Get-ScheduledTask -TaskName "*PowerShell*" -ErrorAction SilentlyContinue
    foreach ($task in $tasks) {
        try {
            if ($task.State -ne "Disabled") {
                Disable-ScheduledTask -TaskName $task.TaskName -ErrorAction Stop | Out-Null
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
        "$env:PUBLIC\Desktop\PowerShell 7 (x64).lnk",
        "$env:PUBLIC\Desktop\PowerShell 7.lnk",
        "C:\Users\Default\Desktop\PowerShell 7 (x64).lnk",
        "C:\Users\Default\Desktop\PowerShell 7.lnk"
    )
    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed shortcut: $shortcut"
        }
    }

    Write-Log "PowerShell 7 AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Installer/Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledPwshVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.Path)"
    } else {
        Write-Log "PowerShell 7 not currently installed."
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $release = Get-LatestPwshRelease
        if (-not $release) {
            Write-Log "Could not resolve download URL. Skipping update, applying customizations only." -Level WARN
        } else {
            # Check if already at latest (normalize version segments for comparison)
            $installedNorm = if ($installed) { Get-NormalizedVersion $installed.Version } else { "" }
            $releaseNorm = Get-NormalizedVersion $release.Version
            if ($installed -and $installedNorm -eq $releaseNorm) {
                Write-Log "Already at latest version: $($installed.Version) (matches $($release.Version)). Skipping download."
            } else {
                Write-Log "Downloading PowerShell $($release.Version)..."

                if (-not (Test-Path $DownloadPath)) {
                    New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
                }

                $msiFile = Join-Path $DownloadPath $release.FileName
                Start-FileDownload -Uri $release.DownloadUrl -OutFile $msiFile

                $preVersion = if ($installed) { $installed.Version } else { "none" }
                $exitCode = Install-Pwsh -MsiPath $msiFile

                $postInstall = Get-InstalledPwshVersion
                if ($postInstall) {
                    if ($postInstall.Version -ne $preVersion) {
                        Write-Log "Updated: $preVersion -> $($postInstall.Version)"
                    } else {
                        Write-Log "Version unchanged after install: $($postInstall.Version)"
                    }
                }
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    # Apply AVD customizations
    Write-Log "-----------------------------------------------------------------"
    Set-PwshAVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledPwshVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Version)"
    }

    # Verify environment variable
    $envCheck = [System.Environment]::GetEnvironmentVariable("POWERSHELL_UPDATECHECK", "Machine")
    if ($envCheck -eq "Off") {
        Write-Log "Verified: POWERSHELL_UPDATECHECK = Off (Machine scope)"
    } else {
        Write-Log "WARNING: POWERSHELL_UPDATECHECK not set to Off at Machine scope." -Level WARN
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
