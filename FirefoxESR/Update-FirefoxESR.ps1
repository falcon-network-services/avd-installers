<#
.SYNOPSIS
    Installs or updates Mozilla Firefox ESR for AVD Gold Images.

.DESCRIPTION
    Downloads the latest Mozilla Firefox ESR x64 MSI installer from Mozilla's
    direct download endpoint, installs it silently, then disables all auto-update
    mechanisms so Firefox remains at the version baked into the Gold Image.

    Auto-update lockdown:
    - Disables Mozilla Maintenance Service
    - Disables Firefox update scheduled tasks (Background Update, Default Browser Agent)
    - Sets Firefox enterprise policies via registry to disable auto-updates
    - Disables telemetry, studies, and crash reporting
    - Removes desktop and taskbar shortcuts

.PARAMETER SkipUpdate
    If specified, skips the download/install and only applies customizations.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-FirefoxESR.ps1
    Updates Firefox ESR to the latest version and disables auto-update.

.EXAMPLE
    .\Update-FirefoxESR.ps1 -SkipUpdate
    Only disables auto-update and applies customizations.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\FirefoxESR",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Mozilla Firefox ESR"

# Mozilla product-details API for version info
$VersionApi = "https://product-details.mozilla.org/1.0/firefox_versions.json"

# Direct download URL for the latest Firefox ESR x64 MSI
$DownloadUrl = "https://download.mozilla.org/?product=firefox-esr-msi-latest-ssl&os=win64&lang=en-US"
$MsiFileName = "FirefoxESR-Latest-x64.msi"

$InstallPaths = @(
    "C:\Program Files\Mozilla Firefox",
    "C:\Program Files (x86)\Mozilla Firefox"
)

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "FirefoxESR-Install.log"
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

