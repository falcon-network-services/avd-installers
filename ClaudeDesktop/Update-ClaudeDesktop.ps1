<#
.SYNOPSIS
    Installs or updates Claude Desktop for AVD Gold Images.

.DESCRIPTION
    Downloads the current Claude Desktop MSIX package and provisions it machine-wide
    with Add-AppxProvisionedPackage, so that every user who signs in to a session host
    built from the image receives the app without needing local administrator rights.

    The MSIX is packaged per-user. Add-AppxPackage would register it for the calling
    account only, which on a multi-session host means one profile. Provisioning stages
    the package at the operating system level instead, and each user profile registers
    it at first sign-in.

    Claude Desktop owns its own version: the in-app updater is left enabled, so hosts
    stay current between image builds. The disableAutoUpdates policy is deliberately
    not set. Do not set it without also taking responsibility for pushing new MSIX
    builds, since both owners registering the package produces duplicate entries under
    the Claude package family and a "the parameter is incorrect" failure.

    Cowork is not available on this platform. It requires the Virtual Machine Platform
    and nested virtualization, which Azure Virtual Desktop session hosts do not provide.
    The Virtual Machine Platform feature is therefore not enabled by this script.

.PARAMETER SkipUpdate
    If specified, skips the download and provisioning and only reports current state.

.PARAMETER Architecture
    MSIX architecture to deploy. Defaults to x64.

.PARAMETER KeepInstallers
    If specified, the downloaded MSIX is not cleaned up after provisioning.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-ClaudeDesktop.ps1
    Provisions the current Claude Desktop MSIX machine-wide.

.EXAMPLE
    .\Update-ClaudeDesktop.ps1 -SkipUpdate
    Reports the provisioned and registered package state without changing it.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Centralized deployment requires an Anthropic Team or Enterprise plan. Each user
    signs in to Claude Desktop with their own account.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [ValidateSet("x64", "arm64")]
    [string]$Architecture = "x64",

    [string]$DownloadPath = "$env:TEMP\ClaudeDesktop",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Claude Desktop"

# Anthropic publishes a redirect to the current MSIX per architecture
$DownloadUrls = @{
    "x64"   = "https://claude.ai/api/desktop/win32/x64/msix/latest/redirect"
    "arm64" = "https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect"
}

# Package identity match. The package family is Claude; match on a wildcard so a
# publisher-side rename does not silently turn this script into a no-op.
$PackageMatch = "*Claude*"

# Policy key. Present for verification only - this script does not write to it.
$PolicyRegPath = "HKLM:\SOFTWARE\Policies\Claude"

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "ClaudeDesktop-Install.log"
    Add-Content -Path $logFile -Value $entry
}

function Get-ProvisionedClaudePackage {
    <#
    .SYNOPSIS
        Returns the machine-wide provisioned Claude package, or $null.
    #>
    try {
        $pkg = Get-AppxProvisionedPackage -Online -ErrorAction Stop |
            Where-Object { $_.DisplayName -like $PackageMatch } |
            Select-Object -First 1
        if ($pkg) {
            return [PSCustomObject]@{
                DisplayName = $pkg.DisplayName
                PackageName = $pkg.PackageName
                Version     = $pkg.Version
            }
        }
    } catch {
        Write-Log "Could not query provisioned packages: $($_.Exception.Message)" -Level WARN
    }
    return $null
}

function Get-RegisteredClaudePackage {
    <#
    .SYNOPSIS
        Returns the Claude package registered for the current user, or $null. Used for
        reporting only: on a Gold Image the local administrator is not the target user.
    #>
    try {
        $pkg = Get-AppxPackage -Name $PackageMatch -ErrorAction Stop | Select-Object -First 1
        if ($pkg) {
            return [PSCustomObject]@{
                Name           = $pkg.Name
                Version        = $pkg.Version
                PackageFullName = $pkg.PackageFullName
            }
        }
    } catch {
        Write-Log "Could not query registered packages: $($_.Exception.Message)" -Level WARN
    }
    return $null
}

