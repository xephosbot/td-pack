<#
.SYNOPSIS
    td-pack Windows build script.

.DESCRIPTION
    Builds TDLib for Windows platforms using Conan + CMake.

.PARAMETER Platform
    Target platform: windows-x64, windows-arm64

.PARAMETER Target
    Build target: tdlib (static libraries), tdlib_jni (JNI shared library)

.EXAMPLE
    .\build.ps1 -Platform windows-x64 -Target tdlib
    .\build.ps1 -Platform windows-arm64 -Target tdlib_jni
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("windows-x64", "windows-arm64")]
    [string]$Platform,

    [Parameter(Mandatory = $true)]
    [ValidateSet("tdlib", "tdlib_jni")]
    [string]$Target
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "======================================================="
Write-Host "  td-pack build: $Platform / $Target"
Write-Host "======================================================="

# --- Step 1: Initialize submodule and apply patch ---
Write-Host ""
Write-Host ">>> Preparing TDLib source..."
$TdDir = Join-Path $ProjectRoot "td"
git -C $ProjectRoot submodule update --init --depth=1 td

# Apply JNI patch
$PatchFile = Join-Path $ProjectRoot "patches\native-bridge-jni.patch"
if (Test-Path $PatchFile) {
    Push-Location $TdDir
    $checkResult = git apply --check $PatchFile 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Applying JNI patch..."
        git apply $PatchFile
    } else {
        Write-Host "JNI patch already applied or not applicable, skipping."
    }
    Pop-Location
}

# --- Step 2: Install Conan dependencies ---
Write-Host ""
Write-Host ">>> Installing Conan dependencies..."
$BuildDir = Join-Path $ProjectRoot "build\$Platform-$Target"
$Profile = Join-Path $ProjectRoot "profiles\$Platform"

conan install $ProjectRoot `
    --profile:build=default `
    --profile:host="$Profile" `
    --build=missing `
    --output-folder="$BuildDir"

if ($LASTEXITCODE -ne 0) { throw "Conan install failed" }

# --- Step 2.5: prepare_cross_compiling for cross-compile targets ---
# When CMAKE_CROSSCOMPILING is true, TDLib skips generating source files.
# Build native generators first so those files exist in the source tree.
if ($Platform -eq "windows-arm64") {
    Write-Host ""
    Write-Host ">>> Preparing cross-compilation (building native generators)..."
    $NativeGenDir = Join-Path $ProjectRoot "build\native-gen"

    # Install native (host) Conan dependencies
    conan install $ProjectRoot `
        --profile:build=default `
        --profile:host=default `
        --build=missing `
        --output-folder="$NativeGenDir"

    if ($LASTEXITCODE -ne 0) { throw "Native Conan install failed" }

    # Configure via root CMakeLists.txt (not td directly) so that the Conan
    # OpenSSL/zlib bridge code is applied -- td's generate_json needs libcrypto.
    cmake -S $ProjectRoot -B $NativeGenDir `
        -G "Visual Studio 17 2022" -A x64 `
        -DCMAKE_TOOLCHAIN_FILE="$NativeGenDir\conan_toolchain.cmake" `
        -DCMAKE_POLICY_DEFAULT_CMP0091=NEW `
        -DTD_ANDROID_JSON=ON

    if ($LASTEXITCODE -ne 0) { throw "Native CMake configure failed" }

    # Build only the generators
    cmake --build $NativeGenDir --config Release --target prepare_cross_compiling --parallel

    if ($LASTEXITCODE -ne 0) { throw "prepare_cross_compiling failed" }
}

# --- Step 3: Configure CMake ---
Write-Host ""
Write-Host ">>> Configuring CMake..."

$Toolchain = Join-Path $BuildDir "conan_toolchain.cmake"

# Determine VS architecture
$VsArch = switch ($Platform) {
    "windows-x64"   { "x64" }
    "windows-arm64" { "ARM64" }
}