function Get-InstalledFirefoxVersion {
    <#
    .SYNOPSIS
        Detects the installed Firefox version by checking known install paths.
    #>
    foreach ($p in $InstallPaths) {
        $exe = Join-Path $p "firefox.exe"
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

function Get-LatestFirefoxESRVersion {
    <#
    .SYNOPSIS
        Queries Mozilla's product-details API for the latest Firefox ESR version.
    #>
    Write-Log "Querying Mozilla product-details API for latest ESR version..."
    try {
        $response = Invoke-WebRequest -Uri $VersionApi -UseBasicParsing -TimeoutSec 30
        $versions = $response.Content | ConvertFrom-Json

        # FIREFOX_ESR contains the current ESR version (e.g., "128.8.0esr")
        $esrVersion = $null
        try { $esrVersion = $versions.FIREFOX_ESR } catch {}

        if (-not $esrVersion) {
            Write-Log "Could not find FIREFOX_ESR in API response." -Level WARN
            return $null
        }

        # Clean the version string (remove "esr" suffix for comparison)
        $cleanVersion = $esrVersion -replace 'esr$', ''

        Write-Log "Latest Firefox ESR: $esrVersion (clean: $cleanVersion)"
        return [PSCustomObject]@{
            FullVersion  = $esrVersion
            CleanVersion = $cleanVersion
        }
    } catch {
        Write-Log "Failed to query Mozilla API: $($_.Exception.Message)" -Level WARN
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
        # Mozilla's download URL redirects, so BITS may not work well; use Invoke-WebRequest
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

    # Firefox ESR MSI should be at least 50 MB
    if ($size -lt 50) {
        Write-Log "Downloaded file is only $([math]::Round($size, 1)) MB - expected >50 MB. File may be invalid." -Level ERROR
        throw "Firefox ESR MSI download appears invalid (too small: $([math]::Round($size, 1)) MB)"
    }
}

function Install-FirefoxESR {
    param([string]$MsiPath)

    Write-Log "Installing Firefox ESR from: $MsiPath"

    # Close Firefox if running
    $ffProcs = Get-Process -Name "firefox" -ErrorAction SilentlyContinue
    if ($ffProcs) {
        Write-Log "Closing Firefox..."
        $ffProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    $msiLog = Join-Path $LogPath "FirefoxESR-MSI-Install.log"
    $arguments = "/i `"$MsiPath`" /qn /norestart INSTALL_MAINTENANCE_SERVICE=false TASKBAR_SHORTCUT=false DESKTOP_SHORTCUT=false /L*v `"$msiLog`""

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "MSI installer exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 1618 -and $process.ExitCode -ne 3010) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }
    return $process.ExitCode
}

function Set-FirefoxAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for Firefox ESR..."

    $firefoxPolicyPath = "HKLM:\SOFTWARE\Policies\Mozilla\Firefox"

    # -- Disable auto-updates --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "DisableAppUpdate" -Value 1
    Write-Log "  DisableAppUpdate = 1"

    # -- Disable telemetry --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "DisableTelemetry" -Value 1
    Write-Log "  DisableTelemetry = 1"

    # -- Disable Firefox Studies (Shield) --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "DisableFirefoxStudies" -Value 1
    Write-Log "  DisableFirefoxStudies = 1"

    # -- Disable Default Browser Agent --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "DisableDefaultBrowserAgent" -Value 1
    Write-Log "  DisableDefaultBrowserAgent = 1"

    # -- Disable crash reporting --
    Set-RegistryValue -Path "$firefoxPolicyPath\Preferences" -Name "datareporting.policy.dataSubmissionEnabled" -Value 0
    Write-Log "  datareporting.policy.dataSubmissionEnabled = 0 (locked)"

    # -- Override first run page (suppress welcome page) --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "OverrideFirstRunPage" -Value "" -Type String
    Write-Log "  OverrideFirstRunPage = (blank - suppressed)"

    # -- Override post-update page (suppress what's new page) --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "OverridePostUpdatePage" -Value "" -Type String
    Write-Log "  OverridePostUpdatePage = (blank - suppressed)"

    # -- Disable default browser check --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "DontCheckDefaultBrowser" -Value 1
    Write-Log "  DontCheckDefaultBrowser = 1"

    # -- Disable Pocket --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "DisablePocket" -Value 1
    Write-Log "  DisablePocket = 1"

    # -- Disable Firefox Accounts / Sync (optional but recommended for VDI) --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "DisableFirefoxAccounts" -Value 1
    Write-Log "  DisableFirefoxAccounts = 1"

    # -- Disable feedback reporting --
    Set-RegistryValue -Path $firefoxPolicyPath -Name "DisableFeedbackCommands" -Value 1
    Write-Log "  DisableFeedbackCommands = 1"

    # -- Disable Mozilla Maintenance Service --
    try {
        $svc = Get-Service -Name "MozillaMaintenance" -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service -Name "MozillaMaintenance" -Force -ErrorAction Stop
            Set-Service -Name "MozillaMaintenance" -StartupType Disabled -ErrorAction Stop
            Write-Log "  MozillaMaintenance service stopped and set to Disabled."
        } else {
            Write-Log "  MozillaMaintenance service not found (not installed)."
        }
    } catch {
        Write-Log "  Failed to disable MozillaMaintenance service: $($_.Exception.Message)" -Level WARN
    }

    # -- Disable Firefox scheduled tasks --
    $taskPatterns = @("*Firefox*", "*Mozilla*")
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
        "$env:PUBLIC\Desktop\Firefox.lnk",
        "$env:PUBLIC\Desktop\Mozilla Firefox.lnk",
        "C:\Users\Default\Desktop\Firefox.lnk",
        "C:\Users\Default\Desktop\Mozilla Firefox.lnk"
    )
    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed shortcut: $shortcut"
        }
    }

    # -- Remove Taskbar Pin (if present) --
    $taskbarShortcuts = @(
        "$env:PUBLIC\AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Firefox.lnk",
        "$env:PUBLIC\AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Mozilla Firefox.lnk"
    )
    foreach ($shortcut in $taskbarShortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed taskbar shortcut: $shortcut"
        }
    }

    Write-Log "Firefox ESR AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Installer/Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledFirefoxVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.Path)"
    } else {
        Write-Log "Firefox not currently installed."
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $latestESR = Get-LatestFirefoxESRVersion
        if (-not $latestESR) {
            Write-Log "Could not resolve latest ESR version. Proceeding with download anyway." -Level WARN
        } else {
            # Compare versions if we have both
            if ($installed -and $installed.Version -eq $latestESR.CleanVersion) {
                Write-Log "Already at latest ESR version: $($installed.Version). Skipping download."
            }
        }

        # Download and install latest ESR MSI (skip if already at latest)
        $skipDownload = $installed -and $latestESR -and $installed.Version -eq $latestESR.CleanVersion
        if (-not $skipDownload) {
            $versionLabel = if ($latestESR) { $latestESR.FullVersion } else { "latest" }
            Write-Log "Downloading Firefox ESR $versionLabel..."

            if (-not (Test-Path $DownloadPath)) {
                New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
            }

            $msiFile = Join-Path $DownloadPath $MsiFileName
            Start-FileDownload -Uri $DownloadUrl -OutFile $msiFile

            $preVersion = if ($installed) { $installed.Version } else { "none" }
            $exitCode = Install-FirefoxESR -MsiPath $msiFile

            $postInstall = Get-InstalledFirefoxVersion
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
    Set-FirefoxAVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledFirefoxVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Version)"
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
