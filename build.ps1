#Requires -Version 5.1
<#
.SYNOPSIS
    TDLib Windows build driver.

.DESCRIPTION
    Builds TDLib static library or tdjni JNI shared library for Windows.
    Uses vcpkg (pinned commit) for OpenSSL/zlib/gperf dependencies.

.PARAMETER Target
    Build target: 'tdlib' (static) or 'tdlib_jni' (JNI shared library).

.PARAMETER Platform
    Target platform: 'windows-x64' or 'windows-arm64'.

.EXAMPLE
    .\build.ps1 -Target tdlib -Platform windows-x64
    .\build.ps1 -Target tdlib_jni -Platform windows-arm64
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('tdlib', 'tdlib_jni')]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [ValidateSet('windows-x64', 'windows-arm64')]
    [string]$Platform
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # faster Invoke-WebRequest

# ── Helpers ────────────────────────────────────────────────────────────────────
function Write-Banner([string]$msg) {
    $line = '═' * 60
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-Info([string]$msg)    { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)      { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn([string]$msg)    { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg)    {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

function Invoke-Cmd {
    [CmdletBinding()]
    param([string]$Exe, [string[]]$Arguments)
    Write-Info "Running: $Exe $($Arguments -join ' ')"
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "'$Exe $($Arguments -join ' ')' exited with code $LASTEXITCODE"
    }
}

# ── Resolve paths ──────────────────────────────────────────────────────────────
$ProjectRoot = $PSScriptRoot
$BuildDir    = Join-Path $ProjectRoot 'build'
$TdDir       = Join-Path $ProjectRoot 'td'
$PatchFile   = Join-Path $ProjectRoot 'patches\native-bridge-jni.patch'
$VcpkgDir    = Join-Path $BuildDir 'vcpkg'
$VcpkgCommit = 'bc3512a509f9d29b37346a7e7e929f9a26e66c7e'

# ── Platform → CMake arch mapping ─────────────────────────────────────────────
switch ($Platform) {
    'windows-x64'   { $CmakeArch = 'x64';   $VcpkgArch = 'x64';   $OutSuffix = 'x64'   }
    'windows-arm64' { $CmakeArch = 'ARM64';  $VcpkgArch = 'arm64'; $OutSuffix = 'arm64' }
}

# JNI builds use static-md triplet so OpenSSL/zlib are statically linked into
# the shared library, making it portable.
if ($Target -eq 'tdlib_jni') {
    $VcpkgTriplet = "${VcpkgArch}-windows-static-md"
} else {
    $VcpkgTriplet = "${VcpkgArch}-windows"
}

# ── Detect parallelism ────────────────────────────────────────────────────────
$Nproc = [Environment]::ProcessorCount
if (-not $Nproc -or $Nproc -lt 1) { $Nproc = 4 }

# ── Step 1: Init git submodule ────────────────────────────────────────────────
Write-Banner 'Initialising TDLib submodule'
Invoke-Cmd git @('-C', $ProjectRoot, 'submodule', 'update', '--init', '--depth=1', 'td')
Write-Ok 'Submodule ready'

# ── Step 2: Setup vcpkg ───────────────────────────────────────────────────────
Write-Banner 'Setting up vcpkg'

if (-not (Test-Path (Join-Path $VcpkgDir '.git'))) {
    if (Test-Path $VcpkgDir) { Remove-Item -Recurse -Force $VcpkgDir }
    Write-Info "Cloning vcpkg..."
    Invoke-Cmd git @('clone', 'https://github.com/microsoft/vcpkg.git', $VcpkgDir)
}

Write-Info "Checking out pinned vcpkg commit: $VcpkgCommit"
Invoke-Cmd git @('-C', $VcpkgDir, 'fetch', '--quiet', 'origin')
Invoke-Cmd git @('-C', $VcpkgDir, 'checkout', $VcpkgCommit)

$BootstrapScript = Join-Path $VcpkgDir 'bootstrap-vcpkg.bat'
if (-not (Test-Path (Join-Path $VcpkgDir 'vcpkg.exe'))) {
    Write-Info 'Bootstrapping vcpkg...'
    & $BootstrapScript -disableMetrics
    if ($LASTEXITCODE -ne 0) { Write-Fail 'vcpkg bootstrap failed' }
}

$VcpkgExe      = Join-Path $VcpkgDir 'vcpkg.exe'
$VcpkgToolchain = Join-Path $VcpkgDir 'scripts\buildsystems\vcpkg.cmake'

# Install required packages
Write-Info "Installing vcpkg packages for $VcpkgTriplet..."
$VcpkgPackages = @(
    "gperf:${VcpkgArch}-windows",
    "openssl:${VcpkgTriplet}",
    "zlib:${VcpkgTriplet}"
)
foreach ($pkg in $VcpkgPackages) {
    Invoke-Cmd $VcpkgExe @('install', $pkg, '--recurse')
}
Write-Ok 'vcpkg packages installed'

# ── Step 3: Apply patch (JNI only) ────────────────────────────────────────────
function Invoke-Patch {
    Write-Banner 'Applying native-bridge-jni patch'

    if (-not (Test-Path $PatchFile)) {
        Write-Fail "Patch file not found: $PatchFile"
    }

    # Check if already applied (reverse check)
    $reverseCheck = & git -C $TdDir apply --check --reverse $PatchFile 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Info 'Patch already applied, skipping'
        return
    }

    # Verify applies cleanly
    $forwardCheck = & git -C $TdDir apply --check $PatchFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Patch does not apply cleanly to td/. Resolve conflicts manually.`n$forwardCheck"
    }

    Invoke-Cmd git @('-C', $TdDir, 'apply', $PatchFile)
    Write-Ok 'Patch applied'
}

# ── Build functions ────────────────────────────────────────────────────────────

function Build-Static {
    $OutDir    = Join-Path $ProjectRoot "out\windows\$OutSuffix"
    $BuildSub  = Join-Path $BuildDir    "windows-static-$OutSuffix"

    Write-Banner "Building TDLib static — windows/$OutSuffix"

    New-Item -ItemType Directory -Force -Path $BuildSub | Out-Null

    Invoke-Cmd cmake @(
        '-A', $CmakeArch,
        '-S', $TdDir,
        '-B', $BuildSub,
        "-DCMAKE_BUILD_TYPE=Release",
        '-DTD_ENABLE_JNI=OFF',
        '-DOPENSSL_USE_STATIC_LIBS=ON',
        "-DCMAKE_TOOLCHAIN_FILE=$VcpkgToolchain",
        "-DVCPKG_TARGET_TRIPLET=$VcpkgTriplet"
    )

    Invoke-Cmd cmake @(
        '--build', $BuildSub,
        '--target', 'tdjson_static',
        '--config', 'Release',
        '--parallel', "$Nproc"
    )

    # Manual copy of artifacts
    $OutLib = Join-Path $OutDir 'lib'
    $OutInc = Join-Path $OutDir 'include\td\telegram'
    New-Item -ItemType Directory -Force -Path $OutLib | Out-Null
    New-Item -ItemType Directory -Force -Path $OutInc | Out-Null

    # Copy .lib files from build dir (Release config subdir on MSVC)
    Get-ChildItem -Path $BuildSub -Recurse -Filter '*.lib' | ForEach-Object {
        Copy-Item $_.FullName -Destination $OutLib -Force -Verbose
    }

    # Copy specific headers
    $ExportHeader = Join-Path $BuildSub 'td\telegram\tdjson_export.h'
    if (Test-Path $ExportHeader) { Copy-Item $ExportHeader -Destination $OutInc -Force -Verbose }
    $JsonClientH = Join-Path $TdDir 'td\telegram\td_json_client.h'
    if (Test-Path $JsonClientH) { Copy-Item $JsonClientH -Destination (Join-Path $OutDir 'include') -Force -Verbose }
    $LogH = Join-Path $TdDir 'td\telegram\td_log.h'
    if (Test-Path $LogH) { Copy-Item $LogH -Destination (Join-Path $OutDir 'include') -Force -Verbose }

    Write-Ok "Static build complete -> $OutDir"
}

function Build-Jni {
    $BuildSub = Join-Path $BuildDir "windows-jni-$OutSuffix"
    $OutDir   = Join-Path $ProjectRoot "out\windows-jni\$OutSuffix"

    # Resolve JAVA_HOME
    $JavaHome = $env:JAVA_HOME
    if (-not $JavaHome -or -not (Test-Path $JavaHome)) {
        Write-Fail "JAVA_HOME is not set or does not exist. Set it to a JDK installation (e.g. C:\Program Files\Eclipse Adoptium\jdk-17)."
    }
    # Convert backslashes to forward slashes — CMake's FindJNI fails on Windows
    # paths that contain backslash escape sequences like \h, \u, \j, etc.
    $JavaHome = $JavaHome -replace '\\', '/'
    Write-Info "JAVA_HOME = $JavaHome"

    Write-Banner "Building TDLib JNI — windows/$OutSuffix"

    New-Item -ItemType Directory -Force -Path $BuildSub | Out-Null

    # Locate vcpkg-installed gperf.  gperf is always installed with the plain
    # x64-windows (or arm64-windows) triplet, but the JNI build uses the
    # static-md triplet.  The vcpkg toolchain does not search across triplets,
    # so we need to pass -DGPERF_EXECUTABLE explicitly.
    $GperfExe = Join-Path $VcpkgDir "installed\${VcpkgArch}-windows\tools\gperf\gperf.exe"
    if (-not (Test-Path $GperfExe)) {
        Write-Fail "gperf not found at $GperfExe — did vcpkg install gperf:${VcpkgArch}-windows succeed?"
    }
    Write-Info "Using gperf: $GperfExe"

    # Build via root CMakeLists.txt with TD_ANDROID_JSON_JAVA=ON to produce
    # the proper tdjni shared library (tdjsonjava.dll) with td_jni.cpp.
    # TD_PACK_STATIC_DEPS=ON ensures OpenSSL and zlib are statically linked so
    # the resulting DLL is portable (Windows does not ship either library).
    Invoke-Cmd cmake @(
        '-A', $CmakeArch,
        '-S', $ProjectRoot,
        '-B', $BuildSub,
        '-DCMAKE_BUILD_TYPE=Release',
        '-DTD_ANDROID_JSON_JAVA=ON',
        '-DTD_PACK_STATIC_DEPS=ON',
        "-DCMAKE_TOOLCHAIN_FILE=$VcpkgToolchain",
        "-DVCPKG_TARGET_TRIPLET=$VcpkgTriplet",
        "-DJAVA_HOME=$JavaHome",
        "-DGPERF_EXECUTABLE=$GperfExe"
    )

    Invoke-Cmd cmake @(
        '--build', $BuildSub,
        '--target', 'tdjni',
        '--config', 'Release',
        '--parallel', "$Nproc"
    )

    # Manual copy of shared library
    $OutLib = Join-Path $OutDir 'lib'
    New-Item -ItemType Directory -Force -Path $OutLib | Out-Null

    # Copy tdjsonjava.dll and tdjsonjava.lib from build dir
    Get-ChildItem -Path $BuildSub -Recurse -Filter 'tdjsonjava.dll' | ForEach-Object {
        Copy-Item $_.FullName -Destination $OutLib -Force -Verbose
    }
    Get-ChildItem -Path $BuildSub -Recurse -Filter 'tdjsonjava.lib' | ForEach-Object {
        Copy-Item $_.FullName -Destination $OutLib -Force -Verbose
    }

    Write-Ok "JNI build complete -> $OutDir"
}

# ── Dispatch ───────────────────────────────────────────────────────────────────
switch ($Target) {
    'tdlib' {
        Build-Static
    }
    'tdlib_jni' {
        Invoke-Patch
        Build-Jni
    }
}

Write-Banner 'Build finished successfully'
Write-Ok "Target  : $Target"
Write-Ok "Platform: $Platform"