$CmakeArgs = @(
    "-G", "Visual Studio 17 2022"
    "-A", $VsArch
    "-DCMAKE_TOOLCHAIN_FILE=$Toolchain"
    "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW"
)

if ($Target -eq "tdlib") {
    # Static library build — use root CMakeLists.txt with TD_ANDROID_JSON
    # to get the simple add_subdirectory(td) path with bridge code for
    # Conan-provided OpenSSL/zlib
    $CmakeArgs += @("-DTD_ANDROID_JSON=ON", "-DTD_ENABLE_JNI=OFF")
    cmake -S $ProjectRoot -B $BuildDir @CmakeArgs
} else {
    $CmakeArgs += @(
        "-DTD_ANDROID_JSON_JAVA=ON"
        "-DTD_ENABLE_JNI=ON"
        "-DTD_JNI_PACKAGE_NAME=io/xbot/tdlib"
    )

    if ($env:JAVA_HOME) {
        $CmakeArgs += @(
            "-DJAVA_INCLUDE_PATH=$env:JAVA_HOME\include"
            "-DJAVA_INCLUDE_PATH2=$env:JAVA_HOME\include\win32"
        )
    }

    cmake -S $ProjectRoot -B $BuildDir @CmakeArgs
}

if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

# --- Step 4: Build ---
Write-Host ""
Write-Host ">>> Building..."

# Build only the target we need — avoids building unnecessary benchmarks
# and the shared tdjson library which can have link-order issues with LTO.
if ($Target -eq "tdlib") {
    cmake --build $BuildDir --config RelWithDebInfo --target tdjson_static --parallel
} else {
    if ($Platform -eq "windows-arm64") {
        cmake --build $BuildDir --config RelWithDebInfo --target tdjni --parallel
    } else {
        cmake --build $BuildDir --config RelWithDebInfo --target tdjson --parallel
    }
}

if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

# --- Step 5: Collect output ---
Write-Host ""
Write-Host ">>> Collecting output..."

$WinArch = $Platform -replace '^windows-', ''
$TdDir = Join-Path $ProjectRoot "td"

if ($Target -eq "tdlib_jni") {
    $OutDir = Join-Path $ProjectRoot "tdlib\windows-jni\$WinArch"
} else {
    $OutDir = Join-Path $ProjectRoot "tdlib\windows\$WinArch"
}

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }

if ($Target -eq "tdlib") {
    # Static build: all .lib libraries + headers
    New-Item -ItemType Directory -Force "$OutDir\lib" | Out-Null
    New-Item -ItemType Directory -Force "$OutDir\include\td\telegram" | Out-Null

    Get-ChildItem $BuildDir -Recurse -Filter "*.lib" |
        Where-Object { $_.FullName -notmatch '\\CMakeFiles\\' } |
        ForEach-Object { Copy-Item $_.FullName "$OutDir\lib\" -Force -Verbose }

    $tdjsonExport = Get-ChildItem $BuildDir -Recurse -Filter "tdjson_export.h" | Select-Object -First 1
    if ($tdjsonExport) {
        Copy-Item $tdjsonExport.FullName "$OutDir\include\td\telegram\" -Verbose
    }
    Copy-Item "$TdDir\td\telegram\td_json_client.h" "$OutDir\include\" -Verbose
    Copy-Item "$TdDir\td\telegram\td_log.h" "$OutDir\include\" -Verbose
} else {
    # JNI build: shared library only
    New-Item -ItemType Directory -Force "$OutDir\lib" | Out-Null

    Get-ChildItem $BuildDir -Recurse -Filter "tdjsonjava*.dll" |
        Where-Object { $_.FullName -notmatch '\\CMakeFiles\\' } |
        ForEach-Object { Copy-Item $_.FullName "$OutDir\lib\" -Force -Verbose }
}

Write-Host ""
Write-Host "======================================================="
Write-Host "  Build complete: $OutDir"
Write-Host "======================================================="
Get-ChildItem "$OutDir" -Recurse | Format-Table FullName, Length
