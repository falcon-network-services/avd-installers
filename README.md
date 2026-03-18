# AVD Gold Image Application Scripts

PowerShell scripts for maintaining Azure Virtual Desktop (AVD) Gold Images. Each script downloads the latest version of an application, installs it silently, disables auto-update mechanisms, and applies AVD/VDI optimizations.

## Quick Start

```powershell
# Update all 12 applications in one run
.\Update-GoldImage.ps1

# Update specific apps only
.\Update-GoldImage.ps1 -Only "GoogleChrome", "MicrosoftEdge"

# Apply customizations without downloading or installing
.\Update-GoldImage.ps1 -SkipUpdate
```

> All scripts require **Run as Administrator**. Logs are written to `%SystemRoot%\Logs\Software\`.

## Repository Structure

```
AVD-Gold-Image-Apps/
├── Update-GoldImage.ps1              # Master orchestrator
├── README.md
├── AdobeReaderDC/
│   └── Update-AdobeReaderDC.ps1
├── Bitwarden/
│   └── Update-Bitwarden.ps1
├── FirefoxESR/
│   └── Update-FirefoxESR.ps1
├── GoogleChrome/
│   └── Update-GoogleChrome.ps1
├── Microsoft365Apps/
│   └── Update-Microsoft365Apps.ps1
├── MicrosoftEdge/
│   └── Update-MicrosoftEdge.ps1
├── MicrosoftTeams/
│   └── Update-MicrosoftTeams.ps1
├── NotepadPlusPlus/
│   └── Update-NotepadPlusPlus.ps1
├── OneDrive/
│   └── Update-OneDrive.ps1
├── PowerShell7/
│   └── Update-PowerShell7.ps1
├── VCRedist/
│   └── Update-VCRedist.ps1
└── WebRTCRedirector/
    └── Update-WebRTCRedirector.ps1
```

## Master Orchestrator

**`Update-GoldImage.ps1`** runs all 12 application scripts sequentially in dependency order. Each application is wrapped in its own error boundary so a failure in one does not block the rest.

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `-SkipUpdate` | Switch | Pass `-SkipUpdate` to all child scripts (customizations only, no downloads) |
| `-Only` | String[] | Run only the specified apps (tab-completable) |
| `-Exclude` | String[] | Run all apps except the specified ones (tab-completable) |
| `-LogPath` | String | Log directory (default: `%SystemRoot%\Logs\Software`) |

### Execution Order

The orchestrator runs applications in this order, optimized for dependencies:

| # | Application | Reason for Position |
|---|---|---|
| 1 | VC++ 2015-2022 Redistributable | Runtime dependency for many applications |
| 2 | PowerShell 7 | Core tooling |
| 3 | Microsoft Edge | Browser |
| 4 | Google Chrome Enterprise | Browser |
| 5 | Mozilla Firefox ESR | Browser |
| 6 | Adobe Acrobat Reader DC | Productivity |
| 7 | Microsoft 365 Apps | Office suite |
| 8 | OneDrive | File sync (pairs with M365) |
| 9 | Microsoft Teams | Communication (depends on WebView2, VC++) |
| 10 | WebRTC Redirector Service | Teams media optimization |
| 11 | Notepad++ | Developer tooling |
| 12 | Bitwarden | Password manager |

### Output

The orchestrator produces a summary report at the end of each run:

```
============================================================
  SUMMARY REPORT
============================================================

#    Application                         Status    Duration
------------------------------------------------------------
1    VC++ 2015-2022 Redistributable      SUCCESS   01:12
2    PowerShell 7                        SUCCESS   00:45
3    Microsoft Edge                      SUCCESS   01:30
...
------------------------------------------------------------
Total: 12 apps | 12 succeeded | 0 failed | 0 skipped
Total elapsed time: 00:14:22
```

### Valid App Names

Use these names with `-Only` and `-Exclude`:

`VCRedist`, `PowerShell7`, `MicrosoftEdge`, `GoogleChrome`, `FirefoxESR`, `AdobeReaderDC`, `Microsoft365Apps`, `OneDrive`, `MicrosoftTeams`, `WebRTCRedirector`, `NotepadPlusPlus`, `Bitwarden`

---

## Individual Application Scripts

### Adobe Acrobat Reader DC

**Script:** `AdobeReaderDC\Update-AdobeReaderDC.ps1`

Downloads and installs Adobe Acrobat Reader DC. Handles both fresh installs (base installer + patch) and updates (patch only) to existing installations.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Architecture` | String | `x64` | Target architecture: `x64` or `x86` |
| `-BaseVersion` | String | `2500120432` | Base installer version for fresh installs |
| `-UpdateVersion` | String | *(auto-detect)* | Specific patch version, or auto-detects latest |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Version detection:** Scrapes Adobe's enterprise release notes page for the latest patch version.

