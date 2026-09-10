<#
.SYNOPSIS
    Installs or updates GitHub CLI for AVD Gold Images.

.DESCRIPTION
    Resolves the latest GitHub CLI release from the GitHub releases API, installs the
    x64 MSI machine-wide, then suppresses the CLI's update notifier so that the version
    baked into the Gold Image is the version users get.

.PARAMETER SkipUpdate
    If specified, skips the download and install and only applies customizations.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-GitHubCLI.ps1
    Updates GitHub CLI to the latest release.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Each user authenticates gh with their own account. No credentials are baked into
    the image.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\GitHubCLI",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "GitHub CLI"

$GitHubReleaseApi = "https://api.github.com/repos/cli/cli/releases/latest"

$GhExePath = Join-Path $env:ProgramFiles "GitHub CLI\gh.exe"

# System environment variable registry path
$EnvRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "GitHubCLI-Install.log"
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

function Send-EnvironmentChange {
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
}

function Get-InstalledGitHubCLIVersion {
    if (Test-Path $GhExePath) {
        $ver = (Get-Item $GhExePath).VersionInfo.ProductVersion
        if ($ver) { $ver = ($ver -split '\s+')[0].TrimStart("v") }
        return [PSCustomObject]@{
            Version = $ver
            ExePath = $GhExePath
        }
    }
    return $null
}

function Get-LatestGitHubCLIRelease {
    Write-Log "Querying GitHub for the latest GitHub CLI release..."
    try {
        $headers = @{ "User-Agent" = "PowerShell-AVD-GoldImage" }
        $release = Invoke-RestMethod -Uri $GitHubReleaseApi -UseBasicParsing -Headers $headers -TimeoutSec 60

        $version = $release.tag_name.TrimStart("v")

        $asset = $release.assets | Where-Object { $_.name -like "*windows_amd64.msi" } | Select-Object -First 1
        if (-not $asset) {
            Write-Log "Could not find a Windows x64 MSI asset in release $($release.tag_name)." -Level WARN
            return $null
        }

        Write-Log "Latest GitHub CLI: $version"
        Write-Log "Installer asset: $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)"
        return [PSCustomObject]@{
            Version     = $version
            DownloadUrl = $asset.browser_download_url
            FileName    = $asset.name
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
    $size = (Get-Item $OutFile).Length / 1MB
    Write-Log "Download complete: $([math]::Round($size, 1)) MB"
}

function Install-GitHubCLI {
    param([string]$InstallerPath)

    Write-Log "Installing GitHub CLI from: $InstallerPath"

    $arguments = @("/i", "`"$InstallerPath`"", "/qn", "/norestart")
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "MSI installer exit code: $($process.ExitCode)"

    # 3010 is success with a reboot required. 1618 is another install already in
    # progress and is treated as non-fatal.
    if ($process.ExitCode -eq 1618) {
        Write-Log "Another installation is in progress (1618). GitHub CLI was not installed on this run." -Level WARN
    } elseif ($process.ExitCode -notin @(0, 3010)) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }

    return $process.ExitCode
}

function Set-GitHubCLIAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for GitHub CLI..."

    # Suppress the "a new release of gh is available" notice, since users cannot
    # update a machine-wide install.
    Set-RegistryValue -Path $EnvRegPath -Name "GH_NO_UPDATE_NOTIFIER" -Value "1" -Type String
    Write-Log "  GH_NO_UPDATE_NOTIFIER = 1 (system environment variable)"

    Send-EnvironmentChange

    Write-Log "GitHub CLI AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Installer/Updater for AVD Gold Images"
    Write-Log "================================================================="

    $installed = Get-InstalledGitHubCLIVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.ExePath)"
    } else {
        Write-Log "GitHub CLI not currently installed."
    }

    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $release = Get-LatestGitHubCLIRelease
        if (-not $release) {
            # An unresolved download URL on a machine with no gh installed is a failed
            # run, not a partial one. Reporting success here would leave an image short
            # an application with nothing in the summary to show it.
            if (-not $installed) {
                throw "Could not resolve a GitHub CLI download URL and GitHub CLI is not installed."
            }
            Write-Log "Could not resolve download URL. Keeping the installed version $($installed.Version) and applying customizations only." -Level WARN
        } elseif ($installed -and $installed.Version -eq $release.Version) {
            Write-Log "Already at latest version: $($installed.Version). Skipping download."
        } else {
            Write-Log "Downloading GitHub CLI $($release.Version)..."

            if (-not (Test-Path $DownloadPath)) {
                New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
            }

            $installerFile = Join-Path $DownloadPath $release.FileName
            Start-FileDownload -Uri $release.DownloadUrl -OutFile $installerFile

            $preVersion = if ($installed) { $installed.Version } else { "none" }
            Install-GitHubCLI -InstallerPath $installerFile | Out-Null

            $postInstall = Get-InstalledGitHubCLIVersion
            if ($postInstall) {
                if ($postInstall.Version -ne $preVersion) {
                    Write-Log "Updated: $preVersion -> $($postInstall.Version)"
                } else {
                    Write-Log "Version unchanged after install: $($postInstall.Version)" -Level WARN
                }
            } else {
                throw "GitHub CLI was not detected after a successful install."
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    Write-Log "-----------------------------------------------------------------"
    Set-GitHubCLIAVDCustomizations

    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledGitHubCLIVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Version)"
    } else {
        throw "GitHub CLI is not installed at completion."
    }

    if (-not $KeepInstallers -and (Test-Path -LiteralPath $DownloadPath)) {
        # Use .NET Directory.Delete instead of Remove-Item: when $env:TEMP resolves to an
        # 8.3 short path (e.g. C:\Users\FNS~1.TEC\...), Remove-Item throws a terminating
        # PSArgumentException that -ErrorAction cannot suppress. Retry briefly in case
        # msiexec still holds a file lock right after install.
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
