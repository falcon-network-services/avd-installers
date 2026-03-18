<#
.SYNOPSIS
    Config-driven orchestrator for AVD Gold Image application updates.

.DESCRIPTION
    Reads a JSON config file to determine which applications to update, fetches each
    application's update script from GitHub at runtime, and executes them in dependency
    order. This allows each gold image to declare its own set of applications without
    needing the full repository cloned locally.

    Execution order is fixed by the internal catalog (dependency order):
     1. VC++ 2015-2022 Redistributable  (runtime dependency for many apps)
     2. PowerShell 7
     3. Microsoft Edge
     4. Google Chrome Enterprise
     5. Mozilla Firefox ESR
     6. Adobe Reader DC
     7. Microsoft 365 Apps
     8. OneDrive
     9. Microsoft Teams
    10. WebRTC Redirector Service
    11. Notepad++
    12. Bitwarden

    Features:
    - Config-driven app selection (apps.json)
    - Scripts fetched from GitHub at runtime (no local repo needed)
    - Per-app parameters from config (e.g., TenantId, Architecture)
    - Per-app error isolation with try/catch
    - Summary report with pass/fail status and elapsed time
    - Full transcript logging

.PARAMETER ConfigPath
    Path to the JSON config file listing applications and their parameters.
    Defaults to C:\Scripts\apps.json.

.PARAMETER SkipUpdate
    If specified, passes -SkipUpdate to all child scripts that support it.
    This runs customizations only without downloading or installing updates.

.PARAMETER LogPath
    Directory for the orchestrator log file. Defaults to $env:SystemRoot\Logs\Software.

.PARAMETER GitHubRepo
    GitHub repository in Owner/Repo format. Defaults to falconnoclaf/avd-installers.
    Override for testing with forks.

.PARAMETER GitHubBranch
    GitHub branch name. Defaults to main. Override for testing with feature branches.

.PARAMETER GitHubToken
    GitHub Personal Access Token for private repositories. If omitted, requests are
    unauthenticated (works only for public repos). The token needs Contents read
    permission on the repository.

.EXAMPLE
    .\Update-GoldImage.ps1
    Reads C:\Scripts\apps.json and updates all listed applications.

.EXAMPLE
    .\Update-GoldImage.ps1 -SkipUpdate
    Applies customizations only (no downloads/installs) for all listed apps.

.EXAMPLE
    .\Update-GoldImage.ps1 -ConfigPath "C:\Scripts\apps-dev.json" -GitHubBranch "feature/test"
    Uses a custom config and pulls scripts from a feature branch.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "C:\Scripts\apps.json",

    [switch]$SkipUpdate,

    [string]$LogPath = "$env:SystemRoot\Logs\Software",

    [string]$GitHubRepo = "falconnoclaf/avd-installers",

    [string]$GitHubBranch = "main",

    [string]$GitHubToken
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ── TLS 1.2 (required for GitHub on WinPS 5.1) ─────────────────────────────
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── GitHub Auth Headers ─────────────────────────────────────────────────────
$GitHubHeaders = @{}
if ($GitHubToken) {
    $GitHubHeaders['Authorization'] = "token $GitHubToken"
}

# ── Paths ────────────────────────────────────────────────────────────────────
$LogFile = Join-Path $LogPath "GoldImage-Update-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$TempDir = Join-Path $env:TEMP "AVD-GoldImage-$(Get-Date -Format 'yyyyMMddHHmmss')"

if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
}

# ── Logging ──────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
}

# ── Application Catalog ─────────────────────────────────────────────────────
# Defines all known apps, their dependency order, and valid per-app parameters.
$AppDefinitions = @(
    @{
        Name               = "VCRedist"
        DisplayName        = "VC++ 2015-2022 Redistributable"
        ScriptFile         = "VCRedist/Update-VCRedist.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @("x64Only")
    },
    @{
        Name               = "PowerShell7"
        DisplayName        = "PowerShell 7"
        ScriptFile         = "PowerShell7/Update-PowerShell7.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @()
    },
    @{
        Name               = "MicrosoftEdge"
        DisplayName        = "Microsoft Edge"
        ScriptFile         = "MicrosoftEdge/Update-MicrosoftEdge.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @("Architecture")
    },
    @{
        Name               = "GoogleChrome"
        DisplayName        = "Google Chrome Enterprise"
        ScriptFile         = "GoogleChrome/Update-GoogleChrome.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @()
    },
    @{
        Name               = "FirefoxESR"
        DisplayName        = "Mozilla Firefox ESR"
        ScriptFile         = "FirefoxESR/Update-FirefoxESR.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @()
    },
    @{
        Name               = "AdobeReaderDC"
        DisplayName        = "Adobe Acrobat Reader DC"
        ScriptFile         = "AdobeReaderDC/Update-AdobeReaderDC.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @("Architecture", "BaseVersion", "UpdateVersion")
    },
    @{
        Name               = "Microsoft365Apps"
        DisplayName        = "Microsoft 365 Apps"
        ScriptFile         = "Microsoft365Apps/Update-Microsoft365Apps.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @("TargetVersion", "TenantId")
    },
    @{
        Name               = "OneDrive"
        DisplayName        = "OneDrive"
        ScriptFile         = "OneDrive/Update-OneDrive.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @("TenantId")
    },
    @{
        Name               = "MicrosoftTeams"
        DisplayName        = "Microsoft Teams"
        ScriptFile         = "MicrosoftTeams/Update-MicrosoftTeams.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @("OfflineMsix")
    },
    @{
        Name               = "WebRTCRedirector"
        DisplayName        = "WebRTC Redirector Service"
        ScriptFile         = "WebRTCRedirector/Update-WebRTCRedirector.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @()
    },
    @{
        Name               = "NotepadPlusPlus"
        DisplayName        = "Notepad++"
        ScriptFile         = "NotepadPlusPlus/Update-NotepadPlusPlus.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @()
    },
    @{
        Name               = "Bitwarden"
        DisplayName        = "Bitwarden"
        ScriptFile         = "Bitwarden/Update-Bitwarden.ps1"
        SupportsSkipUpdate = $true
        ValidParams        = @()
    }
)

