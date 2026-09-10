# AVD Gold Image Application Installers

## Falcon Conventions (Required Reading)

Falcon Network Services maintains shared conventions in the sibling repo at `../fns1-conventions/`. Read these files at session start in addition to this CLAUDE.md.

**Always applicable to this repo:**

- `../fns1-conventions/documentation-conventions.md` - Em dashes prohibited, Falcon vs FNS1 naming, tone, code comment headers, compliance citation patterns
- `../fns1-conventions/tech-stack.md` - Falcon's complete technology environment for orientation
- `../fns1-conventions/active-standards-index.md` - Snapshot of active Falcon standards and runbooks

**Read for cross-repo context (not directly applied here):**

- `../fns1-conventions/document-id-naming.md` - Used when this repo's scripts are referenced from formal Falcon documents
- `../fns1-conventions/ninjaone-conventions.md` - Applies to NinjaOne automations in `../ninjaone/`. The Gold Image scripts in this repo are NOT NinjaOne automations and follow this repo's own conventions documented below
- `../fns1-conventions/azure-conventions.md` - Applies when Azure resources are deployed. This repo produces scripts; Azure deployment is handled elsewhere

**Conflict resolution:**

Where this repo's conventions (the Conventions section below) differ from `fns1-conventions`, the conventions in this CLAUDE.md take precedence for repo-specific patterns (PowerShell function structure, parameter sets, AVD customizations). The shared conventions take precedence for documentation style (no em dashes), document references (FNS1- IDs), and cross-cutting concerns.

## Project Overview

PowerShell scripts for maintaining Azure Virtual Desktop (AVD) Gold Images. Each script downloads the latest version of an application, installs it silently, disables auto-update mechanisms, and applies AVD/VDI-optimized registry customizations.

## Structure

```
Update-GoldImage.ps1             # Config-driven orchestrator - fetches scripts from GitHub
Invoke-GoldImage.ps1             # Bootstrap script - downloads and runs the orchestrator
apps.example.json                # Template config showing all 17 apps with parameters
{AppName}/Update-{AppName}.ps1   # Individual updater scripts (standalone)
```

**17 applications:** VCRedist, PowerShell7, MicrosoftEdge, GoogleChrome, FirefoxESR, AdobeReaderDC, Microsoft365Apps, OneDrive, MicrosoftTeams, WebRTCRedirector, ClaudeDesktop, Git, NodeJS, GitHubCLI, NotepadPlusPlus, Bitwarden, Pandoc

## Conventions

### Script Patterns (must be followed in all scripts)

