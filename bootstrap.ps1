<#
.SYNOPSIS
    Bootstrap loader. This is the ONLY file end users run.

.USAGE
    irm https://raw.githubusercontent.com/<USER>/<REPO>/main/bootstrap.ps1 | iex

.NOTES
    Keep this file tiny and stable. All real logic lives in main.ps1 and the
    modules/ folder so you can update the tool without changing the URL
    people run.
#>

# ---- EDIT THIS after you create your GitHub repo -------------------------
$Global:BaseRepoUrl = "https://raw.githubusercontent.com/YOURUSERNAME/YOURREPO/main"
# ---------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

# 1. TLS 1.2 is required for GitHub raw content on older Windows/PS versions
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# 2. Require Windows PowerShell 5+ or PowerShell 7+ with WPF (Windows only)
if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6 -and -not [System.Environment]::OSVersion.Platform -match "Win") {
    Write-Host "This tool only runs on Windows (WPF GUI required)." -ForegroundColor Red
    return
}

# 3. Self-elevate to Administrator if not already running elevated
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    $launchCmd = "irm $BaseRepoUrl/bootstrap.ps1 | iex"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launchCmd))
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -Verb RunAs
    return
}

# 4. Pull down and execute the real entry point
Write-Host "Downloading main script..." -ForegroundColor Cyan
try {
    $mainScript = Invoke-RestMethod -Uri "$BaseRepoUrl/main.ps1" -UseBasicParsing
}
catch {
    Write-Host "Failed to download main.ps1 from $BaseRepoUrl" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    return
}

# Inject the base URL into the downloaded script's scope before running it
Invoke-Expression $mainScript
