<#
.SYNOPSIS
    Build OpenSSL for Windows (MSVC) - static libraries.
.PARAMETER OpensslSourceDir
    Path to OpenSSL source directory.
.PARAMETER OpensslInstallDir
    Path to install OpenSSL output.
.PARAMETER Arch
    Target architecture: x64 or arm64.
#>
param(
    [string]$OpensslSourceDir = "openssl",
    [string]$OpensslInstallDir = "third-party\openssl",
    [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RootDir

# Resolve absolute paths
if (Test-Path $OpensslSourceDir) {
    $OpensslSourceDir = (Resolve-Path $OpensslSourceDir).Path
} else {
    Write-Error "OpenSSL source directory '$OpensslSourceDir' doesn't exist."
    exit 1
}

$OpensslInstallDir = Join-Path $RootDir "$OpensslInstallDir\windows"

if (Test-Path "$OpensslInstallDir\$Arch") {
    Write-Error "Directory '$OpensslInstallDir\$Arch' already exists. Delete it manually to proceed."
    exit 1
}

Write-Host "Building OpenSSL for Windows ($Arch)..."

Set-Location $OpensslSourceDir

$InstallPath = "$OpensslInstallDir\$Arch"
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null

# Choose correct OpenSSL target
switch ($Arch) {
    "x64"   { $ConfigureTarget = "VC-WIN64A" }
    "arm64" { $ConfigureTarget = "VC-WIN64-ARM" }
    default {
        Write-Error "Unsupported architecture: $Arch. Use 'x64' or 'arm64'."
        exit 1
    }
}

Write-Host "Using OpenSSL target: $ConfigureTarget"

# Clean previous build
& nmake clean 2>$null
if ($LASTEXITCODE -ne 0) { $LASTEXITCODE = 0 }

perl Configure $ConfigureTarget `
    --prefix="$InstallPath" `
    --openssldir="$InstallPath" `
    no-shared no-tests no-asm
if ($LASTEXITCODE -ne 0) { exit 1 }

nmake
if ($LASTEXITCODE -ne 0) { exit 1 }

nmake install_sw
if ($LASTEXITCODE -ne 0) { exit 1 }

nmake clean 2>$null

Set-Location $RootDir

Write-Host "Done. OpenSSL installed to $InstallPath"