**Customizations applied:**
- Disables automatic updates (ARM service not installed)
- Suppresses EULA, registration, and welcome screens
- Disables telemetry and usage statistics
- Disables cloud services and online features
- Configures Protected Mode for AppContainer (AVD compatibility)
- Removes desktop shortcut

---

### Bitwarden

**Script:** `Bitwarden\Update-Bitwarden.ps1`

Downloads the latest Bitwarden desktop client from GitHub Releases and installs it silently.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipUpdate` | Switch | | Skip download/install, apply customizations only |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Version detection:** GitHub Releases API for `bitwarden/clients` repository, filters for `desktop-v*` tagged releases.

**Auto-update lockdown:**
- Sets `ELECTRON_NO_UPDATER=1` system environment variable (disables Squirrel auto-updater)
- Broadcasts `WM_SETTINGCHANGE` to propagate environment variable immediately
- Removes desktop shortcut

---

### Mozilla Firefox ESR

**Script:** `FirefoxESR\Update-FirefoxESR.ps1`

Downloads and installs Mozilla Firefox ESR (Extended Support Release) via the official MSI installer.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipUpdate` | Switch | | Skip download/install, apply customizations only |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Version detection:** Mozilla product-details API (`FIREFOX_ESR` field).

**Download URL:** `https://download.mozilla.org/?product=firefox-esr-msi-latest-ssl&os=win64&lang=en-US`

**Auto-update lockdown (registry policies):**
- `DisableAppUpdate`, `DisableTelemetry`, `DisableFirefoxStudies`
- `DisableDefaultBrowserAgent`, `DontCheckDefaultBrowser`
- `DisablePocket`, `DisableFirefoxAccounts`, `DisableFeedbackCommands`
- Blank `OverrideFirstRunPage` and `OverridePostUpdatePage`
- Stops and disables the Mozilla Maintenance Service

---

### Google Chrome Enterprise

**Script:** `GoogleChrome\Update-GoogleChrome.ps1`

Downloads and installs the Google Chrome Standalone Enterprise MSI (64-bit).

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipUpdate` | Switch | | Skip download/install, apply customizations only |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Version detection:** Google VersionHistory API (`chrome/platforms/win64/channels/stable`).

**Download URL:** `https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi`

**Auto-update lockdown:**
- Google Update policies: `AutoUpdateCheckPeriodMinutes=0`, `UpdateDefault=0`
- Disables services: `gupdate`, `gupdatem`, `GoogleUpdaterService`, `GoogleUpdaterInternalService`
- Chrome policies: disables background mode, metrics reporting, startup boost, browser sign-in, sync, Shopping list, Search side panel, tab hover card images
- Removes desktop shortcut

---

### Microsoft 365 Apps

**Script:** `Microsoft365Apps\Update-Microsoft365Apps.ps1`

Triggers a silent Click-to-Run update for the installed Microsoft 365 Apps, then applies AVD optimizations. Requires M365 Apps to already be installed.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-TargetVersion` | String | *(latest)* | Pin to a specific build (e.g., `16.0.19530.20226`) |
| `-TenantId` | String | | Entra ID tenant ID for OneDrive Known Folder Move |
| `-SkipUpdate` | Switch | | Skip the C2R update, apply customizations only |

**Update method:** Invokes `OfficeC2RClient.exe` with silent update arguments and monitors progress.

**Customizations applied:**
- Disables automatic updates
- Verifies Shared Computer Licensing is enabled
- Hides update notifications
- Disables First Run Experience and Office animations
- Disables hardware acceleration (better RDP/AVD performance)
- Configures OneDrive silent sign-in and Known Folder Move (when TenantId provided)
- Removes desktop shortcuts

---

### Microsoft Edge

**Script:** `MicrosoftEdge\Update-MicrosoftEdge.ps1`

Downloads the latest Microsoft Edge Stable MSI from Microsoft's enterprise endpoint and installs it silently.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Architecture` | String | `x64` | Target architecture: `x64` or `x86` |
| `-SkipUpdate` | Switch | | Skip download/install, apply customizations only |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Version detection:** Edge enterprise releases API (`edgeupdates.microsoft.com/api/products`).

**Auto-update lockdown:**
- Disables `edgeupdate` and `edgeupdatem` services
- Disables Edge update scheduled tasks
- Sets EdgeUpdate group policy to disable auto-updates
- Removes desktop shortcut

---

### Microsoft Teams

**Script:** `MicrosoftTeams\Update-MicrosoftTeams.ps1`

Downloads the Teams bootstrapper and provisions the latest Teams MSIX package for all users (new Teams v2, per-machine).

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipUpdate` | Switch | | Skip download/install, apply customizations only |
| `-OfflineMsix` | String | | Path to a local MSIX file for offline installation |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Update method:** `teamsbootstrapper.exe -p` for per-machine MSIX provisioning. Detects installed version via `Get-AppxProvisionedPackage`.

**Download URL:** `https://go.microsoft.com/fwlink/?linkid=2243204`

