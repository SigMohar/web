<#
.SYNOPSIS
  Downloads CA certificates from ca.sigmohar.com and, only after explicit
  confirmation, trusts them system-wide and (optionally) tells Firefox to
  trust the OS store too.

.DESCRIPTION
  Same design principles as the Linux/macOS versions of this script:
    - No auto-discovery of cert IDs. List them in $CertIds below, or pass
      them as an argument.
    - Every system-changing action (certificate store, registry) requires
      an explicit y/N confirmation showing exactly what will be affected.
    - Downloaded files live only in a temp folder that is deleted when the
      script exits, whether it succeeds, fails, or is interrupted.
    - Chrome and Edge use the Windows certificate store directly, so no
      extra step is needed for them once the system store is updated.
    - Firefox keeps its own trust store. Rather than manipulating its NSS
      database directly (which needs certutil — Windows doesn't ship an
      NSS build of it), this offers to enable Mozilla's official
      "ImportEnterpriseRoots" policy, so Firefox trusts whatever Windows
      already trusts, including any certs installed here.

.USAGE
  # Run from an elevated PowerShell ("Run as Administrator") for full effect:
  .\Install-CACerts.ps1
  .\Install-CACerts.ps1 -CertIds "abcd1234","ef567890"
  .\Install-CACerts.ps1 -Yes            # skip confirmations

  # If script execution is blocked by policy, run it as:
  powershell -ExecutionPolicy Bypass -File .\Install-CACerts.ps1
#>

