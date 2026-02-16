<#
.SYNOPSIS
    Installs or updates Adobe Acrobat Reader DC for AVD Gold Images.

.DESCRIPTION
    Downloads and silently installs Adobe Acrobat Reader DC (64-bit) with
    AVD/VDI-optimized customizations. Handles both fresh installs (base + patch)
    and updates (patch only) to existing installations.

    Customizations applied:
    - Disables automatic updates (ARM service not installed)
    - Suppresses EULA, registration, and welcome screens
    - Removes desktop shortcut
    - Disables telemetry and usage statistics
    - Disables cloud services and online features
    - Configures Protected Mode for AppContainer (AVD compatibility)

.PARAMETER Architecture
    Target architecture: "x64" (default) or "x86".

.PARAMETER BaseVersion
    The base installer version string (e.g., "2500120432"). Only needed for
    fresh installs when no existing Reader installation is detected.

.PARAMETER UpdateVersion
    The update/patch version string (e.g., "2500121208"). If omitted, the
    script queries Adobe's release notes page for the latest version.

.PARAMETER DownloadPath
    Directory to download installers into. Defaults to $env:TEMP\AdobeReaderDC.

.PARAMETER KeepInstallers
    If specified, downloaded installer files are not cleaned up after install.

.PARAMETER LogPath
    Directory for installation log files. Defaults to $env:SystemRoot\Logs\Software.

.EXAMPLE
    .\Install-AdobeReaderDC.ps1
    Detects current state and installs/updates to the latest version (64-bit).

.EXAMPLE
    .\Install-AdobeReaderDC.ps1 -Architecture x86 -KeepInstallers
    Installs/updates 32-bit Reader and retains downloaded files.

.NOTES
    Designed for AVD Gold Image maintenance. Run as Administrator.
    Author: Falcon Network Services LLC
#>

[CmdletBinding()]
param(
    [ValidateSet("x64", "x86")]
    [string]$Architecture = "x64",

    [string]$BaseVersion = "2500120432",

    [string]$UpdateVersion,

    [string]$DownloadPath = "$env:TEMP\AdobeReaderDC",

    [switch]$KeepInstallers,

    [string]$LogPath = "$env:SystemRoot\Logs\Software"
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Speeds up Invoke-WebRequest

# -- Constants -----------------------------------------------------------------

$AppName = "Adobe Acrobat Reader DC"

# Download URL templates (ardownload3.adobe.com)
if ($Architecture -eq "x64") {
    $BaseUrlTemplate   = "https://ardownload3.adobe.com/pub/adobe/acrobat/win/AcrobatDC/{0}/AcroRdrDCx64{0}_en_US.exe"
    $UpdateUrlTemplate = "https://ardownload3.adobe.com/pub/adobe/acrobat/win/AcrobatDC/{0}/AcroRdrDCx64Upd{0}.msp"
} else {
    $BaseUrlTemplate   = "https://ardownload3.adobe.com/pub/adobe/reader/win/AcrobatDC/{0}/AcroRdrDC{0}_en_US.exe"
    $UpdateUrlTemplate = "https://ardownload3.adobe.com/pub/adobe/reader/win/AcrobatDC/{0}/AcroRdrDCUpd{0}.msp"
}

# Registry paths for customization (covers both full Acrobat and Acrobat Reader)
$PolicyPaths = @(
    "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown",
    "HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown"
)
$SettingsPaths = @(
    "HKLM:\SOFTWARE\Adobe\Adobe Acrobat\DC",
    "HKLM:\SOFTWARE\Adobe\Acrobat Reader\DC"
)

# Detection registry path
$UninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

# -- Functions -----------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry

    if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }
    $logFile = Join-Path $LogPath "AdobeReaderDC-Install.log"
    Add-Content -Path $logFile -Value $entry
}

