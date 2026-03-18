<#
.SYNOPSIS
    Updates Microsoft 365 Apps and applies AVD Gold Image customizations.

.DESCRIPTION
    Triggers a silent Click-to-Run update for the installed Microsoft 365 Apps,
    then applies registry-based AVD/VDI optimizations. Designed for Gold Image
    maintenance where M365 Apps are already installed.

    Update behavior:
    - Detects installed version and update channel
    - Forces a silent update via OfficeC2RClient.exe
    - Optionally pins to a specific target version
    - Waits for the update to complete with progress monitoring

    AVD customizations applied:
    - Disables automatic updates (managed via Gold Image refresh)
    - Verifies Shared Computer Licensing is enabled
    - Hides update notifications and enable/disable toggle
    - Disables First Run Experience and Office animations
    - Disables hardware acceleration (better RDP/AVD performance)
    - Configures OneDrive silent sign-in and Known Folder Move
    - Removes desktop shortcuts

.PARAMETER TargetVersion
    Optional. Pin update to a specific build (e.g., "16.0.19530.20226").
    If omitted, updates to the latest version on the current channel.

.PARAMETER TenantId
    Azure AD / Entra ID tenant ID for OneDrive Known Folder Move.
    If omitted, KFM silent opt-in is skipped.

.PARAMETER SkipUpdate
    If specified, skips the Click-to-Run update and only applies customizations.

.PARAMETER LogPath
    Directory for log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Update-Microsoft365Apps.ps1
    Updates to the latest version on the current channel with AVD customizations.

.EXAMPLE
    .\Update-Microsoft365Apps.ps1 -TargetVersion "16.0.19530.20226"
    Updates to a specific build version.

.EXAMPLE
    .\Update-Microsoft365Apps.ps1 -SkipUpdate -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Applies AVD customizations only, including OneDrive KFM.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Requires Microsoft 365 Apps (Click-to-Run) to be already installed.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [string]$TargetVersion,

    [string]$TenantId,

    [switch]$SkipUpdate,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -- Constants -----------------------------------------------------------------

$AppName = "Microsoft 365 Apps"

# ClickToRun paths
$C2RConfigKey  = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
$C2RClientPath = "C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe"

# Channel friendly names (GUID -> name)
$ChannelNames = @{
    "492350f6-3a01-4f97-b9c0-c7c6ddf67d60" = "Current Channel"
    "55336b82-a18d-4dd6-b5f6-9e5095c314a6" = "Monthly Enterprise Channel"
    "b8f9b850-328d-4355-9145-c59439a0c4cf" = "Semi-Annual Enterprise Channel"
    "7ffbc6bf-bc32-4f92-8982-f9dd17fd3114" = "Semi-Annual Enterprise Channel (Preview)"
    "64256afe-f5d9-4f86-8936-8840a6a4f5be" = "Current Channel (Preview)"
    "5440fd1f-7ecb-4221-8110-145efaa6372f" = "Beta Channel"
}

# Update timeout (minutes)
$UpdateTimeoutMinutes = 60

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "Microsoft365Apps-Update.log"
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

function Get-M365InstallInfo {
    <#
    .SYNOPSIS
        Reads the current M365 Apps installation details from the registry.
    #>
    if (-not (Test-Path $C2RConfigKey)) {
        return $null
    }

    $config = Get-ItemProperty -Path $C2RConfigKey -ErrorAction SilentlyContinue
    $channelUrl = $null
    $channelGuid = $null
    $channelName = "Unknown"

    try { $channelUrl = $config.CDNBaseUrl } catch {}
    if ($channelUrl -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
        $channelGuid = $Matches[1]
        if ($ChannelNames.ContainsKey($channelGuid)) {
            $channelName = $ChannelNames[$channelGuid]
        }
    }

    $productIds = $null; try { $productIds = $config.ProductReleaseIds } catch {}
    $version    = $null; try { $version    = $config.VersionToReport  } catch {}
    $platform   = $null; try { $platform   = $config.Platform         } catch {}
    $scl        = $null; try { $scl        = $config.SharedComputerLicensing } catch {}

    return [PSCustomObject]@{
        ProductIds  = $productIds
        Version     = $version
        Platform    = $platform
        ChannelUrl  = $channelUrl
        ChannelGuid = $channelGuid
        ChannelName = $channelName
        SharedComputerLicensing = $scl
    }
}

