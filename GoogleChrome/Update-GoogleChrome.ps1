<#
.SYNOPSIS
    Installs or updates Google Chrome Enterprise for AVD Gold Images.

.DESCRIPTION
    Downloads the latest Google Chrome Enterprise x64 MSI from Google's direct
    download endpoint, installs it silently, then disables all auto-update
    mechanisms so Chrome remains at the version baked into the Gold Image.

    Auto-update lockdown:
    - Disables gupdate and gupdatem services
    - Disables Google Update / Chrome scheduled tasks
    - Sets Google Update group policy to disable auto-updates
    - Disables background mode and telemetry
    - Removes desktop shortcuts

.PARAMETER SkipUpdate
    If specified, skips the download/install and only applies customizations.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-GoogleChrome.ps1
    Updates Chrome to the latest version and disables auto-update.

.EXAMPLE
    .\Update-GoogleChrome.ps1 -SkipUpdate
    Only disables auto-update and applies customizations.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\GoogleChrome",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Google Chrome"

# Google's direct enterprise MSI download URL (always latest stable x64)
$DownloadUrl = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
$MsiFileName = "googlechromestandaloneenterprise64.msi"

# Version history API for detecting latest version
$VersionApi = "https://versionhistory.googleapis.com/v1/chrome/platforms/win64/channels/stable/versions"

$ChromePaths = @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
)

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "GoogleChrome-Install.log"
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

function Get-InstalledChromeVersion {
    <#
    .SYNOPSIS
        Detects the installed Google Chrome version by checking known paths.
    #>
    foreach ($p in $ChromePaths) {
        if (Test-Path $p) {
            $ver = (Get-Item $p).VersionInfo.ProductVersion
            $dir = Split-Path (Split-Path $p)
            return [PSCustomObject]@{
                Version = $ver
                Path    = $dir
                ExePath = $p
            }
        }
    }
    return $null
}

function Get-LatestChromeVersion {
    <#
    .SYNOPSIS
        Queries Google's VersionHistory API for the latest Chrome stable version.
    #>
    Write-Log "Querying Google VersionHistory API for latest Chrome stable..."
    try {
        $response = Invoke-WebRequest -Uri $VersionApi -UseBasicParsing -TimeoutSec 30
        $data = $response.Content | ConvertFrom-Json

        $latestVersion = $null
        try { $latestVersion = $data.versions[0].version } catch {}

        if (-not $latestVersion) {
            Write-Log "Could not parse version from API response." -Level WARN
            return $null
        }

        # Validate version format (e.g., 145.0.7632.76)
        if ($latestVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            Write-Log "API returned unexpected version format: $latestVersion" -Level WARN
            return $null
        }

        Write-Log "Latest Chrome Stable: $latestVersion"
        return $latestVersion
    } catch {
        Write-Log "Failed to query VersionHistory API: $($_.Exception.Message)" -Level WARN
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
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $Uri -Destination $OutFile -Priority High -ErrorAction Stop
        } else {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
        }
    } catch {
        Write-Log "BITS failed, falling back to Invoke-WebRequest: $($_.Exception.Message)" -Level WARN
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
    }

    if (-not (Test-Path $OutFile)) {
        throw "Download failed - file not found at $OutFile"
    }
    $size = (Get-Item $OutFile).Length / 1MB
    Write-Log "Download complete: $([math]::Round($size, 1)) MB"

    # Chrome Enterprise MSI should be at least 70 MB
    if ($size -lt 70) {
        Write-Log "Downloaded file is only $([math]::Round($size, 1)) MB - expected >70 MB. File may be invalid." -Level ERROR
        throw "Chrome MSI download appears invalid (too small: $([math]::Round($size, 1)) MB)"
    }
}

function Test-ChromeMSIInstall {
    <#
    .SYNOPSIS
        Checks whether Chrome was installed via MSI (enterprise) by looking for an
        MsiExec uninstall string in the registry. Returns $true if MSI-based.
    #>
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($regPath in $uninstallPaths) {
        if (-not (Test-Path $regPath)) { continue }
        $keys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $name = $null; try { $name = $props.DisplayName } catch {}
            if ($name -match 'Google Chrome') {
                $uninstall = $null; try { $uninstall = $props.UninstallString } catch {}
                if ($uninstall -match 'MsiExec') { return $true }
                return $false
            }
        }
    }
    return $false
}

