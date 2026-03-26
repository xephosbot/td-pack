<#
.SYNOPSIS
    Build TDLib for Windows (MSVC) - static libraries + headers.
.PARAMETER TdSourceDir
    Path to TDLib source directory.
.PARAMETER OpensslInstallDir
    Path to OpenSSL install directory.
.PARAMETER Arch
    Target architecture: x64 or arm64.
.PARAMETER EnableJni
    If set, build JNI shared library instead of static.
#>
param(
    [string]$TdSourceDir = "td",
    [string]$OpensslInstallDir = "third-party\openssl",
    [string]$Arch = "x64",
    [switch]$EnableJni
)

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RootDir

# Resolve absolute paths
if (Test-Path $TdSourceDir) {
    $TdSourceDir = (Resolve-Path $TdSourceDir).Path
} else {
    Write-Error "TDLib source directory '$TdSourceDir' doesn't exist."
    exit 1
}

$OpensslInstallDir = Join-Path $RootDir "$OpensslInstallDir\windows\$Arch"

if (-not (Test-Path $OpensslInstallDir)) {
    Write-Error "OpenSSL install directory '$OpensslInstallDir' doesn't exist. Run build-openssl-windows.ps1 first."
    exit 1
}

# Check required tools
foreach ($tool in @("cmake", "gperf")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool not found. Please install it."
        exit 1
    }
}

# Determine output directory and cmake platform
switch ($Arch) {
    "x64"   { $CmakePlatform = "x64" }
    "arm64" { $CmakePlatform = "ARM64" }
    default {
        Write-Error "Unsupported architecture: $Arch"
        exit 1
    }
}

if ($EnableJni) {
    $OutputSubdir = "windows-jni"
    $BuildDirName = "build-tdlib-windows-jni-$Arch"
} else {
    $OutputSubdir = "windows"
    $BuildDirName = "build-tdlib-windows-$Arch"
}

$InstallDir = Join-Path $RootDir "tdlib\$OutputSubdir\$Arch"

# Clean output
if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
}

Write-Host "Building TDLib for Windows $Arch (JNI: $EnableJni)..."

# Clean build dir
if (Test-Path $BuildDirName) {
    Remove-Item -Recurse -Force $BuildDirName
}
New-Item -ItemType Directory -Force -Path $BuildDirName | Out-Null

Set-Location $BuildDirName

# Configure TDLib
$cmakeArgs = @(
    $TdSourceDir,
    "-A", $CmakePlatform,
    "-DCMAKE_BUILD_TYPE=Release",
    "-DOPENSSL_ROOT_DIR=$OpensslInstallDir",
    "-DCMAKE_INSTALL_PREFIX=$InstallDir",
    "-DTD_ENABLE_LTO=OFF"
)

if ($EnableJni) {
    $cmakeArgs += "-DTD_ENABLE_JNI=ON"
} else {
    $cmakeArgs += "-DTD_ENABLE_JNI=OFF"
}

cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { exit 1 }

# Build
if ($EnableJni) {
    Write-Host "Building tdjson (shared) for Windows $Arch..."
    cmake --build . --config Release --target tdjson -- /m
} else {
    Write-Host "Building tdjson_static for Windows $Arch..."
    cmake --build . --config Release --target tdjson_static -- /m
}
if ($LASTEXITCODE -ne 0) { exit 1 }

Set-Location $RootDir

New-Item -ItemType Directory -Force -Path "$InstallDir\lib" | Out-Null
New-Item -ItemType Directory -Force -Path "$InstallDir\include\td\telegram" | Out-Null

if ($EnableJni) {
    # Copy JNI shared libraries
    Get-ChildItem -Path $BuildDirName -Recurse -Filter "tdjson*.dll" | ForEach-Object {
        Copy-Item $_.FullName "$InstallDir\lib\" -Verbose
    }
    Get-ChildItem -Path $BuildDirName -Recurse -Filter "tdjson*.lib" | ForEach-Object {
        Copy-Item $_.FullName "$InstallDir\lib\" -Verbose
    }
} else {
    # Copy static libraries
    Get-ChildItem -Path $BuildDirName -Recurse -Filter "*.lib" | ForEach-Object {
        Copy-Item $_.FullName "$InstallDir\lib\" -Verbose
    }
    # Copy OpenSSL static libraries
    Copy-Item "$OpensslInstallDir\lib\libcrypto.lib" "$InstallDir\lib\" -ErrorAction SilentlyContinue -Verbose
    Copy-Item "$OpensslInstallDir\lib\libssl.lib" "$InstallDir\lib\" -ErrorAction SilentlyContinue -Verbose
}

# Copy headers
$tdjsonExport = Get-ChildItem -Path $BuildDirName -Recurse -Filter "tdjson_export.h" | Select-Object -First 1
if ($tdjsonExport) {
    Copy-Item $tdjsonExport.FullName "$InstallDir\include\td\telegram\" -Verbose
}
Copy-Item "$TdSourceDir\td\telegram\td_json_client.h" "$InstallDir\include\" -Verbose
Copy-Item "$TdSourceDir\td\telegram\td_log.h" "$InstallDir\include\" -Verbose

# Clean build dir
Remove-Item -Recurse -Force $BuildDirName -ErrorAction SilentlyContinue

Write-Host "Done. TDLib Windows build stored in tdlib\$OutputSubdir\$Arch"
Get-ChildItem "$InstallDir\lib" | Format-Table Name, Length
