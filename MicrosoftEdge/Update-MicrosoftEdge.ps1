<#
.SYNOPSIS
    Updates Microsoft Edge and disables auto-update for AVD Gold Images.

.DESCRIPTION
    Downloads the latest Microsoft Edge Stable MSI from Microsoft's direct
    download endpoint, installs it silently over the existing installation,
    then locks down all auto-update mechanisms so Edge remains at the version
    baked into the Gold Image.

    Auto-update lockdown:
    - Disables edgeupdate and edgeupdatem services
    - Disables Edge update scheduled tasks
    - Sets EdgeUpdate group policy to disable auto-updates
    - Optionally configures Edge browser policies for AVD

.PARAMETER Architecture
    Target architecture: "x64" (default) or "x86".

.PARAMETER SkipUpdate
    If specified, skips the Edge update and only applies customizations.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-MicrosoftEdge.ps1
    Updates Edge to latest stable and disables auto-update.

.EXAMPLE
    .\Update-MicrosoftEdge.ps1 -SkipUpdate
    Only disables auto-update and applies AVD customizations.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [ValidateSet("x64", "x86")]
    [string]$Architecture = "x64",

    [switch]$SkipUpdate,

    [string]$DownloadPath = "$env:TEMP\MicrosoftEdge",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Microsoft Edge"

# Edge enterprise releases JSON API (returns direct download URLs)
$EdgeReleasesApi = "https://edgeupdates.microsoft.com/api/products"

$MsiFileName = "MicrosoftEdgeEnterpriseX64.msi"
if ($Architecture -eq "x86") { $MsiFileName = "MicrosoftEdgeEnterpriseX86.msi" }

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "MicrosoftEdge-Update.log"
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

function Get-InstalledEdgeVersion {
    <#
    .SYNOPSIS
        Detects the installed Microsoft Edge version.
    #>
    $edgePaths = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($p in $edgePaths) {
        if (Test-Path $p) {
            $ver = (Get-Item $p).VersionInfo.ProductVersion
            return [PSCustomObject]@{
                Version = $ver
                Path    = $p
            }
        }
    }
    return $null
}

