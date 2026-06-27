<#
.SYNOPSIS
    Installs or updates Notepad++ for AVD Gold Images.

.DESCRIPTION
    Downloads the latest Notepad++ x64 installer from the GitHub releases API,
    installs it silently, then disables auto-update so the version is locked
    to what's baked into the Gold Image.

    Customizations applied:
    - Disables built-in auto-updater (config XML + removes updater plugin)
    - Removes desktop shortcut

.PARAMETER SkipUpdate
    If specified, skips the download/install and only applies customizations.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-NotepadPlusPlus.ps1
    Updates Notepad++ to the latest version and disables auto-update.

.EXAMPLE
    .\Update-NotepadPlusPlus.ps1 -SkipUpdate
    Only disables auto-update and applies customizations.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\NotepadPlusPlus",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Notepad++"
$GitHubReleasesApi = "https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest"

$InstallPaths = @(
    "C:\Program Files\Notepad++",
    "C:\Program Files (x86)\Notepad++"
)

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "NotepadPlusPlus-Install.log"
    Add-Content -Path $logFile -Value $entry
}

function Get-InstalledNppVersion {
    foreach ($p in $InstallPaths) {
        $exe = Join-Path $p "notepad++.exe"
        if (Test-Path $exe) {
            $ver = (Get-Item $exe).VersionInfo.ProductVersion
            return [PSCustomObject]@{
                Version     = $ver
                Path        = $p
                ExePath     = $exe
            }
        }
    }
    return $null
}

function Get-LatestNppRelease {
    <#
    .SYNOPSIS
        Queries the GitHub releases API for the latest Notepad++ release and
        returns the download URL for the x64 installer EXE.
    #>
    Write-Log "Querying GitHub for latest Notepad++ release..."
    try {
        $headers = @{ "User-Agent" = "PowerShell-AVD-GoldImage" }
        $response = Invoke-WebRequest -Uri $GitHubReleasesApi -UseBasicParsing -Headers $headers -TimeoutSec 30
        $release = $response.Content | ConvertFrom-Json

        $tagName = $release.tag_name  # e.g., "v8.7.7"
        $version = $tagName -replace '^v', ''

        # Find the x64 installer asset (e.g., npp.8.7.7.Installer.x64.exe)
        $asset = $release.assets | Where-Object {
            $_.name -match 'Installer\.x64\.exe$' -and $_.name -notmatch 'arm'
        } | Select-Object -First 1

        if (-not $asset) {
            Write-Log "Could not find x64 installer asset in release." -Level WARN
            return $null
        }

        Write-Log "Latest Notepad++: $version"
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

function Install-Npp {
    param([string]$InstallerPath)

    Write-Log "Installing Notepad++ from: $InstallerPath"

    # Close Notepad++ if running
    $nppProcs = Get-Process -Name "notepad++" -ErrorAction SilentlyContinue
    if ($nppProcs) {
        Write-Log "Closing Notepad++..."
        $nppProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # /S = silent, /D= sets install directory (must be last param, no quotes)
    $arguments = "/S"

    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "Installer exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }
    return $process.ExitCode
}

function Set-NppAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for Notepad++..."

    $installed = Get-InstalledNppVersion
    if (-not $installed) {
        Write-Log "Notepad++ not found - skipping customizations." -Level WARN
        return
    }

    $nppDir = $installed.Path

    # -- Disable auto-update via config XML --
    # Notepad++ checks an XML config for auto-update settings
    $configFile = Join-Path $nppDir "config.xml"
    $updaterDir = Join-Path $nppDir "updater"
    $gupdateExe = Join-Path $updaterDir "GUP.exe"

    # Method 1: Remove the GUP (Generic Updater Plugin) entirely
    if (Test-Path $gupdateExe) {
        try {
            Remove-Item -Path $gupdateExe -Force -ErrorAction Stop
            Write-Log "Removed GUP.exe (auto-updater)."
        } catch {
            Write-Log "Failed to remove GUP.exe: $($_.Exception.Message)" -Level WARN
        }
    }

    # Also remove the updater directory if empty or just has config
    if (Test-Path $updaterDir) {
        try {
            Remove-Item -Path $updaterDir -Recurse -Force -ErrorAction Stop
            Write-Log "Removed updater directory."
        } catch {
            Write-Log "Failed to remove updater directory: $($_.Exception.Message)" -Level WARN
        }
    }

    # Method 2: Set noUpdate in the config XML (belt and suspenders)
    # The config.xml may not exist until Notepad++ has been launched once.
    # We also need to set it in the default config that ships with the installer.
    $configFiles = @(
        (Join-Path $nppDir "config.xml"),
        (Join-Path $nppDir "config.model.xml")
    )

    foreach ($cfg in $configFiles) {
        if (Test-Path $cfg) {
            try {
                $content = Get-Content -Path $cfg -Raw -ErrorAction Stop
                if ($content -match 'nppUpdateState') {
                    # Replace existing noUpdate setting
                    $content = $content -replace 'nppUpdateState="[^"]*"', 'nppUpdateState="no"'
                } elseif ($content -match '<GUIConfig[^>]*name="noUpdate"') {
                    $content = $content -replace '(<GUIConfig[^>]*name="noUpdate"[^>]*>)[^<]*(</GUIConfig>)', '${1}no${2}'
                }
                Set-Content -Path $cfg -Value $content -Force -ErrorAction Stop
                Write-Log "Set auto-update to disabled in: $cfg"
            } catch {
                Write-Log "Failed to update config $cfg : $($_.Exception.Message)" -Level WARN
            }
        }
    }

    # -- Remove Desktop Shortcuts --
    $shortcuts = @(
        "$env:PUBLIC\Desktop\Notepad++.lnk",
        "C:\Users\Default\Desktop\Notepad++.lnk"
    )
    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "Removed shortcut: $shortcut"
        }
    }

    Write-Log "Notepad++ AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Installer/Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledNppVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.Path)"
    } else {
        Write-Log "Notepad++ not currently installed."
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $release = Get-LatestNppRelease
        if (-not $release) {
            Write-Log "Could not resolve download URL. Skipping update, applying customizations only." -Level WARN
        } else {
            # Check if already at latest
            if ($installed -and $installed.Version -eq $release.Version) {
                Write-Log "Already at latest version: $($installed.Version). Skipping download."
            } else {
                Write-Log "Downloading Notepad++ $($release.Version)..."

                if (-not (Test-Path $DownloadPath)) {
                    New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
                }

                $installerFile = Join-Path $DownloadPath $release.FileName
                Start-FileDownload -Uri $release.DownloadUrl -OutFile $installerFile

                $preVersion = if ($installed) { $installed.Version } else { "none" }
                $exitCode = Install-Npp -InstallerPath $installerFile

                $postInstall = Get-InstalledNppVersion
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
    Set-NppAVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledNppVersion
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
    Write-Log "$AppName installation/update completed successfully."
    Write-Log "================================================================="
    exit 0

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