- `#Requires -RunAsAdministrator` at top
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"`
- `$ProgressPreference = "SilentlyContinue"` to speed up web requests
- Every script has its own `Write-Log`, `Set-RegistryValue`, and `Start-FileDownload` functions (standalone design, no shared modules). Exception: `Set-RegistryValue` is only required in scripts that apply registry customizations - scripts with no registry changes (VCRedist, WebRTCRedirector, NotepadPlusPlus, Pandoc) are exempt.
- Logs go to `$env:SystemRoot\Logs\Software\`
- Downloads use BITS with Invoke-WebRequest fallback (except for URLs with redirects, which use Invoke-WebRequest only)
- File size validation after download
- Close running app processes before install
- Remove desktop shortcuts from `$env:PUBLIC\Desktop` and `C:\Users\Default\Desktop`
- Clean up downloaded installers unless `-KeepInstallers` is specified
- Exit codes: 0 = success, 1618 = another install in progress, 3010 = reboot needed (all treated as non-fatal)

### Parameters (every script must support)

- `-SkipUpdate` - Skip download/install, apply customizations only
- `-KeepInstallers` - Retain downloaded files
- `-LogPath` - Log directory (default: `$env:SystemRoot\Logs\Software`)
- `-DownloadPath` - Download directory (default: `$env:TEMP\{AppName}`)

Exception: `-DownloadPath` and `-KeepInstallers` are only required in scripts that download files. Microsoft365Apps uses Click-to-Run and is exempt from both parameters.

### AVD Customizations (applied by every script)

Each script disables auto-update mechanisms using a belt-and-suspenders approach:
1. Registry policies to disable updates
2. Stop and disable update services
3. Disable update scheduled tasks
4. Remove updater executables where applicable

### MSIX-Packaged Applications

MSIX apps (MicrosoftTeams, ClaudeDesktop) are provisioned machine-wide with `Add-AppxProvisionedPackage`, not installed per-user. The packages are authored per-user, so `Add-AppxPackage` would register the app for the calling account only, which on a multi-session host means a single profile. Provisioning stages the package at the OS level and each user profile registers it at first sign-in.

Version detection for these apps compares `Get-AppxProvisionedPackage` output against the package version. Where the publisher exposes no version API, read `Package/Identity/@Version` from `AppxManifest.xml` inside the downloaded package (open the MSIX as a zip with `System.IO.Compression.ZipFile`) rather than downloading and provisioning unconditionally.

### Orchestrator (`Update-GoldImage.ps1`)

- Reads `apps.json` config to determine which apps to process
- Fetches each app's script from GitHub at runtime (no local repo needed)
- Runs apps in catalog dependency order (VCRedist first, utilities last)
- Splats per-app parameters from config (e.g., TenantId, Architecture)
- Each app wrapped in its own `try/catch` error boundary
- Produces summary report with status and duration per app
- `$AppDefinitions` array defines valid apps and their `ValidParams`
- TLS 1.2 set before any web calls (required for WinPS 5.1 + GitHub)
- Downloaded scripts are `Unblock-File`d and cleaned up in a `finally` block

### Bootstrap (`Invoke-GoldImage.ps1`)

- Downloads `Update-GoldImage.ps1` from GitHub and executes it
- Passes all parameters through via `@args`
- Enables a single copy-paste one-liner to update any gold image

## When Adding a New Application

1. Create `{AppName}/{Install|Update}-{AppName}.ps1` following the patterns above
2. Add an entry to `$AppDefinitions` in `Update-GoldImage.ps1` (include `ValidParams` for any special parameters)
3. Update `apps.example.json` with the new app entry
4. Update `README.md` with the new application section

## Linting

Use PowerShell's built-in parser to validate scripts for syntax errors:

```bash
# Lint a single script
pwsh -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile("./VCRedist/Update-VCRedist.ps1", [ref]$null, [ref]$errors); if ($errors) { $errors | ForEach-Object { Write-Error $_.Message }; exit 1 }'

# Lint all scripts
pwsh -NoProfile -Command 'Get-ChildItem -Path . -Filter "*.ps1" -Recurse | ForEach-Object { $e=$null; [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e); if ($e) { $e | ForEach-Object { Write-Output "ERROR: $($_.Extent.File):$($_.Extent.StartLineNumber) - $($_.Message)" } } }; if ($LASTEXITCODE) { exit 1 }'
```

Note: These scripts target Windows and cannot be executed on Linux. Syntax validation is the primary check available in non-Windows environments.

## Important Notes

- All scripts are designed to run under Windows PowerShell 5.1 (not just PowerShell 7)
- Scripts must be idempotent - safe to run multiple times
- Version detection degrades by state, not uniformly. Where the version API fails but the app is already installed, log a WARN and continue with customizations only. Where the app is absent, throw. A run that installs nothing must fail: a SUCCESS line in the summary for an app that is not on the image is worse than a failed run, because nothing downstream will catch it
- A non-zero installer exit code is a failure, not a warning, and so is an unchanged version after an install that reported success. The documented exceptions are 1618 (another install in progress) and 3010 (reboot required), which are non-fatal
- Never leave auto-update mechanisms enabled - this is critical for Gold Image integrity
- Adobe Reader version detection scrapes HTML (most fragile); all others use structured APIs