function Get-LatestEdgeMsiUrl {
    <#
    .SYNOPSIS
        Queries the Edge enterprise releases API to get the direct MSI download URL
        for the latest Stable channel release.
    #>
    Write-Log "Querying Edge enterprise releases API..."
    try {
        $response = Invoke-WebRequest -Uri $EdgeReleasesApi -UseBasicParsing -TimeoutSec 30
        $products = $response.Content | ConvertFrom-Json

        # Find the Stable channel product
        $stable = $products | Where-Object { $_.Product -eq "Stable" }
        if (-not $stable) {
            Write-Log "Could not find Stable channel in API response." -Level WARN
            return $null
        }

        # Get the latest release
        $latestRelease = $stable.Releases |
            Where-Object { $_.Platform -eq "Windows" -and $_.Architecture -eq $Architecture } |
            Sort-Object { [version]$_.ProductVersion } -Descending |
            Select-Object -First 1

        if (-not $latestRelease) {
            Write-Log "Could not find $Architecture release for Windows." -Level WARN
            return $null
        }

        # Find the MSI artifact
        $msiArtifact = $latestRelease.Artifacts | Where-Object { $_.ArtifactName -eq "msi" }
        if (-not $msiArtifact) {
            Write-Log "Could not find MSI artifact in release." -Level WARN
            return $null
        }

        Write-Log "Latest Edge Stable: $($latestRelease.ProductVersion) ($Architecture)"
        return [PSCustomObject]@{
            Version     = $latestRelease.ProductVersion
            DownloadUrl = $msiArtifact.Location
            SizeBytes   = $msiArtifact.SizeInBytes
            Hash        = $msiArtifact.Hash
        }
    } catch {
        Write-Log "Failed to query Edge releases API: $($_.Exception.Message)" -Level WARN
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
}

function Install-EdgeMSI {
    param([string]$MsiPath)

    Write-Log "Installing Edge from: $MsiPath"

    # Close Edge if running
    $edgeProcs = Get-Process -Name "msedge" -ErrorAction SilentlyContinue
    if ($edgeProcs) {
        Write-Log "Closing Microsoft Edge..."
        $edgeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    $logFile = Join-Path $LogPath "MicrosoftEdge-MSI-Install.log"
    $arguments = "/i `"$MsiPath`" /qn /norestart DONOTCREATEDESKTOPSHORTCUT=true /L*v `"$logFile`""

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "MSI installer exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 1618 -and $process.ExitCode -ne 3010) {
        throw "$AppName installation failed with exit code $($process.ExitCode)"
    }
    return $process.ExitCode
}

function Set-EdgeAVDCustomizations {
    Write-Log "Applying AVD Gold Image customizations for Microsoft Edge..."

    # -- Disable Edge auto-updates via EdgeUpdate policy --
    $edgeUpdatePath = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
    # AutoUpdateCheckPeriodMinutes = 0 disables auto-update checks
    Set-RegistryValue -Path $edgeUpdatePath -Name "AutoUpdateCheckPeriodMinutes" -Value 0
    # UpdateDefault: 0 = Updates disabled, 1 = Always allow, 2 = Manual only, 3 = Auto
    Set-RegistryValue -Path $edgeUpdatePath -Name "UpdateDefault" -Value 0
    # Specific override for Edge Stable
    Set-RegistryValue -Path "$edgeUpdatePath\Apps\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" -Name "Update" -Value 0

    # -- Disable Edge update services --
    $services = @("edgeupdate", "edgeupdatem")
    foreach ($svc in $services) {
        try {
            $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($service) {
                Stop-Service -Name $svc -Force -ErrorAction Stop
                Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
                Write-Log "Service '$svc' stopped and set to Disabled."
            }
        } catch {
            Write-Log "Failed to disable service '$svc': $($_.Exception.Message)" -Level WARN
        }
    }

    # -- Disable Edge update scheduled tasks --
    $tasks = Get-ScheduledTask -TaskName "*Edge*" -ErrorAction SilentlyContinue
    foreach ($task in $tasks) {
        try {
            if ($task.State -ne "Disabled") {
                $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null
                Write-Log "Disabled scheduled task: $($task.TaskName)"
            }
        } catch {
            Write-Log "Failed to disable task '$($task.TaskName)': $($_.Exception.Message)" -Level WARN
        }
    }

    # -- Edge browser policies for AVD --
    $edgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"

    # Disable first run experience
    Set-RegistryValue -Path $edgePolicyPath -Name "HideFirstRunExperience" -Value 1

    # Disable import prompts on first launch
    Set-RegistryValue -Path $edgePolicyPath -Name "AutoImportAtFirstRun" -Value 4
    # 4 = Disables auto-import

    # Disable Edge sidebar (Copilot / Discover)
    Set-RegistryValue -Path $edgePolicyPath -Name "HubsSidebarEnabled" -Value 0

    # Disable Edge shopping features
    Set-RegistryValue -Path $edgePolicyPath -Name "EdgeShoppingAssistantEnabled" -Value 0

    # Disable default browser prompt
    Set-RegistryValue -Path $edgePolicyPath -Name "DefaultBrowserSettingEnabled" -Value 0

    # Disable background mode (Edge running after close)
    Set-RegistryValue -Path $edgePolicyPath -Name "BackgroundModeEnabled" -Value 0

    # Disable startup boost (persistent background process)
    Set-RegistryValue -Path $edgePolicyPath -Name "StartupBoostEnabled" -Value 0

    # Disable sending browsing data to Microsoft
    Set-RegistryValue -Path $edgePolicyPath -Name "SendSiteInfoToImproveServices" -Value 0
    Set-RegistryValue -Path $edgePolicyPath -Name "PersonalizationReportingEnabled" -Value 0

    # -- Remove Desktop Shortcuts --
    $shortcuts = @(
        "$env:PUBLIC\Desktop\Microsoft Edge.lnk",
        "C:\Users\Default\Desktop\Microsoft Edge.lnk"
    )
    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "Removed shortcut: $shortcut"
        }
    }

    Write-Log "Edge AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-InstalledEdgeVersion
    if ($installed) {
        Write-Log "Installed version: $($installed.Version)"
        Write-Log "Installed path:    $($installed.Path)"
    } else {
        Write-Log "Microsoft Edge not detected." -Level WARN
    }

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        # Query API for latest MSI download URL
        $edgeRelease = Get-LatestEdgeMsiUrl
        if (-not $edgeRelease) {
            Write-Log "Could not resolve Edge download URL. Skipping update, applying customizations only." -Level WARN
        } else {
            Write-Log "Downloading Edge $($edgeRelease.Version) MSI..."

            if (-not (Test-Path $DownloadPath)) {
                New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
            }

            $msiFile = Join-Path $DownloadPath $MsiFileName
            Start-FileDownload -Uri $edgeRelease.DownloadUrl -OutFile $msiFile

            # Validate file size (MSI should be > 100 MB)
            $actualSize = (Get-Item $msiFile).Length
            if ($actualSize -lt 100MB) {
                Write-Log "Downloaded file is only $([math]::Round($actualSize / 1MB, 1)) MB - expected >100 MB. File may be corrupt." -Level ERROR
                throw "Edge MSI download appears invalid (too small: $([math]::Round($actualSize / 1MB, 1)) MB)"
            }

            $preVersion = if ($installed) { $installed.Version } else { "none" }
            $exitCode = Install-EdgeMSI -MsiPath $msiFile

            $postInstall = Get-InstalledEdgeVersion
            if ($postInstall) {
                if ($postInstall.Version -ne $preVersion) {
                    Write-Log "Updated: $preVersion -> $($postInstall.Version)"
                } else {
                    Write-Log "Already at latest version: $($postInstall.Version)"
                }
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    # Apply AVD customizations
    Write-Log "-----------------------------------------------------------------"
    Set-EdgeAVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalVer = Get-InstalledEdgeVersion
    if ($finalVer) {
        Write-Log "Final version: $($finalVer.Version)"
    }

    # Cleanup
    if (-not $KeepInstallers -and (Test-Path $DownloadPath)) {
        Remove-Item -Path $DownloadPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned up download directory."
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
