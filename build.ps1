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
Write-Info "Installing vcpkg packages for $VcpkgArch..."
$VcpkgPackages = @(
    "gperf:${VcpkgArch}-windows",
    "openssl:${VcpkgArch}-windows",
    "zlib:${VcpkgArch}-windows"
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
        '-DTD_ENABLE_LTO=ON',
        "-DCMAKE_TOOLCHAIN_FILE=$VcpkgToolchain",
        "-DVCPKG_TARGET_TRIPLET=${VcpkgArch}-windows"
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
    Write-Info "JAVA_HOME = $JavaHome"

    # Build JNI include flags for Windows (requires include\win32 subdir)
    $JavaInclude     = Join-Path $JavaHome 'include'
    $JavaIncludeWin  = Join-Path $JavaInclude 'win32'

    Write-Banner "Building TDLib JNI — windows/$OutSuffix"

    New-Item -ItemType Directory -Force -Path $BuildSub | Out-Null

    # Single-pass: configure TDLib directly with JNI enabled, build tdjson shared library
    Invoke-Cmd cmake @(
        '-A', $CmakeArch,
        '-S', $TdDir,
        '-B', $BuildSub,
        '-DCMAKE_BUILD_TYPE=Release',
        '-DTD_ENABLE_JNI=ON',
        '-DTD_ENABLE_LTO=OFF',
        "-DCMAKE_TOOLCHAIN_FILE=$VcpkgToolchain",
        "-DVCPKG_TARGET_TRIPLET=${VcpkgArch}-windows",
        "-DJAVA_HOME=$JavaHome",
        "-DJAVA_INCLUDE_PATH=$JavaInclude",
        "-DJAVA_INCLUDE_PATH2=$JavaIncludeWin"
    )

    Invoke-Cmd cmake @(
        '--build', $BuildSub,
        '--target', 'tdjson',
        '--config', 'Release',
        '--parallel', "$Nproc"
    )

    # Manual copy of shared library
    $OutLib = Join-Path $OutDir 'lib'
    New-Item -ItemType Directory -Force -Path $OutLib | Out-Null

    # Copy tdjson.dll and tdjson.lib from build dir
    Get-ChildItem -Path $BuildSub -Recurse -Filter 'tdjson.dll' | ForEach-Object {
        Copy-Item $_.FullName -Destination $OutLib -Force -Verbose
    }
    Get-ChildItem -Path $BuildSub -Recurse -Filter 'tdjson.lib' | ForEach-Object {
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