**Auto-update lockdown:**
- Sets `HKLM:\SOFTWARE\Microsoft\Teams\disableAutoUpdate = 1`
- Removes desktop shortcut

> This script will also install Teams on a new Gold Image where Teams is not yet present.

---

### Notepad++

**Script:** `NotepadPlusPlus\Update-NotepadPlusPlus.ps1`

Downloads the latest Notepad++ x64 installer from GitHub Releases and installs it silently.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipUpdate` | Switch | | Skip download/install, apply customizations only |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Version detection:** GitHub Releases API for `notepad-plus-plus/notepad-plus-plus`.

**Auto-update lockdown:**
- Modifies config XML to disable auto-update checks
- Removes GUP.exe (built-in updater plugin)
- Removes desktop shortcut

---

### OneDrive

**Script:** `OneDrive\Update-OneDrive.ps1`

Downloads the latest OneDrive per-machine installer from Microsoft and installs it silently.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-TenantId` | String | | Entra ID tenant ID for Known Folder Move |
| `-SkipUpdate` | Switch | | Skip download/install, apply customizations only |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Install method:** `OneDriveSetup.exe /allusers /silent` for per-machine installation (required for AVD).

**Auto-update lockdown:**
- Disables OneDrive Updater Service
- Disables OneDrive update scheduled tasks
- Sets registry policy to prevent self-update
- Configures OneDrive for AVD/VDI (silent sign-in, per-machine mode)

---

### PowerShell 7

**Script:** `PowerShell7\Update-PowerShell7.ps1`

Downloads the latest PowerShell 7 MSI from GitHub Releases and installs it silently.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipUpdate` | Switch | | Skip download/install, apply customizations only |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Version detection:** GitHub Releases API for `PowerShell/PowerShell`. Uses `FileVersion` (not `ProductVersion`, which includes a SHA hash).

**MSI properties:** `ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1`, `REGISTER_MANIFEST=1`, `ADD_PATH=1`, `ENABLE_PSREMOTING=1`, `USE_MU=0`, `ENABLE_MU=0`

**Auto-update lockdown:**
- Sets `POWERSHELL_UPDATECHECK=Off` system environment variable
- `USE_MU=0` and `ENABLE_MU=0` disable Microsoft Update delivery
- Broadcasts `WM_SETTINGCHANGE` to propagate environment variable immediately

---

### VC++ 2015-2022 Redistributable

**Script:** `VCRedist\Update-VCRedist.ps1`

Downloads and installs the latest Visual C++ 2015-2022 Redistributable (both x64 and x86).

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipUpdate` | Switch | | Skip download/install (detection only) |
| `-x64Only` | Switch | | Only install the x64 redistributable |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Download URLs:**
- `https://aka.ms/vs/17/release/vc_redist.x64.exe`
- `https://aka.ms/vs/17/release/vc_redist.x86.exe`

**Notes:** No auto-update lockdown needed. The VC++ Redistributable does not self-update. Handles exit code 1638 (same or newer already installed).

---

### WebRTC Redirector Service

**Script:** `WebRTCRedirector\Update-WebRTCRedirector.ps1`

Downloads and installs the latest Remote Desktop WebRTC Redirector Service MSI. This component provides media optimization for Teams on Azure Virtual Desktop.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-SkipUpdate` | Switch | | Skip download/install (detection only) |
| `-KeepInstallers` | Switch | | Retain downloaded files after install |

**Download URL:** `https://aka.ms/msrdcwebrtcsvc/msi`

**Notes:** No auto-update lockdown needed. The WebRTC Redirector does not self-update. Verifies that the `RDWebRTCSvc` service is running with Automatic start type after installation.

---

## Common Script Patterns

All scripts follow these conventions:

| Pattern | Implementation |
|---|---|
| **Logging** | `Write-Host` with timestamps; all output also written to `%SystemRoot%\Logs\Software\` |
| **Error handling** | `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"` with `try/catch` blocks |
| **Downloads** | BITS transfer with `Invoke-WebRequest` fallback; file size validation |
| **Registry writes** | Isolated `Set-RegistryValue` helper with independent `try/catch` |
| **Desktop shortcuts** | Cleaned from `$env:PUBLIC\Desktop` and `$env:USERPROFILE\Desktop` |
| **Installer cleanup** | Downloaded files removed after install unless `-KeepInstallers` is specified |
| **Admin check** | `#Requires -RunAsAdministrator` |

## Requirements

- Windows Server 2019/2022 or Windows 10/11 (AVD session host)
- PowerShell 5.1 or later
- Run as Administrator
- Internet access to download installers (or use offline parameters where supported)

## License

Falcon Network Services LLC