function Uninstall-Chrome {
    <#
    .SYNOPSIS
        Removes a non-MSI Chrome installation using Chrome's own setup.exe --uninstall.
    #>
    Write-Log "Removing existing non-MSI Chrome installation..."

    # Close Chrome and related processes
    $processNames = @("chrome", "GoogleUpdate", "GoogleCrashHandler", "GoogleCrashHandler64", "setup")
    foreach ($proc in $processNames) {
        Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    # Try using Chrome's own uninstaller (setup.exe --uninstall)
    $setupPaths = @(
        "C:\Program Files\Google\Chrome\Application\*\Installer\setup.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\*\Installer\setup.exe"
    )
    $setupExe = $setupPaths | ForEach-Object { Resolve-Path $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if ($setupExe) {
        Write-Log "Running Chrome uninstaller: $($setupExe.Path)"
        $process = Start-Process -FilePath $setupExe.Path -ArgumentList "--uninstall --force-uninstall --system-level" -Wait -PassThru -NoNewWindow
        Write-Log "Chrome uninstaller exit code: $($process.ExitCode)"
    }

    # Clean up remaining Chrome directories
    $chromeDirs = @(
        "C:\Program Files\Google\Chrome",
        "C:\Program Files (x86)\Google\Chrome"
    )
    foreach ($dir in $chromeDirs) {
        if (Test-Path $dir) {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed directory: $dir"
        }
    }
}

function Install-ChromeMSI {
    param([string]$MsiPath)

    Write-Log "Installing Chrome from: $MsiPath"

    # Close Chrome and related processes that can lock files and cause MSI 1603
    $processNames = @("chrome", "GoogleUpdate", "GoogleCrashHandler", "GoogleCrashHandler64", "setup")
    foreach ($proc in $processNames) {
        $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
        if ($running) {
            Write-Log "Closing $proc..."
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    # Stop Google Update services before install
    $services = @("gupdate", "gupdatem", "GoogleUpdaterService", "GoogleUpdaterInternalService")
    foreach ($svc in $services) {
        try {
            $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($service -and $service.Status -eq 'Running') {
                Stop-Service -Name $svc -Force -ErrorAction Stop
                Write-Log "Stopped service: $svc"
            }
        } catch {
            Write-Log "Could not stop service '$svc': $($_.Exception.Message)" -Level WARN
        }
    }

    Start-Sleep -Seconds 3

    $msiLog = Join-Path $LogPath "GoogleChrome-MSI-Install.log"
    $arguments = "/i `"$MsiPath`" /qn /norestart /L*v `"$msiLog`""

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "MSI installer exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 1618 -and $process.ExitCode -ne 3010) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }
    return $process.ExitCode
}

function Set-ChromeAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for Google Chrome..."

    # -- Google Update policies (disable auto-updates) --
    $googleUpdatePath = "HKLM:\SOFTWARE\Policies\Google\Update"

    # AutoUpdateCheckPeriodMinutes = 0 disables auto-update checks
    Set-RegistryValue -Path $googleUpdatePath -Name "AutoUpdateCheckPeriodMinutes" -Value 0
    Write-Log "  AutoUpdateCheckPeriodMinutes = 0"

    # UpdateDefault: 0 = Updates disabled
    Set-RegistryValue -Path $googleUpdatePath -Name "UpdateDefault" -Value 0
    Write-Log "  UpdateDefault = 0"

    # Specific override for Chrome Stable (Chrome GUID: {8A69D345-D564-463C-AFF1-A69D9E530F96})
    Set-RegistryValue -Path "$googleUpdatePath\Apps\{8A69D345-D564-463C-AFF1-A69D9E530F96}" -Name "Update" -Value 0
    Write-Log "  Chrome Stable Update = 0"

    # Disable update download (belt and suspenders)
    Set-RegistryValue -Path $googleUpdatePath -Name "DisableAutoUpdateChecksCheckboxValue" -Value 1
    Write-Log "  DisableAutoUpdateChecksCheckboxValue = 1"

    # -- Chrome browser policies --
    $chromePolicyPath = "HKLM:\SOFTWARE\Policies\Google\Chrome"

    # Disable background mode (Chrome running after close)
    Set-RegistryValue -Path $chromePolicyPath -Name "BackgroundModeEnabled" -Value 0
    Write-Log "  BackgroundModeEnabled = 0"

    # Disable metrics/telemetry reporting
    Set-RegistryValue -Path $chromePolicyPath -Name "MetricsReportingEnabled" -Value 0
    Write-Log "  MetricsReportingEnabled = 0"

    # Disable default browser check
    Set-RegistryValue -Path $chromePolicyPath -Name "DefaultBrowserSettingEnabled" -Value 0
    Write-Log "  DefaultBrowserSettingEnabled = 0"

    # Suppress first run experience / welcome page
    Set-RegistryValue -Path $chromePolicyPath -Name "SuppressFirstRunBubble" -Value 1
    Write-Log "  SuppressFirstRunBubble = 1"

    # Disable import dialog on first run
    Set-RegistryValue -Path $chromePolicyPath -Name "ImportAutofillFormData" -Value 0
    Write-Log "  ImportAutofillFormData = 0"

    # Disable Chrome sign-in prompts
    Set-RegistryValue -Path $chromePolicyPath -Name "BrowserSignin" -Value 0
    Write-Log "  BrowserSignin = 0 (disabled)"

    # Disable sync
    Set-RegistryValue -Path $chromePolicyPath -Name "SyncDisabled" -Value 1
    Write-Log "  SyncDisabled = 1"

    # Disable sending usage stats to Google
    Set-RegistryValue -Path $chromePolicyPath -Name "DeviceMetricsReportingEnabled" -Value 0
    Write-Log "  DeviceMetricsReportingEnabled = 0"

    # Disable startup boost (persistent background process)
    Set-RegistryValue -Path $chromePolicyPath -Name "StartupBoostEnabled" -Value 0
    Write-Log "  StartupBoostEnabled = 0"

    # Disable Chrome shopping features
    Set-RegistryValue -Path $chromePolicyPath -Name "ShoppingListEnabled" -Value 0
    Write-Log "  ShoppingListEnabled = 0"

    # Disable side panel companion (Gemini/AI)
    Set-RegistryValue -Path $chromePolicyPath -Name "GoogleSearchSidePanelEnabled" -Value 0
    Write-Log "  GoogleSearchSidePanelEnabled = 0"

    # Disable tab hover card previews (reduce resource usage in VDI)
    Set-RegistryValue -Path $chromePolicyPath -Name "TabHoverCardImagesEnabled" -Value 0
    Write-Log "  TabHoverCardImagesEnabled = 0"

    # -- Disable Google Update services --
    $services = @("gupdate", "gupdatem", "GoogleUpdaterService", "GoogleUpdaterInternalService")
    foreach ($svc in $services) {
        try {
            $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($service) {
                Stop-Service -Name $svc -Force -ErrorAction Stop
                Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
                Write-Log "  Service '$svc' stopped and set to Disabled."
            }
        } catch {
            Write-Log "  Failed to disable service '$svc': $($_.Exception.Message)" -Level WARN
        }
    }

    # -- Disable Google Update / Chrome scheduled tasks --
    $taskPatterns = @("*Google*", "*Chrome*")
    foreach ($pattern in $taskPatterns) {
        $tasks = Get-ScheduledTask -TaskName $pattern -ErrorAction SilentlyContinue
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
    }

    # -- Remove Desktop Shortcuts --
    $shortcuts = @(
        "$env:PUBLIC\Desktop\Google Chrome.lnk",
        "C:\Users\Default\Desktop\Google Chrome.lnk"
    )
    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed shortcut: $shortcut"
        }
    }

    Write-Log "Google Chrome AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Enterprise Installer/Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledChromeVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.Path)"
    } else {
        Write-Log "Google Chrome not currently installed."
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $latestVersion = Get-LatestChromeVersion
        if (-not $latestVersion) {
            Write-Log "Could not resolve latest version. Proceeding with download anyway." -Level WARN
        } else {
            # Compare versions if both available
            if ($installed -and $installed.Version -eq $latestVersion) {
                Write-Log "Already at latest version: $($installed.Version). Skipping download."
            }
        }

        # Download latest Chrome Enterprise MSI (skip if already at latest)
        $skipDownload = $installed -and $latestVersion -and $installed.Version -eq $latestVersion
        if (-not $skipDownload) {
            $versionLabel = if ($latestVersion) { $latestVersion } else { "latest" }
            Write-Log "Downloading Chrome Enterprise $versionLabel..."

            if (-not (Test-Path $DownloadPath)) {
                New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
            }

            $msiFile = Join-Path $DownloadPath $MsiFileName
            Start-FileDownload -Uri $DownloadUrl -OutFile $msiFile

            # If Chrome is installed but NOT via MSI, uninstall first so the enterprise MSI can install cleanly
            if ($installed -and -not (Test-ChromeMSIInstall)) {
                Write-Log "Existing Chrome was not installed via MSI (enterprise). Removing before MSI install..." -Level WARN
                Uninstall-Chrome
            }

            $preVersion = if ($installed) { $installed.Version } else { "none" }
            $exitCode = Install-ChromeMSI -MsiPath $msiFile

            $postInstall = Get-InstalledChromeVersion
            if ($postInstall) {
                if ($postInstall.Version -ne $preVersion) {
                    Write-Log "Updated: $preVersion -> $($postInstall.Version)"
                } else {
                    Write-Log "Version unchanged after install: $($postInstall.Version)"
                }
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    # Apply AVD customizations
    Write-Log "-----------------------------------------------------------------"
    Set-ChromeAVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledChromeVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Version)"
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
    Write-Log "$AppName installation/update completed successfully."
    Write-Log "================================================================="
    exit 0

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
