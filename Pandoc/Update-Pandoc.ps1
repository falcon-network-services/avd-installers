<#
.SYNOPSIS
    Installs or updates Pandoc for AVD Gold Images.

.DESCRIPTION
    Downloads the latest Pandoc x64 MSI installer from the GitHub releases API,
    installs it silently, and removes any desktop shortcuts.

    Pandoc is a command-line document converter with no auto-update mechanism,
    so no update-disabling customizations are required.

.PARAMETER SkipUpdate
    If specified, skips the download/install and only applies customizations.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.PARAMETER DownloadPath
    Directory for downloaded installer files. Defaults to $env:TEMP\Pandoc.

.EXAMPLE
    .\Update-Pandoc.ps1
    Installs or updates Pandoc to the latest version.

.EXAMPLE
    .\Update-Pandoc.ps1 -SkipUpdate
    Only applies customizations (desktop shortcut removal).

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\Pandoc",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Pandoc"
$GitHubReleasesApi = "https://api.github.com/repos/jgm/pandoc/releases/latest"

$InstallPaths = @(
    "C:\Program Files\Pandoc",
    "C:\Program Files (x86)\Pandoc"
)

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "Pandoc-Install.log"
    Add-Content -Path $logFile -Value $entry
}

function Get-InstalledPandocVersion {
    foreach ($p in $InstallPaths) {
        $exe = Join-Path $p "pandoc.exe"
        if (Test-Path $exe) {
            try {
                $output = & $exe --version 2>$null
                if ($output -and $output[0] -match 'pandoc\s+([\d.]+)') {
                    return [PSCustomObject]@{
                        Version = $Matches[1]
                        Path    = $p
                        ExePath = $exe
                    }
                }
            } catch {
                # Fall back to file version info
            }
            $ver = (Get-Item $exe).VersionInfo.ProductVersion
            if ($ver) {
                return [PSCustomObject]@{
                    Version = $ver
                    Path    = $p
                    ExePath = $exe
                }
            }
        }
    }
    return $null
}

function Get-LatestPandocRelease {
    <#
    .SYNOPSIS
        Queries the GitHub releases API for the latest Pandoc release and
        returns the download URL for the x64 MSI installer.
    #>
    Write-Log "Querying GitHub for latest Pandoc release..."
    try {
        $headers = @{ "User-Agent" = "PowerShell-AVD-GoldImage" }
        $response = Invoke-WebRequest -Uri $GitHubReleasesApi -UseBasicParsing -Headers $headers -TimeoutSec 30
        $release = $response.Content | ConvertFrom-Json

        $version = $release.tag_name

        # Find the x64 MSI installer asset (e.g., pandoc-3.9.0.2-x86_64.msi)
        $asset = $release.assets | Where-Object {
            $_.name -match '^pandoc-.*-x86_64\.msi$'
        } | Select-Object -First 1

        if (-not $asset) {
            Write-Log "Could not find x64 MSI installer asset in release." -Level WARN
            return $null
        }

        Write-Log "Latest Pandoc: $version"
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

    # Try BITS first, fall back to Invoke-WebRequest
    $useBits = $true
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Uri -Destination $OutFile -ErrorAction Stop
    } catch {
        Write-Log "BITS transfer failed, falling back to Invoke-WebRequest: $($_.Exception.Message)" -Level WARN
        $useBits = $false
    }

    if (-not $useBits) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
        } catch {
            Write-Log "Download failed: $($_.Exception.Message)" -Level ERROR
            throw
        }
    }

    if (-not (Test-Path $OutFile)) {
        throw "Download failed - file not found at $OutFile"
    }
    $size = (Get-Item $OutFile).Length / 1MB
    Write-Log "Download complete: $([math]::Round($size, 1)) MB"
}

function Install-Pandoc {
    param([string]$InstallerPath)

    Write-Log "Installing Pandoc from: $InstallerPath"

    $arguments = "/i `"$InstallerPath`" /quiet /norestart"

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "Installer exit code: $($process.ExitCode)"

    # 0 = success, 1618 = another install in progress, 3010 = reboot needed
    if ($process.ExitCode -notin @(0, 1618, 3010)) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }
    return $process.ExitCode
}

function Set-PandocAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for Pandoc..."

    $installed = Get-InstalledPandocVersion
    if (-not $installed) {
        Write-Log "Pandoc not found - skipping customizations." -Level WARN
        return
    }

    # Pandoc has no auto-update mechanism - only desktop shortcut cleanup needed.

    # -- Remove Desktop Shortcuts --
    $shortcuts = @(
        "$env:PUBLIC\Desktop\Pandoc.lnk",
        "C:\Users\Default\Desktop\Pandoc.lnk"
    )
    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "Removed shortcut: $shortcut"
        }
    }

    Write-Log "Pandoc AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Installer/Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledPandocVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.Path)"
    } else {
        Write-Log "Pandoc not currently installed."
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $release = Get-LatestPandocRelease
        if (-not $release) {
            Write-Log "Could not resolve download URL. Skipping update, applying customizations only." -Level WARN
        } else {
            # Check if already at latest
            if ($installed -and $installed.Version -eq $release.Version) {
                Write-Log "Already at latest version: $($installed.Version). Skipping download."
            } else {
                Write-Log "Downloading Pandoc $($release.Version)..."

                if (-not (Test-Path $DownloadPath)) {
                    New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
                }

                $installerFile = Join-Path $DownloadPath $release.FileName
                Start-FileDownload -Uri $release.DownloadUrl -OutFile $installerFile

                # Validate file size
                if ($release.SizeBytes -gt 0) {
                    $actualSize = (Get-Item $installerFile).Length
                    if ($actualSize -ne $release.SizeBytes) {
                        Write-Log "File size mismatch: expected $($release.SizeBytes) bytes, got $actualSize bytes" -Level WARN
                    }
                }

                $preVersion = if ($installed) { $installed.Version } else { "none" }
                $exitCode = Install-Pandoc -InstallerPath $installerFile

                $postInstall = Get-InstalledPandocVersion
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
    Set-PandocAVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledPandocVersion
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