function Get-MsixManifestVersion {
    <#
    .SYNOPSIS
        Reads the Identity version from the AppxManifest inside an MSIX package.
    #>
    param([string]$MsixPath)

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($MsixPath)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq "AppxManifest.xml" } | Select-Object -First 1
            if (-not $entry) {
                Write-Log "AppxManifest.xml not found inside the package." -Level WARN
                return $null
            }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $xml = [xml]$xmlText
            return $xml.Package.Identity.Version
        } finally {
            $zip.Dispose()
        }
    } catch {
        Write-Log "Could not read version from MSIX manifest: $($_.Exception.Message)" -Level WARN
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
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers $headers -TimeoutSec 900
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

function Install-ClaudeDesktop {
    <#
    .SYNOPSIS
        Provisions the MSIX machine-wide. Add-AppxProvisionedPackage replaces an
        existing provisioned version of the same package family.
    #>
    param([string]$MsixPath)

    Write-Log "Provisioning Claude Desktop machine-wide from: $MsixPath"

    try {
        Add-AppxProvisionedPackage -Online -PackagePath $MsixPath -SkipLicense -Regions "all" -ErrorAction Stop | Out-Null
        Write-Log "Add-AppxProvisionedPackage completed."
    } catch {
        throw "$AppName provisioning failed: $($_.Exception.Message)"
    }

    Write-Log "Waiting for provisioning to settle..."
    Start-Sleep -Seconds 10
}

function Test-ClaudeUpdatePolicy {
    <#
    .SYNOPSIS
        Reports whether an auto-update policy is present. Claude Desktop owns its own
        version in this deployment, so disableAutoUpdates is expected to be absent.
    #>
    if (Test-Path $PolicyRegPath) {
        $value = $null
        try {
            $value = (Get-ItemProperty -Path $PolicyRegPath -Name "disableAutoUpdates" -ErrorAction Stop).disableAutoUpdates
        } catch {
            Write-Log "  Policy key present, disableAutoUpdates not set. In-app updater owns versioning."
            return
        }
        if ($value -eq 1) {
            Write-Log "  disableAutoUpdates = 1. The in-app updater is disabled, so this image is now the version owner and new MSIX builds must be pushed at each image build." -Level WARN
        } else {
            Write-Log "  disableAutoUpdates = $value. In-app updater owns versioning."
        }
    } else {
        Write-Log "  No policy key present. In-app updater owns versioning."
    }
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Installer/Updater for AVD Gold Images"
    Write-Log "Architecture: $Architecture"
    Write-Log "================================================================="

    $provisioned = Get-ProvisionedClaudePackage
    if ($provisioned) {
        Write-Log "Provisioned package: $($provisioned.DisplayName)"
        Write-Log "Provisioned version: $($provisioned.Version)"
    } else {
        Write-Log "Claude Desktop is not currently provisioned machine-wide."
    }

    $registered = Get-RegisteredClaudePackage
    if ($registered) {
        Write-Log "Registered for the current account: $($registered.Name) $($registered.Version)"
    }

    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"

        if (-not (Test-Path $DownloadPath)) {
            New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
        }

        $msixFile = Join-Path $DownloadPath "Claude-$Architecture.msix"
        Start-FileDownload -Uri $DownloadUrls[$Architecture] -OutFile $msixFile

        $packageVersion = Get-MsixManifestVersion -MsixPath $msixFile
        if ($packageVersion) {
            Write-Log "Downloaded package version: $packageVersion"
        }

        $alreadyCurrent = $false
        if ($provisioned -and $packageVersion -and $provisioned.Version -eq $packageVersion) {
            $alreadyCurrent = $true
        }

        if ($alreadyCurrent) {
            Write-Log "Already provisioned at $packageVersion. Skipping provisioning."
        } else {
            $preVersion = if ($provisioned) { $provisioned.Version } else { "none" }
            Install-ClaudeDesktop -MsixPath $msixFile

            $postProvision = Get-ProvisionedClaudePackage
            if (-not $postProvision) {
                throw "Claude Desktop is not provisioned after a successful provisioning call."
            }
            if ($postProvision.Version -ne $preVersion) {
                Write-Log "Provisioned: $preVersion -> $($postProvision.Version)"
            } else {
                throw "Provisioning reported success but the provisioned version is unchanged at $($postProvision.Version). Expected $packageVersion."
            }
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified)."
    }

    Write-Log "-----------------------------------------------------------------"
    Write-Log "Verifying update ownership for Claude Desktop..."
    Test-ClaudeUpdatePolicy
    Write-Log "Cowork is unavailable on Azure Virtual Desktop session hosts, which do not provide nested virtualization. Virtual Machine Platform is not enabled by this script."

    Write-Log "-----------------------------------------------------------------"
    $finalProvisioned = Get-ProvisionedClaudePackage
    if ($finalProvisioned) {
        Write-Log "Final provisioned version: $($finalProvisioned.Version)"
        Write-Log "Package name: $($finalProvisioned.PackageName)"
    } else {
        throw "No provisioned Claude Desktop package found at completion."
    }

    if (-not $KeepInstallers -and (Test-Path -LiteralPath $DownloadPath)) {
        # Use .NET Directory.Delete instead of Remove-Item: when $env:TEMP resolves to an
        # 8.3 short path (e.g. C:\Users\FNS~1.TEC\...), Remove-Item throws a terminating
        # PSArgumentException that -ErrorAction cannot suppress. Retry briefly in case the
        # deployment stack still holds a handle on the package.
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
    Write-Log "$AppName provisioning completed successfully."
    Write-Log "================================================================="
    exit 0

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
