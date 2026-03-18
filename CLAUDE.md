# AVD Gold Image Application Installers

## Project Overview

PowerShell scripts for maintaining Azure Virtual Desktop (AVD) Gold Images. Each script downloads the latest version of an application, installs it silently, disables auto-update mechanisms, and applies AVD/VDI-optimized registry customizations.

## Structure

```
Update-GoldImage.ps1          # Master orchestrator - runs all 12 apps in dependency order
{AppName}/Update-{AppName}.ps1   # Individual updater scripts (standalone)
```

**12 applications:** VCRedist, PowerShell7, MicrosoftEdge, GoogleChrome, FirefoxESR, AdobeReaderDC, Microsoft365Apps, OneDrive, MicrosoftTeams, WebRTCRedirector, NotepadPlusPlus, Bitwarden

## Conventions

### Script Patterns (must be followed in all scripts)

- `#Requires -RunAsAdministrator` at top
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"`
- `$ProgressPreference = "SilentlyContinue"` to speed up web requests
- Every script has its own `Write-Log`, `Set-RegistryValue`, and `Start-FileDownload` functions (standalone design, no shared modules). Exception: `Set-RegistryValue` is only required in scripts that apply registry customizations — scripts with no registry changes (VCRedist, WebRTCRedirector, NotepadPlusPlus) are exempt.
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

### Orchestrator (`Update-GoldImage.ps1`)

- Runs apps in dependency order (VCRedist first, utilities last)
- Each app wrapped in its own `try/catch` error boundary
- Supports `-Only` and `-Exclude` filters
- Produces summary report with status and duration per app
- `$AppDefinitions` array must be updated when adding/removing apps

## When Adding a New Application

1. Create `{AppName}/{Install|Update}-{AppName}.ps1` following the patterns above
2. Add an entry to `$AppDefinitions` in `Update-GoldImage.ps1`
3. Add the app name to both `ValidateSet` attributes on `-Only` and `-Exclude` parameters
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
- Version detection should gracefully handle API failures (fall back to download anyway or customizations only)
- Never leave auto-update mechanisms enabled - this is critical for Gold Image integrity
- Adobe Reader version detection scrapes HTML (most fragile); all others use structured APIs