function Get-InstalledReaderVersion {
    <#
    .SYNOPSIS
        Detects the currently installed Adobe Acrobat Reader DC version.
    #>
    foreach ($path in $UninstallPaths) {
        if (-not (Test-Path $path)) { continue }
        $keys = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
        foreach ($key in $keys) {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }

            $displayName = $null
            try { $displayName = $props.DisplayName } catch { continue }
            if ([string]::IsNullOrEmpty($displayName)) { continue }

            if ($displayName -match "Adobe Acrobat") {
                $displayVersion  = $null; try { $displayVersion  = $props.DisplayVersion  } catch {}
                $uninstallString = $null; try { $uninstallString = $props.UninstallString } catch {}
                return [PSCustomObject]@{
                    DisplayName     = $displayName
                    DisplayVersion  = $displayVersion
                    UninstallString = $uninstallString
                    PSPath          = $key.PSPath
                }
            }
        }
    }
    return $null
}

function Get-LatestReaderVersion {
    <#
    .SYNOPSIS
        Scrapes the Adobe enterprise release notes index to find the latest
        continuous-track version number.
    #>
    Write-Log "Querying Adobe release notes for latest version..."
    try {
        $uri = "https://www.adobe.com/devnet-docs/acrobatetk/tools/ReleaseNotesDC/index.html"
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 30

        # Match version patterns like "25.001.21208"
        $matches = [regex]::Matches($response.Content, '(\d{2}\.\d{3}\.\d{5})')
        if ($matches.Count -gt 0) {
            # Versions are listed newest-first; take the first match
            $latestDotted = $matches[0].Value
            # Convert dotted version to flat format: "25.001.21208" -> "2500121208"
            $latestFlat = $latestDotted -replace '\.', ''
            Write-Log "Latest version detected: $latestDotted ($latestFlat)"
            return $latestFlat
        }
    } catch {
        Write-Log "Failed to query release notes: $($_.Exception.Message)" -Level WARN
    }
    return $null
}

