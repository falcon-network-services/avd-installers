<#
.SYNOPSIS
    Bootstrap script that downloads and executes Update-GoldImage.ps1 from GitHub.

.DESCRIPTION
    Fetches the latest Update-GoldImage.ps1 orchestrator from GitHub and runs it.
    All parameters are passed through to the orchestrator.

    Public repo one-liner (paste into elevated PowerShell):
    $f="$env:TEMP\Invoke-GoldImage.ps1";[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/falcon-network-services/avd-installers/main/Invoke-GoldImage.ps1' -OutFile $f -UseBasicParsing;& $f;[System.IO.File]::Delete($f)

    Private repo one-liner (replace <PAT> with your token):
    $f="$env:TEMP\Invoke-GoldImage.ps1";$t="<PAT>";[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/falcon-network-services/avd-installers/main/Invoke-GoldImage.ps1' -OutFile $f -UseBasicParsing -Headers @{Authorization="token $t"};& $f -GitHubToken $t;[System.IO.File]::Delete($f)

.NOTES
    Author: Falcon Network Services LLC
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo   = "falcon-network-services/avd-installers"
$branch = "main"
$url    = "https://raw.githubusercontent.com/$repo/$branch/Update-GoldImage.ps1"
$tempScript = Join-Path $env:TEMP "Update-GoldImage.ps1"

# Check if a GitHubToken was passed through so we can use it for this download too
$headers = @{}
foreach ($a in $args) {
    if ($a -eq '-GitHubToken' -or $a -eq '-GitHubToken:') {
        $tokenArgFound = $true
        continue
    }
    if ($tokenArgFound) {
        $headers['Authorization'] = "token $a"
        $tokenArgFound = $false
    }
}

try {
    Write-Host "[Invoke-GoldImage] Downloading Update-GoldImage.ps1 from GitHub..."
    Invoke-WebRequest -Uri $url -OutFile $tempScript -UseBasicParsing -Headers $headers
    Unblock-File -Path $tempScript

    Write-Host "[Invoke-GoldImage] Executing Update-GoldImage.ps1..."
    & $tempScript @args
}
finally {
    # [IO.File]::Delete handles 8.3 short paths in $env:TEMP (e.g. C:\Users\FNS~1.TEC\...)
    # that Remove-Item cannot, and is a no-op if the file is already gone.
    if (Test-Path -LiteralPath $tempScript) {
        try { [System.IO.File]::Delete($tempScript) }
        catch { Write-Warning "Could not remove temporary script '$tempScript': $($_.Exception.Message)" }
    }
}
