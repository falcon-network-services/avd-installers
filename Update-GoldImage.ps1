<#
.SYNOPSIS
    Master orchestrator script for AVD Gold Image application updates.

.DESCRIPTION
    Sequentially executes all application update/install scripts for the AVD Gold
    Image. Each application runs in an isolated error boundary so a failure in one
    does not prevent the remaining applications from being processed.

    Execution order is optimized for dependencies:
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
    - Per-app error isolation with try/catch
    - Summary report with pass/fail/skip status
    - Elapsed time per app and total run time
    - -SkipUpdate passthrough to child scripts
    - -Only / -Exclude parameters for selective execution
    - Full transcript logging

.PARAMETER SkipUpdate
    If specified, passes -SkipUpdate to all child scripts that support it.
    This runs customizations only without downloading or installing updates.

.PARAMETER Only
    Array of application names to run. Only these apps will be processed.
    Valid names: VCRedist, PowerShell7, MicrosoftEdge, GoogleChrome, FirefoxESR,
                 AdobeReaderDC, Microsoft365Apps, OneDrive, MicrosoftTeams,
                 WebRTCRedirector, NotepadPlusPlus, Bitwarden

.PARAMETER Exclude
    Array of application names to skip. All other apps will be processed.
    Uses the same valid names as -Only.

.PARAMETER LogPath
    Directory for the orchestrator log file. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-GoldImage.ps1
    Updates all 12 applications in dependency order.

.EXAMPLE
    .\Update-GoldImage.ps1 -SkipUpdate
    Applies customizations only (no downloads/installs) for all apps.

.EXAMPLE
    .\Update-GoldImage.ps1 -Only "GoogleChrome", "MicrosoftEdge"
    Updates only Chrome and Edge.

.EXAMPLE
    .\Update-GoldImage.ps1 -Exclude "Bitwarden"
    Updates all apps except Bitwarden.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    All child scripts must be in their respective subdirectories relative to this script.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdate,

    [ValidateSet(
        "VCRedist", "PowerShell7", "MicrosoftEdge", "GoogleChrome", "FirefoxESR",
        "AdobeReaderDC", "Microsoft365Apps", "OneDrive", "MicrosoftTeams",
        "WebRTCRedirector", "NotepadPlusPlus", "Bitwarden"
    )]
    [string[]]$Only,

    [ValidateSet(
        "VCRedist", "PowerShell7", "MicrosoftEdge", "GoogleChrome", "FirefoxESR",
        "AdobeReaderDC", "Microsoft365Apps", "OneDrive", "MicrosoftTeams",
        "WebRTCRedirector", "NotepadPlusPlus", "Bitwarden"
    )]
    [string[]]$Exclude,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ── Paths ──────────────────────────────────────────────────────────────────────
$ScriptRoot = $PSScriptRoot
$LogFile    = Join-Path $LogPath "GoldImage-Update-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

if (-not (Test-Path $LogPath)) {
    New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
}

# ── Logging ────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
}

# ── Application Definitions ───────────────────────────────────────────────────
# Each entry: Name, DisplayName, ScriptRelativePath, SupportsSkipUpdate
$AppDefinitions = @(
    @{
        Name             = "VCRedist"
        DisplayName      = "VC++ 2015-2022 Redistributable"
        ScriptPath       = "VCRedist\Update-VCRedist.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "PowerShell7"
        DisplayName      = "PowerShell 7"
        ScriptPath       = "PowerShell7\Install-PowerShell7.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "MicrosoftEdge"
        DisplayName      = "Microsoft Edge"
        ScriptPath       = "MicrosoftEdge\Update-MicrosoftEdge.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "GoogleChrome"
        DisplayName      = "Google Chrome Enterprise"
        ScriptPath       = "GoogleChrome\Install-GoogleChrome.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "FirefoxESR"
        DisplayName      = "Mozilla Firefox ESR"
        ScriptPath       = "FirefoxESR\Install-FirefoxESR.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "AdobeReaderDC"
        DisplayName      = "Adobe Acrobat Reader DC"
        ScriptPath       = "AdobeReaderDC\Install-AdobeReaderDC.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "Microsoft365Apps"
        DisplayName      = "Microsoft 365 Apps"
        ScriptPath       = "Microsoft365Apps\Update-Microsoft365Apps.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "OneDrive"
        DisplayName      = "OneDrive"
        ScriptPath       = "OneDrive\Update-OneDrive.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "MicrosoftTeams"
        DisplayName      = "Microsoft Teams"
        ScriptPath       = "MicrosoftTeams\Update-MicrosoftTeams.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "WebRTCRedirector"
        DisplayName      = "WebRTC Redirector Service"
        ScriptPath       = "WebRTCRedirector\Update-WebRTCRedirector.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "NotepadPlusPlus"
        DisplayName      = "Notepad++"
        ScriptPath       = "NotepadPlusPlus\Install-NotepadPlusPlus.ps1"
        SupportsSkipUpdate = $true
    },
    @{
        Name             = "Bitwarden"
        DisplayName      = "Bitwarden"
        ScriptPath       = "Bitwarden\Install-Bitwarden.ps1"
        SupportsSkipUpdate = $true
    }
)