[CmdletBinding()]
param(
    # Put every cert ID (the "XXXX" in https://ca.sigmohar.com/r/XXXX.crt)
    # you want installed here, or pass -CertIds at the command line.
    [string[]]$CertIds = @(
        # "xxxx1",
        # "xxxx2"
    ),
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$BaseUrl = if ($env:CA_BASE_URL) { $env:CA_BASE_URL } else { "https://ca.sigmohar.com/r" }

function Write-Log  { param($msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" }
function Write-Info-Warn { param($msg) Write-Warning $msg }
function Write-Err  { param($msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ERROR: $msg" -ForegroundColor Red }

function Confirm-Action {
    param([string]$Prompt)
    if ($Yes) {
        Write-Log "(auto-confirmed via -Yes) $Prompt"
        return $true
    }
    $reply = Read-Host "$Prompt [y/N]"
    return ($reply -match '^(y|yes)$')
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

$IsAdmin = Test-IsAdmin

if ($CertIds.Count -eq 0) {
    Write-Err "No cert IDs configured. Edit `$CertIds at the top of this script, or pass them as an argument:"
    Write-Err "  .\Install-CACerts.ps1 -CertIds 'xxxx1','xxxx2'"
    exit 1
}

# --------------------------------------------------------------------
# Temp dir — created up front, always removed in the finally block below
# --------------------------------------------------------------------
$TempDir = Join-Path $env:TEMP ("ca-certs-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $TempDir | Out-Null

try {

    Write-Log "Temp download folder: $TempDir"
    Write-Host ""
    Write-Host "About to download the following:"
    foreach ($id in $CertIds) { Write-Host "  $BaseUrl/$id.crt" }
    if (-not (Confirm-Action "Proceed with downloading these $($CertIds.Count) file(s)?")) {
        Write-Log "Aborted by user before any download."
        exit 0
    }

    # id -> @{ Path; Nickname; Cert; Thumbprint }
    $Fetched = @{}

    foreach ($id in $CertIds) {
        $url = "$BaseUrl/$id.crt"
        $rawPath = Join-Path $TempDir "$id.raw"
        Write-Log "Downloading $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $rawPath -UseBasicParsing
        } catch {
            Write-Info-Warn "Failed to download '$id' ($($_.Exception.Message)) — skipping."
            continue
        }

        try {
            $bytes = [System.IO.File]::ReadAllBytes($rawPath)
            # X509Certificate2 accepts both DER and base64-PEM encoded single certs.
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$bytes)
        } catch {
            Write-Err "'$id' is not a valid certificate (DER or PEM) — skipping."
            continue
        }

        $nickname = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        if ([string]::IsNullOrWhiteSpace($nickname)) { $nickname = $id }

        $Fetched[$id] = @{ Path = $rawPath; Nickname = $nickname; Cert = $cert; Thumbprint = $cert.Thumbprint }
        Write-Log "  -> OK: '$nickname' ($id)"
    }

    if ($Fetched.Count -eq 0) {
        Write-Err "No certificates were successfully downloaded/validated. Nothing to install."
        exit 1
    }

    Write-Host ""
    Write-Log "Successfully fetched and validated $($Fetched.Count) of $($CertIds.Count) requested cert(s):"
    foreach ($id in $Fetched.Keys) {
        Write-Host "  - $($Fetched[$id].Nickname) ($id)"
    }

    # ------------------------------------------------------------------
    # System / user certificate store
    # ------------------------------------------------------------------
    $storeLocation = $null
    if ($IsAdmin) {
        Write-Host ""
        Write-Host "The following cert(s) can be added to the SYSTEM-WIDE trust store (Cert:\LocalMachine\Root)."
        Write-Host "This affects every user and application on this machine that uses the Windows certificate"
        Write-Host "store, including Edge and Chrome."
        foreach ($id in $Fetched.Keys) { Write-Host "  - $($Fetched[$id].Nickname)" }
        if (Confirm-Action "Proceed with system-wide (LocalMachine) trust store installation?") {
            $storeLocation = "Cert:\LocalMachine\Root"
        } else {
            Write-Log "Skipped system-wide trust store installation."
        }
    } else {
        Write-Info-Warn "Not running as Administrator — cannot write to the machine-wide (LocalMachine) store."
        if (Confirm-Action "Install into the CURRENT USER trust store instead (Cert:\CurrentUser\Root, affects only your account)?") {
            $storeLocation = "Cert:\CurrentUser\Root"
        } else {
            Write-Log "Skipped certificate store installation entirely."
        }
    }

    if ($storeLocation) {
        foreach ($id in $Fetched.Keys) {
            $info = $Fetched[$id]
            $existing = Get-ChildItem $storeLocation -ErrorAction SilentlyContinue |
                        Where-Object { $_.Thumbprint -eq $info.Thumbprint }
            if ($existing) {
                Write-Log "'$($info.Nickname)' is already present in $storeLocation — skipping re-import."
                continue
            }
            try {
                Import-Certificate -FilePath $info.Path -CertStoreLocation $storeLocation | Out-Null
                Write-Log "Installed '$($info.Nickname)' into $storeLocation"
            } catch {
                Write-Info-Warn "Failed to install '$($info.Nickname)' into $storeLocation`: $($_.Exception.Message)"
            }
        }
    }

    # ------------------------------------------------------------------
    # Firefox: enable "trust the OS store" policy instead of touching NSS directly
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "Firefox keeps its own trust store separate from Windows. Rather than injecting certs into"
    Write-Host "each Firefox profile's NSS database (which needs tooling Windows doesn't ship with), this"
    Write-Host "can enable Mozilla's official 'ImportEnterpriseRoots' policy, so Firefox trusts whatever"
    Write-Host "Windows already trusts — this also covers any future certs automatically."

    $regRoot = $null
    $scopeDesc = $null
    if ($IsAdmin) {
        $regRoot = "HKLM:\SOFTWARE\Policies\Mozilla\Firefox"
        $scopeDesc = "all users on this machine (HKLM)"
    } else {
        Write-Info-Warn "Not running as Administrator — the machine-wide (HKLM) policy location isn't writable."
        if (Confirm-Action "Set this policy for your user account only instead (HKCU)?") {
            $regRoot = "HKCU:\SOFTWARE\Policies\Mozilla\Firefox"
            $scopeDesc = "your user account only (HKCU)"
        }
    }

    if ($regRoot) {
        $already = $false
        if (Test-Path $regRoot) {
            $val = Get-ItemProperty -Path $regRoot -Name ImportEnterpriseRoots -ErrorAction SilentlyContinue
            if ($val -and $val.ImportEnterpriseRoots -eq 1) { $already = $true }
        }
        if ($already) {
            Write-Log "Firefox 'ImportEnterpriseRoots' policy is already enabled ($scopeDesc)."
        } elseif (Confirm-Action "Enable Firefox's 'ImportEnterpriseRoots' policy for $scopeDesc?") {
            New-Item -Path $regRoot -Force | Out-Null
            New-ItemProperty -Path $regRoot -Name ImportEnterpriseRoots -Value 1 -PropertyType DWord -Force | Out-Null
            Write-Log "Enabled Firefox 'ImportEnterpriseRoots' policy ($scopeDesc). Restart Firefox for it to take effect."
        } else {
            Write-Log "Skipped Firefox policy setup."
        }
    } else {
        Write-Log "Skipped Firefox policy setup entirely."
    }

} finally {
    Write-Log "Finished. Removing temp folder: $TempDir"
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
