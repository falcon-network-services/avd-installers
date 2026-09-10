<#
.SYNOPSIS
    Installs or updates Node.js LTS for AVD Gold Images.

.DESCRIPTION
    Resolves the current Node.js LTS release from the official release index, installs
    the x64 MSI machine-wide, then suppresses the npm update notifier so that the
    version baked into the Gold Image is the version users get.

    The MSI installs to Program Files and adds Node to the machine PATH, so the runtime
    is shared by every session rather than installed into each user's profile container.

.PARAMETER SkipUpdate
    If specified, skips the download and install and only applies customizations.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-NodeJS.ps1
    Updates Node.js to the current LTS release.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\NodeJS",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Node.js"

# Official release index. Entries with a non-false "lts" value are LTS releases,
# newest first.
$ReleaseIndexUrl = "https://nodejs.org/dist/index.json"

$NodeExePath = Join-Path $env:ProgramFiles "nodejs\node.exe"

# System environment variable registry path
$EnvRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "NodeJS-Install.log"
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

function Get-InstalledNodeVersion {
    if (Test-Path $NodeExePath) {
        $ver = (Get-Item $NodeExePath).VersionInfo.ProductVersion
        if ($ver) { $ver = $ver.TrimStart("v") }
        return [PSCustomObject]@{
            Version = $ver
            ExePath = $NodeExePath
        }
    }
    return $null
}

function Get-LatestNodeLtsRelease {
    Write-Log "Querying the Node.js release index for the current LTS release..."
    try {
        $headers = @{ "User-Agent" = "PowerShell-AVD-GoldImage" }
        $index = Invoke-RestMethod -Uri $ReleaseIndexUrl -UseBasicParsing -Headers $headers -TimeoutSec 60

        $lts = $index | Where-Object { $_.lts } | Select-Object -First 1
        if (-not $lts) {
            Write-Log "No LTS release found in the release index." -Level WARN
            return $null
        }

        $version = $lts.version.TrimStart("v")
        $fileName = "node-v$version-x64.msi"
        Write-Log "Latest Node.js LTS: $version ($($lts.lts))"
        return [PSCustomObject]@{
            Version     = $version
            DownloadUrl = "https://nodejs.org/dist/v$version/$fileName"
            FileName    = $fileName
        }
    } catch {
        Write-Log "Failed to query the Node.js release index: $($_.Exception.Message)" -Level WARN
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

    # nodejs.org/dist serves the MSI directly, so BITS is used first with
    # Invoke-WebRequest as the fallback.
    $downloaded = $false
    try {
        Start-BitsTransfer -Source $Uri -Destination $OutFile -ErrorAction Stop
        $downloaded = $true
    } catch {
        Write-Log "BITS transfer failed, falling back to Invoke-WebRequest: $($_.Exception.Message)" -Level WARN
    }

    if (-not $downloaded) {
        try {
            $headers = @{ "User-Agent" = "PowerShell-AVD-GoldImage" }
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers $headers -TimeoutSec 600
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

function Install-NodeJS {
    param([string]$InstallerPath)

    Write-Log "Installing Node.js from: $InstallerPath"

    $arguments = @("/i", "`"$InstallerPath`"", "/qn", "/norestart", "ALLUSERS=1")
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "MSI installer exit code: $($process.ExitCode)"

    # 3010 is success with a reboot required, which is acceptable on an image VM.
    # 1618 is another install already in progress and is treated as non-fatal.
    if ($process.ExitCode -eq 1618) {
        Write-Log "Another installation is in progress (1618). Node.js was not installed on this run." -Level WARN
    } elseif ($process.ExitCode -notin @(0, 3010)) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }

    return $process.ExitCode
}

function Set-NodeJSAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for Node.js..."

    # Suppress the npm update notifier so users are not prompted to update a runtime
    # they cannot change.
    Set-RegistryValue -Path $EnvRegPath -Name "NO_UPDATE_NOTIFIER" -Value "1" -Type String
    Write-Log "  NO_UPDATE_NOTIFIER = 1 (system environment variable)"

    Send-EnvironmentChange

    Write-Log "Node.js AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName LTS Installer/Updater for AVD Gold Images"
    Write-Log "================================================================="

    $installed = Get-InstalledNodeVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.ExePath)"
    } else {
        Write-Log "Node.js not currently installed."
    }

    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        $release = Get-LatestNodeLtsRelease
        if (-not $release) {
            # An unresolved download URL on a machine with no Node installed is a failed
            # run, not a partial one. Reporting success here would leave an image short
            # an application with nothing in the summary to show it.
            if (-not $installed) {
                throw "Could not resolve a Node.js LTS download URL and Node.js is not installed."
            }
            Write-Log "Could not resolve download URL. Keeping the installed version $($installed.Version) and applying customizations only." -Level WARN
        } elseif ($installed -and $installed.Version -eq $release.Version) {
            Write-Log "Already at latest LTS: $($installed.Version). Skipping download."
        } else {
            Write-Log "Downloading Node.js $($release.Version)..."

            if (-not (Test-Path $DownloadPath)) {
                New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
            }

            $installerFile = Join-Path $DownloadPath $release.FileName
            Start-FileDownload -Uri $release.DownloadUrl -OutFile $installerFile

            $preVersion = if ($installed) { $installed.Version } else { "none" }
            $installExitCode = Install-NodeJS -InstallerPath $installerFile

            $postInstall = Get-InstalledNodeVersion
            if (-not $postInstall) {
                throw "Node.js was not detected after a successful install."
            }
            if ($postInstall.Version -ne $preVersion) {
                Write-Log "Updated: $preVersion -> $($postInstall.Version)"
            } elseif ($installExitCode -eq 1618) {
                # The installer never ran, so an unchanged version is expected here.
                Write-Log "Version unchanged: $($postInstall.Version). No install was attempted (1618)." -Level WARN
            } else {
                throw "The installer reported success but the version is unchanged at $($postInstall.Version). Expected $($release.Version)."
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    Write-Log "-----------------------------------------------------------------"
    Set-NodeJSAVDCustomizations

    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledNodeVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Version)"
    } else {
        throw "Node.js is not installed at completion."
    }

    $envCheck = [System.Environment]::GetEnvironmentVariable("NO_UPDATE_NOTIFIER", "Machine")
    if ($envCheck -eq "1") {
        Write-Log "Verified: NO_UPDATE_NOTIFIER = 1 (Machine scope)"
    } else {
        Write-Log "NO_UPDATE_NOTIFIER not set at Machine scope." -Level WARN
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
