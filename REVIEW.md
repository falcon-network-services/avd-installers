# Installer Review - AVD Gold Image Scripts

## Summary

Reviewed all 12 application installer scripts plus the master orchestrator (`Update-GoldImage.ps1`). Overall the codebase is **well-structured and production-quality** with consistent patterns, good error handling, and comprehensive AVD/VDI optimizations. Found 1 bug, 3 structural issues, and several minor observations.

---

## Bugs Fixed

### 1. Bitwarden: Null reference when not installed (CRITICAL)

**File:** `Bitwarden/Install-Bitwarden.ps1:333`

**Problem:** When Bitwarden is not installed (`$installed` is `$null`) but a GitHub release is found, the script calls `Get-NormalizedVersion $installed.Version` unconditionally. This throws `You cannot call a method on a null-valued expression` before the null guard on line 335 can protect it.

**Fix:** Moved the null check before `Get-NormalizedVersion` is called on `$installed.Version`.

---

## Structural Issues Fixed

### 2. Chrome/Firefox: Early exit skips cleanup and duplicates customizations

**Files:** `GoogleChrome/Install-GoogleChrome.ps1:354-372`, `FirefoxESR/Install-FirefoxESR.ps1:343-359`

**Problem:** When the installed version matches the latest, both scripts had an early `exit 0` path that:
- Called `Set-*AVDCustomizations` and exited, but skipped the cleanup block at the end
- In the normal flow (download + install), customizations were applied *after* the early-exit block too, meaning a code path refactor had left redundant logic

**Fix:** Replaced the early-exit pattern with a `$skipDownload` flag, allowing the script to fall through to the shared cleanup/customizations/verification code at the bottom. This ensures cleanup always runs and customizations are applied exactly once.

### 3. M365 Apps: Shortcut cleanup includes Edge and Teams shortcuts

**File:** `Microsoft365Apps/Update-Microsoft365Apps.ps1:310-323`

**Problem:** The desktop shortcut removal list included `Microsoft Edge.lnk` and `Microsoft Teams.lnk` entries. These are not M365 Apps shortcuts and are already handled by `MicrosoftEdge/Update-MicrosoftEdge.ps1` and `MicrosoftTeams/Update-MicrosoftTeams.ps1` respectively.

**Fix:** Removed the Edge and Teams entries from the M365 shortcut list. Added a comment noting they're handled by their own scripts.

### 4. Adobe Reader DC: Missing `-SkipUpdate` parameter

**File:** `AdobeReaderDC/Install-AdobeReaderDC.ps1`

**Problem:** Adobe Reader DC was the only installer without a `-SkipUpdate` parameter. The orchestrator correctly had `SupportsSkipUpdate = $false`, but this meant running `Update-GoldImage.ps1 -SkipUpdate` would still attempt to download and install Adobe Reader while all other apps would skip.

**Fix:** Added `-SkipUpdate` parameter support to the script and updated the orchestrator to set `SupportsSkipUpdate = $true`.

---

## Observations (No Changes Made)

### Architecture & Design

- **Standalone design is intentional and good.** Each script duplicates `Write-Log`, `Set-RegistryValue`, and `Start-FileDownload`. While a shared module would reduce duplication, the standalone design means each script can be run independently without dependencies, which is ideal for Gold Image maintenance scenarios.

- **Execution order is well-thought-out.** VCRedist first (runtime dependency), then PowerShell 7 (tooling), browsers, productivity apps, and utilities last.

- **Error isolation in the orchestrator is solid.** Each app runs in its own `try/catch` so one failure doesn't block the rest.

### Download & Installation

- **BITS with Invoke-WebRequest fallback** is used by most scripts (VCRedist, Edge, Chrome, OneDrive, WebRTC, Adobe). PowerShell 7, Notepad++, Teams, and Bitwarden use only `Invoke-WebRequest` (appropriate since their download URLs involve redirects that BITS may not handle well).

- **File size validation** is applied consistently where applicable. Each script has a minimum size threshold appropriate to its installer.

- **MSI exit code handling** is consistent: `0` (success), `1618` (another install in progress), and `3010` (reboot needed) are all treated as non-fatal. WebRTC additionally handles `1603`.

### Version Detection

- **Adobe Reader version scraping** (`Get-LatestReaderVersion`) parses HTML from Adobe's release notes page. This is the most fragile version detection method in the suite. If Adobe changes the page format, auto-detection will fail gracefully (falls back to customizations only), but consider using the Adobe Admin Console API as an alternative in the future.

- **GitHub API rate limiting** could affect PowerShell 7, Notepad++, and Bitwarden scripts if run frequently without authentication. All three use a `User-Agent` header which helps, but adding a `$env:GITHUB_TOKEN` auth header would be more robust for CI/CD pipelines.

### AVD Customizations

- **Comprehensive auto-update lockdown** across all apps. The belt-and-suspenders approach (registry policies + service disabling + scheduled task disabling) is appropriate for Gold Image maintenance.

- **Edge policy set is thorough**: first-run, sidebar/Copilot, shopping, default browser prompt, background mode, startup boost, and telemetry are all addressed.

- **Chrome policies** include the newer `GoogleSearchSidePanelEnabled` and `ShoppingListEnabled` policies which is good for current Chrome versions.

- **Firefox policies** correctly use the `HKLM:\SOFTWARE\Policies\Mozilla\Firefox` path which is the enterprise policy mechanism.

- **M365 Apps**: The Outlook cached mode settings (`SyncWindowSetting = 1` for 1 month) are appropriate for VDI profile size management.

### Minor Items

- **VCRedist `$exitCode`** (line 232) is assigned in a loop but never used after the loop body. Harmless.

- **M365 `Invoke-M365Update`** monitoring: The `OfficeClickToRun` process check may never trigger its break condition since that process runs as a persistent service. The version-change check and timeout are the actual exit conditions. Works correctly in practice.

- **Bitwarden stub installer** downloads the full app during install, which means the `Start-FileDownload` size check only validates the stub (~700KB), not the full application. The description in the script correctly documents this behavior.

---

## Test Recommendations

1. Run `Update-GoldImage.ps1 -SkipUpdate` to verify all customizations apply cleanly without downloads
2. Run `Update-GoldImage.ps1 -Only "Bitwarden"` on a machine without Bitwarden to verify the null-reference fix
3. Run individual Chrome/Firefox scripts when already at latest version to verify cleanup runs correctly
4. Run `Update-GoldImage.ps1 -SkipUpdate` to verify Adobe Reader now respects the flag