$ValidAppNames = $AppDefinitions | ForEach-Object { $_.Name }

# ── Read Config ──────────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    Write-Log "Config file not found: $ConfigPath" -Level ERROR
    Write-Log "Create a config file or specify a path with -ConfigPath." -Level ERROR
    Write-Log "See apps.example.json in the repository for a template." -Level ERROR
    exit 1
}

try {
    $configRaw = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
    $config = $configRaw | ConvertFrom-Json
}
catch {
    Write-Log "Failed to parse config file: $($_.Exception.Message)" -Level ERROR
    exit 1
}

if (-not $config.apps) {
    Write-Log "Config file has no 'apps' array." -Level ERROR
    exit 1
}

if ($config.apps.Count -eq 0) {
    Write-Log "Config 'apps' array is empty. Nothing to do." -Level WARN
    exit 0
}

# ── Validate Config ──────────────────────────────────────────────────────────
$invalidNames = @()
foreach ($appEntry in $config.apps) {
    if ($ValidAppNames -notcontains $appEntry.name) {
        $invalidNames += $appEntry.name
    }
}

if ($invalidNames.Count -gt 0) {
    Write-Log "Unrecognized app name(s) in config: $($invalidNames -join ', ')" -Level ERROR
    Write-Log "Valid names: $($ValidAppNames -join ', ')" -Level ERROR
    exit 1
}

# Validate per-app parameters against the catalog
foreach ($appEntry in $config.apps) {
    if ($appEntry.PSObject.Properties['parameters']) {
        $catalogEntry = $AppDefinitions | Where-Object { $_.Name -eq $appEntry.name }
        $paramNames = ($appEntry.parameters | Get-Member -MemberType NoteProperty).Name
        foreach ($paramName in $paramNames) {
            if ($catalogEntry.ValidParams -notcontains $paramName) {
                Write-Log "Invalid parameter '$paramName' for app '$($appEntry.name)'." -Level ERROR
                if ($catalogEntry.ValidParams.Count -gt 0) {
                    Write-Log "Valid parameters for $($appEntry.name): $($catalogEntry.ValidParams -join ', ')" -Level ERROR
                }
                else {
                    Write-Log "$($appEntry.name) does not accept any per-app parameters." -Level ERROR
                }
                exit 1
            }
        }
    }
}

# ── Build config lookup (name -> parameters) ────────────────────────────────
$configLookup = @{}
foreach ($appEntry in $config.apps) {
    $configLookup[$appEntry.name] = $appEntry
}

# Filter catalog to only config-listed apps (preserving dependency order)
$AppsToRun = $AppDefinitions | Where-Object { $configLookup.ContainsKey($_.Name) }

# ── Banner ───────────────────────────────────────────────────────────────────
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Log "============================================================"
Write-Log "  AVD Gold Image Update - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "============================================================"
Write-Log "Config file: $ConfigPath"
Write-Log "GitHub source: $GitHubRepo @ $GitHubBranch ($(if ($GitHubToken) { 'authenticated' } else { 'public' }))"
Write-Log "Applications to process: $($AppsToRun.Count)"
Write-Log "SkipUpdate mode: $SkipUpdate"
Write-Log "Log file: $LogFile"
Write-Log "------------------------------------------------------------"

# ── Create Temp Directory ────────────────────────────────────────────────────
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null

# ── Results Tracking ─────────────────────────────────────────────────────────
$Results = [System.Collections.ArrayList]::new()