function Start-FileDownload {
    param(
        [string]$Uri,
        [string]$OutFile
    )
    Write-Log "Downloading: $Uri"
    Write-Log "Destination: $OutFile"

    try {
        # Use BITS if available (faster, resumes), fall back to Invoke-WebRequest
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

function Install-ReaderBase {
    <#
    .SYNOPSIS
        Installs the Adobe Reader DC base installer (EXE) silently.
    #>
    param([string]$InstallerPath)

    Write-Log "Starting base installation from: $InstallerPath"
    $arguments = @(
        "/sAll"
        "/rs"
        "/msi"
        "EULA_ACCEPT=YES"
        "SUPPRESS_APP_LAUNCH=YES"
        "DISABLEDESKTOPSHORTCUT=1"
        "DISABLE_ARM_SERVICE_INSTALL=1"
        "/L*v `"$(Join-Path $LogPath 'AdobeReaderDC-BaseInstall.log')`""
    )

    $process = Start-Process -FilePath $InstallerPath -ArgumentList ($arguments -join " ") -Wait -PassThru -NoNewWindow
    Write-Log "Base installer exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 1618 -and $process.ExitCode -ne 3010) {
        throw "$AppName base installation failed with exit code $($process.ExitCode)"
    }
    return $process.ExitCode
}

function Install-ReaderUpdate {
    <#
    .SYNOPSIS
        Applies an Adobe Reader DC update patch (MSP) silently.
    #>
    param([string]$PatchPath)

    Write-Log "Applying update patch: $PatchPath"
    $logFile = Join-Path $LogPath "AdobeReaderDC-Update.log"
    $arguments = "/p `"$PatchPath`" /qn /norestart /L*v `"$logFile`""

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    Write-Log "Update patch exit code: $($process.ExitCode)"

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 1618 -and $process.ExitCode -ne 3010) {
        throw "$AppName update failed with exit code $($process.ExitCode)"
    }
    return $process.ExitCode
}

function Set-ReaderAVDCustomizations {
    <#
    .SYNOPSIS
        Applies registry-based customizations optimized for AVD Gold Images.
        Each operation is independent so a single failure does not block the rest.
    #>
    Write-Log "Applying AVD Gold Image customizations..."

    # Helper to ensure a registry path exists and set a value.
    # Uses its own error handling so one failed write never blocks subsequent writes.
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

    # Apply policy and settings customizations to both Acrobat and Reader paths
    # (whichever product is installed, the correct keys get written)
    foreach ($polPath in $PolicyPaths) {
        Write-Log "Applying policies to: $polPath"

        # Disable Automatic Updates
        Set-RegistryValue -Path $polPath -Name "bUpdater" -Value 0
        Set-RegistryValue -Path $polPath -Name "bAcroSuppressUpsell" -Value 1

        # Disable Usage Statistics / Telemetry
        Set-RegistryValue -Path $polPath -Name "bUsageMeasurement" -Value 0
        Set-RegistryValue -Path "$polPath\cServices" -Name "bToggleAdobeDocumentServices" -Value 1
        Set-RegistryValue -Path "$polPath\cServices" -Name "bToggleAdobeSign" -Value 1
        Set-RegistryValue -Path "$polPath\cServices" -Name "bToggleSendAndTrack" -Value 1
        Set-RegistryValue -Path "$polPath\cServices" -Name "bToggleWebConnectors" -Value 1
        Set-RegistryValue -Path "$polPath\cServices" -Name "bTogglePrefsSync" -Value 1
        Set-RegistryValue -Path "$polPath\cServices" -Name "bToggleNotifications" -Value 1
        Set-RegistryValue -Path "$polPath\cServices" -Name "bAdobeSendPluginToggle" -Value 1
        Set-RegistryValue -Path "$polPath\cServices" -Name "bUpdater" -Value 0

        # Disable Cloud Services / Online Features
        Set-RegistryValue -Path "$polPath\cCloud" -Name "bAdobeSendPluginToggle" -Value 1
        Set-RegistryValue -Path "$polPath\cSharePoint" -Name "bDisableSharePointFeatures" -Value 1

        # Disable Welcome Screen
        Set-RegistryValue -Path "$polPath\cWelcomeScreen" -Name "bShowWelcomeScreen" -Value 0

        # AppContainer Compatibility (AVD-specific)
        # Prevents the "incompatible with AppContainer" warning in AVD sessions
        Set-RegistryValue -Path $polPath -Name "bEnableProtectedModeAppContainer" -Value 0

        # Protected View: Off for AVD performance
        Set-RegistryValue -Path "$polPath\cTrustManager" -Name "iProtectedView" -Value 0
    }

    foreach ($setPath in $SettingsPaths) {
        Write-Log "Applying settings to: $setPath"

        # Suppress EULA
        Set-RegistryValue -Path "$setPath\AdobeViewer" -Name "EULA" -Value 1

        # Suppress optional component download prompts
        Set-RegistryValue -Path "$setPath\AVAlert\cCheckbox" -Name "iDigSigDwnldOptionalComps" -Value 0
    }

    # Disable Adobe Updater (ARM) Service
    try {
        $armService = Get-Service -Name "AdobeARMservice" -ErrorAction SilentlyContinue
        if ($armService) {
            Stop-Service -Name "AdobeARMservice" -Force -ErrorAction Stop
            Set-Service -Name "AdobeARMservice" -StartupType Disabled -ErrorAction Stop
            Write-Log "AdobeARMservice stopped and set to Disabled."
        } else {
            Write-Log "AdobeARMservice not found (OK if DISABLE_ARM_SERVICE_INSTALL was used)."
        }
    } catch {
        Write-Log "Failed to disable AdobeARMservice: $($_.Exception.Message)" -Level WARN
    }

    # Remove Desktop Shortcuts
    $desktopShortcuts = @(
        "$env:PUBLIC\Desktop\Adobe Acrobat.lnk",
        "$env:PUBLIC\Desktop\Adobe Acrobat Reader.lnk",
        "$env:PUBLIC\Desktop\Adobe Acrobat Reader DC.lnk",
        "C:\Users\Default\Desktop\Adobe Acrobat.lnk",
        "C:\Users\Default\Desktop\Adobe Acrobat Reader.lnk",
        "C:\Users\Default\Desktop\Adobe Acrobat Reader DC.lnk"
    )
    foreach ($shortcut in $desktopShortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -ErrorAction SilentlyContinue
            Write-Log "Removed shortcut: $shortcut"
        }
    }

    # Disable Scheduled Tasks
    $tasks = @(
        "Adobe Acrobat Update Task",
        "AdobeGCInvoker-1.0"
    )
    foreach ($task in $tasks) {
        try {
            $existingTask = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
            if ($existingTask) {
                Disable-ScheduledTask -TaskName $task -ErrorAction Stop | Out-Null
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
    Write-Log "$AppName Installer/Updater for AVD Gold Images"
    Write-Log "Architecture: $Architecture"
    Write-Log "================================================================="

    # Ensure download directory exists
    if (-not (Test-Path $DownloadPath)) {
        New-Item -Path $DownloadPath -ItemType Directory -Force | Out-Null
    }

    # Detect current installation
    $installed = Get-InstalledReaderVersion
    if ($installed) {
        Write-Log "Detected installed version: $($installed.DisplayName) - $($installed.DisplayVersion)"
    } else {
        Write-Log "No existing Adobe Reader DC installation detected."
    }

    # Resolve target update version
    if (-not $UpdateVersion) {
        $UpdateVersion = Get-LatestReaderVersion
        if (-not $UpdateVersion -or $UpdateVersion -notmatch '^\d{10}$') {
            Write-Log "Auto-detection failed or returned invalid value. Falling back to customizations only." -Level WARN
            $UpdateVersion = $null
        }
    }
    if ($UpdateVersion) {
        Write-Log "Target update version: $UpdateVersion"
    }

    # Install/Update only if we have a valid target version
    if ($UpdateVersion) {
        # Fresh Install Path
        if (-not $installed) {
            Write-Log "Performing fresh installation..."

            # Download base installer
            $baseUrl = $BaseUrlTemplate -f $BaseVersion
            $baseFile = Join-Path $DownloadPath (Split-Path $baseUrl -Leaf)
            Start-FileDownload -Uri $baseUrl -OutFile $baseFile

            # Install base
            $exitCode = Install-ReaderBase -InstallerPath $baseFile
            Write-Log "Base installation completed (exit code: $exitCode)."

            # Download and apply update patch if update version differs from base
            if ($UpdateVersion -ne $BaseVersion) {
                $updateUrl = $UpdateUrlTemplate -f $UpdateVersion
                $updateFile = Join-Path $DownloadPath (Split-Path $updateUrl -Leaf)
                Start-FileDownload -Uri $updateUrl -OutFile $updateFile
                $exitCode = Install-ReaderUpdate -PatchPath $updateFile
                Write-Log "Update patch applied (exit code: $exitCode)."
            }
        }
        # Update Path
        else {
            Write-Log "Performing update..."
            $updateUrl = $UpdateUrlTemplate -f $UpdateVersion
            $updateFile = Join-Path $DownloadPath (Split-Path $updateUrl -Leaf)
            Start-FileDownload -Uri $updateUrl -OutFile $updateFile
            $exitCode = Install-ReaderUpdate -PatchPath $updateFile
            Write-Log "Update applied (exit code: $exitCode)."
        }
    } else {
        Write-Log "Skipping install/update (no valid version resolved). Applying customizations only."
    }

    # Apply AVD customizations
    Set-ReaderAVDCustomizations

    # Verify final installation
    $finalVersion = Get-InstalledReaderVersion
    if ($finalVersion) {
        Write-Log "Verified installation: $($finalVersion.DisplayName) - $($finalVersion.DisplayVersion)"
    } else {
        Write-Log "WARNING: Could not verify installation after completion." -Level WARN
    }

    # Cleanup
    if (-not $KeepInstallers -and (Test-Path $DownloadPath)) {
        Remove-Item -Path $DownloadPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned up download directory."
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