# ── Filter Applications ───────────────────────────────────────────────────────
if ($Only -and $Exclude) {
    Write-Log "Cannot use -Only and -Exclude together. Pick one." -Level ERROR
    exit 1
}

$AppsToRun = $AppDefinitions

if ($Only) {
    $AppsToRun = $AppDefinitions | Where-Object { $Only -contains $_.Name }
    Write-Log "Running ONLY: $($Only -join ', ')"
}

if ($Exclude) {
    $AppsToRun = $AppDefinitions | Where-Object { $Exclude -notcontains $_.Name }
    Write-Log "Excluding: $($Exclude -join ', ')"
}

if ($AppsToRun.Count -eq 0) {
    Write-Log "No applications selected to run." -Level WARN
    exit 0
}

# ── Banner ─────────────────────────────────────────────────────────────────────
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Log "============================================================"
Write-Log "  AVD Gold Image Update - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "============================================================"
Write-Log "Applications to process: $($AppsToRun.Count)"
Write-Log "SkipUpdate mode: $SkipUpdate"
Write-Log "Log file: $LogFile"
Write-Log "Script root: $ScriptRoot"
Write-Log "------------------------------------------------------------"

# ── Results Tracking ───────────────────────────────────────────────────────────
$Results = [System.Collections.ArrayList]::new()

# ── Execute Each Application ──────────────────────────────────────────────────
$appIndex = 0
foreach ($app in $AppsToRun) {
    $appIndex++
    $appStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $scriptFullPath = Join-Path $ScriptRoot $app.ScriptPath
    $status  = "UNKNOWN"
    $detail  = ""

    Write-Log ""
    Write-Log "============================================================"
    Write-Log "  [$appIndex/$($AppsToRun.Count)] $($app.DisplayName)"
    Write-Log "============================================================"

    # Verify the script exists
    if (-not (Test-Path $scriptFullPath)) {
        $status = "SKIPPED"
        $detail = "Script not found: $scriptFullPath"
        Write-Log $detail -Level WARN
    }
    else {
        try {
            # Build arguments
            $scriptArgs = @{}

            if ($SkipUpdate -and $app.SupportsSkipUpdate) {
                $scriptArgs['SkipUpdate'] = $true
            }

            Write-Log "Executing: $scriptFullPath"
            if ($scriptArgs.Count -gt 0) {
                Write-Log "Arguments: $($scriptArgs.Keys -join ', ')"
            }
            Write-Log "------------------------------------------------------------"

            # Execute the child script
            & $scriptFullPath @scriptArgs

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

# ── Summary Report ─────────────────────────────────────────────────────────────
$totalStopwatch.Stop()
$totalElapsed = $totalStopwatch.Elapsed.ToString("hh\:mm\:ss")

$successCount = ($Results | Where-Object { $_.Status -eq "SUCCESS" }).Count
$failedCount  = ($Results | Where-Object { $_.Status -eq "FAILED" }).Count
$skippedCount = ($Results | Where-Object { $_.Status -eq "SKIPPED" }).Count

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
        "SKIPPED" { "WARN" }
        default   { "INFO" }
    }
    Write-Log $line -Level $level

    if ($r.Status -eq "FAILED") {
        Write-Log "    -> $($r.Detail)" -Level ERROR
    }
}

Write-Log ""
Write-Log "------------------------------------------------------------"
Write-Log "Total: $($Results.Count) apps | $successCount succeeded | $failedCount failed | $skippedCount skipped"
Write-Log "Total elapsed time: $totalElapsed"
Write-Log "Log file: $LogFile"
Write-Log "============================================================"

# ── Exit Code ──────────────────────────────────────────────────────────────────
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
