[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$CertificatePath = (Join-Path $PSScriptRoot "crosshelper-ca-cert.pem"),

    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Stop-WithError {
    param([string]$Message)

    Write-Error $Message
    exit 1
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$administrator = [Security.Principal.WindowsBuiltInRole]::Administrator
if (-not $principal.IsInRole($administrator)) {
    Stop-WithError "Run PowerShell as Administrator, then run this script again."
}

if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
    Stop-WithError "Certificate file not found: $CertificatePath"
}

$resolvedPath = (Resolve-Path -LiteralPath $CertificatePath).Path
$pem = Get-Content -LiteralPath $resolvedPath -Raw
$match = [regex]::Match(
    $pem,
    "-----BEGIN CERTIFICATE-----\s*(?<data>[A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----"
)
if (-not $match.Success) {
    Stop-WithError "The file does not contain a PEM certificate."
}

try {
    $certificateBytes = [Convert]::FromBase64String(($match.Groups["data"].Value -replace "\s", ""))
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificateBytes)
}
catch {
    Stop-WithError "The certificate could not be parsed: $($_.Exception.Message)"
}

$basicConstraintsExtension = $certificate.Extensions |
    Where-Object { $_.Oid.Value -eq "2.5.29.19" } |
    Select-Object -First 1
if ($null -eq $basicConstraintsExtension) {
    Stop-WithError "The certificate has no Basic Constraints extension and cannot be trusted as a CA."
}

$basicConstraints = [Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new(
    $basicConstraintsExtension,
    $basicConstraintsExtension.Critical
)
if (-not $basicConstraints.CertificateAuthority) {
    Stop-WithError "The selected certificate is not a certificate authority."
}

$now = Get-Date
if ($now -lt $certificate.NotBefore -or $now -gt $certificate.NotAfter) {
    Stop-WithError "The certificate is not currently valid. Valid from $($certificate.NotBefore) to $($certificate.NotAfter)."
}

Write-Host "Certificate subject: $($certificate.Subject)"
Write-Host "SHA-256 fingerprint: $($certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256))"
Write-Host "Valid until: $($certificate.NotAfter)"

$store = [Security.Cryptography.X509Certificates.X509Store]::new(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
)

try {
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $existing = $store.Certificates.Find(
        [Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,
        $certificate.Thumbprint,
        $false
    )

    if ($existing.Count -gt 0) {
        Write-Host "This certificate is already installed in Local Computer\Trusted Root Certification Authorities."
        exit 0
    }

    if (-not $Force) {
        Write-Warning "Installing a root CA allows it to authenticate servers to this computer."
        $confirmation = Read-Host "Type INSTALL to trust this certificate"
        if ($confirmation -cne "INSTALL") {
            Stop-WithError "Certificate installation cancelled."
        }
    }

    $store.Add($certificate)
}
finally {
    $store.Close()
    $certificate.Dispose()
}

Write-Host "Certificate installed in Local Computer\Trusted Root Certification Authorities."