function Invoke-M365Update {
    <#
    .SYNOPSIS
        Triggers a silent Click-to-Run update and waits for completion.
    #>
    param([string]$PinVersion)

    if (-not (Test-Path $C2RClientPath)) {
        throw "OfficeC2RClient.exe not found at: $C2RClientPath"
    }

    # Close any running Office apps
    $officeProcesses = @("WINWORD", "EXCEL", "POWERPNT", "OUTLOOK", "ONENOTE", "MSACCESS", "MSPUB", "lync", "ms-teams")
    foreach ($proc in $officeProcesses) {
        $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
        if ($running) {
            Write-Log "Closing $proc..."
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    # Build update command
    $arguments = "/update user updatepromptuser=false forceappshutdown=true displaylevel=false"
    if ($PinVersion) {
        $arguments += " updatetoversion=$PinVersion"
        Write-Log "Pinning update to version: $PinVersion"
    }

    Write-Log "Executing: OfficeC2RClient.exe $arguments"
    $updateProcess = Start-Process -FilePath $C2RClientPath -ArgumentList $arguments -PassThru -NoNewWindow

    # Monitor the update process
    Write-Log "Update initiated. Monitoring progress (timeout: $UpdateTimeoutMinutes minutes)..."
    $startTime = Get-Date
    $lastVersion = (Get-M365InstallInfo).Version

    # Wait for the OfficeC2RClient process to finish
    $completed = $updateProcess.WaitForExit(($UpdateTimeoutMinutes * 60 * 1000))

    if (-not $completed) {
        Write-Log "Update process did not exit within $UpdateTimeoutMinutes minutes." -Level WARN
        try { $updateProcess | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
        return $false
    }

    Write-Log "OfficeC2RClient.exe exited with code: $($updateProcess.ExitCode)"

    # The C2R client spawns background processes. Wait for OfficeClickToRun.exe to finish updating.
    $waitStart = Get-Date
    $maxWaitMinutes = 30
    while (((Get-Date) - $waitStart).TotalMinutes -lt $maxWaitMinutes) {
        $c2rService = Get-Process -Name "OfficeClickToRun" -ErrorAction SilentlyContinue
        if (-not $c2rService) { break }

        # Check if version has changed
        $currentInfo = Get-M365InstallInfo
        if ($currentInfo.Version -ne $lastVersion) {
            Write-Log "Version changed from $lastVersion to $($currentInfo.Version)"
            break
        }

        Start-Sleep -Seconds 10
    }

    return $true
}

function Set-M365AVDCustomizations {
    <#
    .SYNOPSIS
        Applies registry-based customizations optimized for AVD Gold Images.
        Each operation is independent so a single failure does not block the rest.
    #>
    Write-Log "Applying AVD Gold Image customizations for Microsoft 365 Apps..."

    # -- Disable Automatic Updates (managed via Gold Image refresh) --
    $updatePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\OfficeUpdate"
    Set-RegistryValue -Path $updatePolicyPath -Name "EnableAutomaticUpdates" -Value 0
    Set-RegistryValue -Path $updatePolicyPath -Name "HideUpdateNotifications" -Value 1
    Set-RegistryValue -Path $updatePolicyPath -Name "HideEnableDisableUpdates" -Value 1

    # -- Verify / Enforce Shared Computer Licensing --
    try {
        $sclValue = (Get-ItemProperty -Path $C2RConfigKey -ErrorAction SilentlyContinue).SharedComputerLicensing
        if ($sclValue -ne "1") {
            Set-RegistryValue -Path $C2RConfigKey -Name "SharedComputerLicensing" -Value "1" -Type String
            Write-Log "Shared Computer Licensing was not enabled - now set to 1."
        } else {
            Write-Log "Shared Computer Licensing already enabled."
        }
    } catch {
        Set-RegistryValue -Path $C2RConfigKey -Name "SharedComputerLicensing" -Value "1" -Type String
        Write-Log "Set Shared Computer Licensing to 1 (could not read previous value)."
    }

    # -- Disable First Run and animations --
    $officePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\General"
    Set-RegistryValue -Path $officePolicyPath -Name "ShownFirstRunOptin" -Value 1
    Set-RegistryValue -Path $officePolicyPath -Name "DisableMovie" -Value 1

    $firstRunPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\FirstRun"
    Set-RegistryValue -Path $firstRunPath -Name "DisableMovie" -Value 1
    Set-RegistryValue -Path $firstRunPath -Name "BootedRTM" -Value 1

    # -- Disable hardware graphics acceleration (better RDP/AVD performance) --
    $graphicsPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Graphics"
    Set-RegistryValue -Path $graphicsPath -Name "DisableHardwareAcceleration" -Value 1

    # -- Disable Office telemetry --
    $telemetryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\Common\ClientTelemetry"
    Set-RegistryValue -Path $telemetryPath -Name "DisableTelemetry" -Value 1

    $feedbackPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Feedback"
    Set-RegistryValue -Path $feedbackPath -Name "Enabled" -Value 0
    Set-RegistryValue -Path $feedbackPath -Name "SurveyEnabled" -Value 0
    Set-RegistryValue -Path $feedbackPath -Name "IncludeEmail" -Value 0

    # -- Disable connected experiences (privacy) --
    $privacyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Privacy"
    Set-RegistryValue -Path $privacyPath -Name "DisconnectedState" -Value 2
    Set-RegistryValue -Path $privacyPath -Name "UserContentDisabled" -Value 2
    Set-RegistryValue -Path $privacyPath -Name "DownloadContentDisabled" -Value 2
    Set-RegistryValue -Path $privacyPath -Name "ControllerConnectedServicesEnabled" -Value 2

    # -- OneDrive: silent sign-in and per-machine mode --
    $oneDrivePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive"
    Set-RegistryValue -Path $oneDrivePolicyPath -Name "SilentAccountConfig" -Value 1

    # Known Folder Move (if TenantId provided)
    if ($TenantId) {
        Set-RegistryValue -Path $oneDrivePolicyPath -Name "KFMSilentOptIn" -Value $TenantId -Type String
        Write-Log "OneDrive KFM configured for tenant: $TenantId"
    }

    # -- Outlook: cached mode optimizations for VDI --
    $outlookPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Outlook\Cached Mode"
    Set-RegistryValue -Path $outlookPath -Name "Enable" -Value 1
    Set-RegistryValue -Path $outlookPath -Name "SyncWindowSetting" -Value 1
    Set-RegistryValue -Path $outlookPath -Name "CalendarSyncWindowSetting" -Value 1
    # SyncWindowSetting 1 = 1 month of email cached (reduces profile size)

    # -- Disable LinkedIn integration --
    $linkedInPath = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\LinkedIn"
    Set-RegistryValue -Path $linkedInPath -Name "DisableLinkedInFeatures" -Value 1

    # -- Remove Desktop Shortcuts --
    # Note: Edge and Teams shortcuts are handled by their own installer scripts
    $desktopShortcuts = @(
        "$env:PUBLIC\Desktop\Excel.lnk",
        "$env:PUBLIC\Desktop\Outlook.lnk",
        "$env:PUBLIC\Desktop\PowerPoint.lnk",
        "$env:PUBLIC\Desktop\Word.lnk",
        "$env:PUBLIC\Desktop\OneNote.lnk",
        "$env:PUBLIC\Desktop\Access.lnk",
        "$env:PUBLIC\Desktop\Publisher.lnk",
        "$env:PUBLIC\Desktop\Visio.lnk"
    )
    foreach ($shortcut in $desktopShortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "Removed shortcut: $shortcut"
        }
    }

    # -- Disable Office scheduled tasks that are unnecessary on Gold Images --
    $tasks = @(
        "Office Automatic Updates 2.0",
        "Office ClickToRun Service Monitor",
        "Office Feature Updates",
        "Office Feature Updates Logon"
    )
    foreach ($task in $tasks) {
        try {
            $existingTask = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
            if ($existingTask) {
                $existingTask | Disable-ScheduledTask -ErrorAction Stop | Out-Null
                Write-Log "Disabled scheduled task: $task"
            }
        } catch {
            Write-Log "Failed to disable task '$task': $($_.Exception.Message)" -Level WARN
        }
    }

    Write-Log "AVD customizations applied successfully."
}

# -- Main Execution ------------------------------------------------------------

try {
    Write-Log "================================================================="
    Write-Log "$AppName Updater for AVD Gold Images"
    Write-Log "================================================================="

    # Detect current installation
    $installed = Get-M365InstallInfo
    if (-not $installed) {
        throw "Microsoft 365 Apps (Click-to-Run) installation not detected."
    }

    Write-Log "Products:  $($installed.ProductIds)"
    Write-Log "Version:   $($installed.Version)"
    Write-Log "Channel:   $($installed.ChannelName)"
    Write-Log "Platform:  $($installed.Platform)"
    Write-Log "SCL:       $($installed.SharedComputerLicensing)"

    # Perform update
    if (-not $SkipUpdate) {
        Write-Log "-----------------------------------------------------------------"
        Write-Log "Starting Click-to-Run update..."

        $preVersion = $installed.Version
        $success = Invoke-M365Update -PinVersion $TargetVersion

        # Re-read version after update
        $postInstall = Get-M365InstallInfo
        if ($postInstall.Version -ne $preVersion) {
            Write-Log "Updated: $preVersion -> $($postInstall.Version)"
        } elseif ($success) {
            Write-Log "Already at latest version: $($postInstall.Version)"
        } else {
            Write-Log "Update may not have completed successfully." -Level WARN
        }
    } else {
        Write-Log "Skipping update (SkipUpdate specified). Applying customizations only."
    }

    # Apply AVD customizations
    Write-Log "-----------------------------------------------------------------"
    Set-M365AVDCustomizations

    # Final verification
    Write-Log "-----------------------------------------------------------------"
    $finalInfo = Get-M365InstallInfo
    Write-Log "Final version: $($finalInfo.Version)"
    Write-Log "Channel:       $($finalInfo.ChannelName)"
    Write-Log "SCL:           $($finalInfo.SharedComputerLicensing)"

    Write-Log "================================================================="
    Write-Log "$AppName update and customization completed successfully."
    Write-Log "================================================================="
    exit 0

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
