<#
.SYNOPSIS
    Installs or updates Git for Windows for AVD Gold Images.

.DESCRIPTION
    Resolves the latest Git for Windows release from the GitHub releases API and
    installs the 64-bit Inno Setup package silently, machine-wide, with a fixed
    component set. The auto-updater component is excluded so that the version baked
    into the Gold Image is the version users get.

    Git is installed on the image because it is a prerequisite for repository work in
    Claude Code and for GitHub CLI operations that act on a working tree. User identity
    and credentials are per-user and are not configured here.

.PARAMETER SkipUpdate
    If specified, skips the download and install and only applies customizations.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-Git.ps1
    Updates Git for Windows to the latest release.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\Git",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Git for Windows"

$GitHubReleaseApi = "https://api.github.com/repos/git-for-windows/git/releases/latest"

$GitExePath = Join-Path $env:ProgramFiles "Git\cmd\git.exe"

# Inno Setup silent install arguments.
# Components: git-lfs and shell integration, without the auto-updater. Anything not
# listed is not installed, so the component list is the full set.
$InstallComponents = "gitlfs,assoc,assoc_sh,windowsterminal"
$InstallArguments = "/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES /COMPONENTS=`"$InstallComponents`""

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "Git-Install.log"
    Add-Content -Path $logFile -Value $entry
}

function Get-InstalledGitVersion {
    <#
    .SYNOPSIS
        Returns the installed Git version as major.minor.patch. Parsed from git.exe
        output rather than file version metadata, which reports a Windows-specific
        build suffix that does not compare cleanly against release asset names.
    #>
    if (Test-Path $GitExePath) {
        try {
            $output = & $GitExePath --version 2>$null
            # "git version 2.55.0.windows.5" -> 2.55.0.5, "…windows.1" -> 2.55.0.
            # This matches how release assets are named, so the two compare directly.
            if ($output -match 'git version (\d+\.\d+\.\d+)(?:\.windows\.(\d+))?') {
                $base = $Matches[1]
                $revision = $Matches[2]
                if ($revision -and $revision -ne "1") {
                    $normalized = "$base.$revision"
                } else {
                    $normalized = $base
                }
                return [PSCustomObject]@{
                    Version = $normalized
                    Raw     = ($output -replace '^git version ', '')
                    ExePath = $GitExePath
                }
            }
            Write-Log "Could not parse the version from git.exe output: $output" -Level WARN
        } catch {
            Write-Log "Could not run git.exe: $($_.Exception.Message)" -Level WARN
        }
    }
    return $null
}

function Get-LatestGitRelease {
    Write-Log "Querying GitHub for the latest Git for Windows release..."
    try {
        $headers = @{ "User-Agent" = "PowerShell-AVD-GoldImage" }
        $release = Invoke-RestMethod -Uri $GitHubReleaseApi -UseBasicParsing -Headers $headers -TimeoutSec 60

        # Asset names take the form Git-2.51.0-64-bit.exe, or Git-2.55.0.5-64-bit.exe
        # where the release carries a Windows revision above .1. Excludes the portable
        # and 32-bit variants.
        $assetPattern = '^Git-(\d+\.\d+\.\d+(?:\.\d+)?)-64-bit\.exe$'
        $asset = $release.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
        if (-not $asset) {
            Write-Log "Could not find a 64-bit installer asset in release $($release.tag_name)." -Level WARN
            return $null
        }

        if ($asset.name -notmatch $assetPattern) {
            Write-Log "Could not parse a version from the asset name $($asset.name)." -Level WARN
            return $null
        }
        $version = $Matches[1]

        Write-Log "Latest Git for Windows: $version"
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

function Install-Git {
    param([string]$InstallerPath)

    Write-Log "Installing Git for Windows from: $InstallerPath"
    Write-Log "Components: $InstallComponents"

    # Close anything holding the Git installation open. On a multi-session host this
    # only affects the account running the update, since the image VM has no users.
    foreach ($name in @("git-bash", "git-gui", "gitk", "bash", "git")) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Log "Closing $name..."
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    $process = Start-Process -FilePath $InstallerPath -ArgumentList $InstallArguments -Wait -PassThru -NoNewWindow
    Write-Log "Installer exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }

    Write-Log "Waiting for post-install finalization..."
    Start-Sleep -Seconds 5

    return $process.ExitCode
}

function Set-GitAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for Git..."

    # The auto-updater is excluded at install time. Disable its scheduled task as well,
    # in case an earlier install on this image included the component.
    $tasks = Get-ScheduledTask -TaskName "*Git for Windows Updater*" -ErrorAction SilentlyContinue
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

    # Remove desktop shortcuts. Git Bash and Git GUI are launched from the Start menu.
    $shortcuts = @(
        "$env:PUBLIC\Desktop\Git Bash.lnk",
        "$env:PUBLIC\Desktop\Git GUI.lnk",
        "C:\Users\Default\Desktop\Git Bash.lnk",
        "C:\Users\Default\Desktop\Git GUI.lnk"
    )
    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "  Removed shortcut: $shortcut"
        }
    }

    Write-Log "Git AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Installer/Updater for AVD Gold Images"
    Write-Log "================================================================="

    $installed = Get-InstalledGitVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.ExePath)"
    } else {
        Write-Log "Git for Windows not currently installed."
    }

    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $release = Get-LatestGitRelease
        if (-not $release) {
            # An unresolved download URL on a machine with no Git installed is a failed
            # run, not a partial one. Reporting success here would leave an image short
            # an application with nothing in the summary to show it.
            if (-not $installed) {
                throw "Could not resolve a Git for Windows download URL and Git is not installed."
            }
            Write-Log "Could not resolve download URL. Keeping the installed version $($installed.Version) and applying customizations only." -Level WARN
        } elseif ($installed -and $installed.Version -eq $release.Version) {
            Write-Log "Already at latest version: $($installed.Version). Skipping download."
        } else {
            Write-Log "Downloading Git for Windows $($release.Version)..."

            if (-not (Test-Path $DownloadPath)) {
                New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
            }

            $installerFile = Join-Path $DownloadPath $release.FileName
            Start-FileDownload -Uri $release.DownloadUrl -OutFile $installerFile

            $preVersion = if ($installed) { $installed.Version } else { "none" }
            Install-Git -InstallerPath $installerFile | Out-Null

            $postInstall = Get-InstalledGitVersion
            if ($postInstall) {
                if ($postInstall.Version -ne $preVersion) {
                    Write-Log "Updated: $preVersion -> $($postInstall.Version)"
                } else {
                    Write-Log "Version unchanged after install: $($postInstall.Version)" -Level WARN
                }
            } else {
                throw "Git was not detected after a successful install."
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    Write-Log "-----------------------------------------------------------------"
    Set-GitAVDCustomizations

    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledGitVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Raw) (normalized $($finalVer.Version))"
    } else {
        throw "Git for Windows is not installed at completion."
    }

    if (-not $KeepInstallers -and (Test-Path -LiteralPath $DownloadPath)) {
        # Use .NET Directory.Delete instead of Remove-Item: when $env:TEMP resolves to an
        # 8.3 short path (e.g. C:\Users\FNS~1.TEC\...), Remove-Item throws a terminating
        # PSArgumentException that -ErrorAction cannot suppress. Retry briefly in case the
        # installer still holds a file lock.
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