# ── Execute Each Application ─────────────────────────────────────────────────
$appIndex = 0
try {
    foreach ($app in $AppsToRun) {
        $appIndex++
        $appStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $status  = "UNKNOWN"
        $detail  = ""

        Write-Log ""
        Write-Log "============================================================"
        Write-Log "  [$appIndex/$($AppsToRun.Count)] $($app.DisplayName)"
        Write-Log "============================================================"

        # Download script from GitHub
        $scriptUrl  = "https://raw.githubusercontent.com/$GitHubRepo/$GitHubBranch/$($app.ScriptFile)"
        $scriptPath = Join-Path $TempDir "Update-$($app.Name).ps1"

        try {
            Write-Log "Downloading: $scriptUrl"
            Invoke-WebRequest -Uri $scriptUrl -OutFile $scriptPath -UseBasicParsing -Headers $GitHubHeaders
            Unblock-File -Path $scriptPath
        }
        catch {
            $status = "FAILED"
            $detail = "Failed to download script: $($_.Exception.Message)"
            Write-Log $detail -Level ERROR

            $appStopwatch.Stop()
            $Results.Add([PSCustomObject]@{
                Index       = $appIndex
                Application = $app.DisplayName
                Status      = $status
                Duration    = $appStopwatch.Elapsed.ToString("mm\:ss")
                Detail      = $detail
            }) | Out-Null
            continue
        }

        try {
            # Build arguments
            $scriptArgs = @{}

            if ($SkipUpdate -and $app.SupportsSkipUpdate) {
                $scriptArgs['SkipUpdate'] = $true
            }

            # Add per-app parameters from config
            $appConfig = $configLookup[$app.Name]
            if ($appConfig.PSObject.Properties['parameters']) {
                $paramMembers = ($appConfig.parameters | Get-Member -MemberType NoteProperty).Name
                foreach ($paramName in $paramMembers) {
                    $scriptArgs[$paramName] = $appConfig.parameters.$paramName
                }
            }

            Write-Log "Executing: $scriptPath"
            if ($scriptArgs.Count -gt 0) {
                Write-Log "Arguments: $($scriptArgs.Keys -join ', ')"
            }
            Write-Log "------------------------------------------------------------"

            # Execute the child script
            & $scriptPath @scriptArgs

            $status = "SUCCESS"
            $detail = "Completed successfully"
            Write-Log "------------------------------------------------------------"
            Write-Log "$($app.DisplayName) completed successfully."
        }
        catch {
            $status = "FAILED"
            $detail = $_.Exception.Message
            Write-Log "------------------------------------------------------------"
            Write-Log "$($app.DisplayName) FAILED: $detail" -Level ERROR
        }

        $appStopwatch.Stop()
        $elapsed = $appStopwatch.Elapsed.ToString("mm\:ss")

        $Results.Add([PSCustomObject]@{
            Index       = $appIndex
            Application = $app.DisplayName
            Status      = $status
            Duration    = $elapsed
            Detail      = $detail
        }) | Out-Null

        Write-Log "Duration: $elapsed"
    }
}
finally {
    # ── Clean Up Temp Directory ──────────────────────────────────────────────
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ── Summary Report ───────────────────────────────────────────────────────────
$totalStopwatch.Stop()
$totalElapsed = $totalStopwatch.Elapsed.ToString("hh\:mm\:ss")

$successCount = ($Results | Where-Object { $_.Status -eq "SUCCESS" }).Count
$failedCount  = ($Results | Where-Object { $_.Status -eq "FAILED" }).Count

Write-Log ""
Write-Log "============================================================"
Write-Log "  SUMMARY REPORT"
Write-Log "============================================================"
Write-Log ""

# Column widths
$colIdx  = 4
$colApp  = 35
$colStat = 9
$colDur  = 8

$header = "{0,-$colIdx} {1,-$colApp} {2,-$colStat} {3,-$colDur}" -f "#", "Application", "Status", "Duration"
Write-Log $header
Write-Log ("-" * ($colIdx + $colApp + $colStat + $colDur + 3))

foreach ($r in $Results) {
    $line = "{0,-$colIdx} {1,-$colApp} {2,-$colStat} {3,-$colDur}" -f $r.Index, $r.Application, $r.Status, $r.Duration
    $level = switch ($r.Status) {
        "FAILED"  { "ERROR" }
        default   { "INFO" }
    }
    Write-Log $line -Level $level

    if ($r.Status -eq "FAILED") {
        Write-Log "    -> $($r.Detail)" -Level ERROR
    }
}

Write-Log ""
Write-Log "------------------------------------------------------------"
Write-Log "Total: $($Results.Count) apps | $successCount succeeded | $failedCount failed"
Write-Log "Total elapsed time: $totalElapsed"
Write-Log "Log file: $LogFile"
Write-Log "============================================================"

# ── Exit Code ────────────────────────────────────────────────────────────────
if ($failedCount -gt 0) {
    Write-Log ""
    Write-Log "One or more applications failed. Review the log for details." -Level WARN
    exit 1
}
else {
    Write-Log ""
    Write-Log "All applications completed successfully."
    exit 0
}
