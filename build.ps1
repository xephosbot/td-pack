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

# ── Toolchain: Ninja + clang-cl + sccache ──────────────────────────────────────
# We build with the Ninja generator and clang-cl instead of the MSVC/MSBuild
# generator for two reasons:
#   * size  — clang produces far leaner static .lib than cl.exe (MSVC tdcore.lib
#             was ~536 MB vs ~100 MB for the same code under clang on Linux);
#   * speed — Ninja + sccache caches compilation, so warm CI builds drop from
#             ~40 min to a few minutes (MSBuild does not cache cleanly).
# clang-cl is ABI-compatible with MSVC, so vcpkg's *-windows triplets still work.
# The arch is taken from the Developer Command Prompt environment (set by the CI
# 'msvc-dev-cmd' step or a local VS prompt), so no -A/--target is needed.
function Find-ClangCl {
    # Escape hatch: set TDPACK_USE_CLANG=0 to force MSVC cl.exe (e.g. if clang-cl
    # hits a known arm64 codegen bug). sccache/Ninja still apply, so speed is kept.
    if ($env:TDPACK_USE_CLANG -in @('0', 'false', 'off')) {
        Write-Info 'TDPACK_USE_CLANG disabled — using MSVC cl.exe'
        return $null
    }
    $c = Get-Command clang-cl -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'LLVM\bin\clang-cl.exe')
    )
    foreach ($vs in @('Enterprise','Professional','Community','BuildTools')) {
        $candidates += "${env:ProgramFiles}\Microsoft Visual Studio\2022\$vs\VC\Tools\Llvm\x64\bin\clang-cl.exe"
        $candidates += "${env:ProgramFiles}\Microsoft Visual Studio\2022\$vs\VC\Tools\Llvm\bin\clang-cl.exe"
    }
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function Get-ToolchainArgs {
    $a = @('-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release')
    $clang = Find-ClangCl
    if ($clang) {
        $clangFwd = $clang -replace '\\', '/'
        Write-Info "Compiler: clang-cl ($clang)"
        $a += @("-DCMAKE_C_COMPILER=$clangFwd", "-DCMAKE_CXX_COMPILER=$clangFwd")
    } else {
        Write-Warn 'clang-cl not found — falling back to MSVC cl.exe (size win lost, sccache still applies)'
        $a += @('-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl')
    }
    if (Get-Command sccache -ErrorAction SilentlyContinue) {
        Write-Info 'Compiler launcher: sccache'
        $a += @('-DCMAKE_C_COMPILER_LAUNCHER=sccache', '-DCMAKE_CXX_COMPILER_LAUNCHER=sccache')
    } else {
        Write-Warn 'sccache not found — building without compiler cache'
    }
    return $a
}

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

# ── Step 3: Apply a build-time patch to the td submodule (idempotent) ──────────
function Invoke-TdPatch {
    param([string]$Patch, [string]$Label)
    Write-Banner "Applying $Label patch"

    if (-not (Test-Path $Patch)) {
        Write-Fail "Patch file not found: $Patch"
    }

    # Already applied? (reverse check succeeds)
    & git -C $TdDir apply --check --reverse $Patch 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Info 'Patch already applied, skipping'
        return
    }

    # Verify it applies cleanly
    $forwardCheck = & git -C $TdDir apply --check $Patch 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Patch does not apply cleanly to td/. Resolve conflicts manually.`n$forwardCheck"
    }

    Invoke-Cmd git @('-C', $TdDir, 'apply', $Patch)
    Write-Ok 'Patch applied'
}

# clang-cl support: td's TdSetUpCompiler.cmake routes clang-cl into its GNU
# Clang path (-std=c++17), which clang-cl's cl-style driver rejects. This
# one-line build-time patch makes clang-cl (MSVC=true) use td's MSVC flag path
# instead. No-op for real MSVC and for GNU clang/gcc on Linux/macOS.
$ClangClPatch = Join-Path $ProjectRoot 'patches\clang-cl-support.patch'

# ── Helper: strip static libraries in-place ────────────────────────────────────
# MSVC ships no 'strip'; LLVM's llvm-objcopy understands COFF archives.  We only
# drop debug info (safe — keeps every symbol needed for linking).  The bulk of
# the Windows size reduction comes from the explicit lib list in Build-Static
# and MinSizeRel, not from this step, so a missing llvm-objcopy is non-fatal.
function Optimize-StaticLibs {
    param([string]$LibDir)

    $libs = Get-ChildItem -Path $LibDir -Filter '*.lib' -ErrorAction SilentlyContinue
    if (-not $libs) { Write-Warn "No .lib files to strip in $LibDir"; return }

    $tool = Get-Command llvm-objcopy -ErrorAction SilentlyContinue
    if (-not $tool) {
        # Try the bundled VS/LLVM location before giving up.
        $candidate = Join-Path ${env:ProgramFiles} 'LLVM\bin\llvm-objcopy.exe'
        if (Test-Path $candidate) { $tool = $candidate } else { $tool = $null }
    }
    if (-not $tool) {
        Write-Warn 'llvm-objcopy not found — skipping .lib strip (size unaffected)'
        return
    }

    $before = [math]::Round(($libs | Measure-Object Length -Sum).Sum / 1MB, 1)
    foreach ($lib in $libs) {
        & $tool --strip-debug $lib.FullName 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Warn "strip-debug failed for $($lib.Name) — kept as-is" }
    }
    $after = [math]::Round((Get-ChildItem -Path $LibDir -Filter '*.lib' | Measure-Object Length -Sum).Sum / 1MB, 1)
    Write-Ok "Static libs stripped: $before MB -> $after MB"
}

# ── Build functions ────────────────────────────────────────────────────────────

function Build-Static {
    $OutDir    = Join-Path $ProjectRoot "out\windows\$OutSuffix"
    $BuildSub  = Join-Path $BuildDir    "windows-static-$OutSuffix"

    Write-Banner "Building TDLib static — windows/$OutSuffix"

    New-Item -ItemType Directory -Force -Path $BuildSub | Out-Null

    # Ninja + clang-cl + sccache (Get-ToolchainArgs). Release, not MinSizeRel:
    # with td's function-level sections, /O1 produces more COMDAT sections →
    # larger, less-compressible .lib (measured).
    Invoke-Cmd cmake (@(
        '-S', $TdDir,
        '-B', $BuildSub
    ) + (Get-ToolchainArgs) + @(
        '-DTD_ENABLE_JNI=OFF',
        '-DOPENSSL_USE_STATIC_LIBS=ON',
        "-DCMAKE_TOOLCHAIN_FILE=$VcpkgToolchain",
        "-DVCPKG_TARGET_TRIPLET=$VcpkgTriplet"
    ))

    Invoke-Cmd cmake @(
        '--build', $BuildSub,
        '--target', 'tdjson_static',
        '--parallel', "$Nproc"
    )

    # Manual copy of artifacts
    $OutLib = Join-Path $OutDir 'lib'
    $OutInc = Join-Path $OutDir 'include\td\telegram'
    New-Item -ItemType Directory -Force -Path $OutLib | Out-Null
    New-Item -ItemType Directory -Force -Path $OutInc | Out-Null

    # Log every .lib in the build tree (path + size) so the windows-arm64 vs
    # x64 size gap is visible in CI, then ship ONLY the TDLib static libs
    # (td*.lib) plus OpenSSL/zlib — this excludes example/test/benchmark and
    # stray dependency libs that the previous blanket recursive copy pulled in.
    $allLibs = Get-ChildItem -Path $BuildSub -Recurse -Filter '*.lib'
    Write-Info "All .lib under build tree ($($allLibs.Count)):"
    $allLibs | Sort-Object Length -Descending | ForEach-Object {
        Write-Host ('  {0,8:N1} MB  {1}' -f ($_.Length / 1MB), $_.FullName)
    }

    $shipPattern = '^(td.*|libcrypto.*|libssl.*|crypto|ssl|zlib.*|zstd.*)$'
    $shipped = $allLibs |
        Where-Object { $_.BaseName -match $shipPattern } |
        Sort-Object Name -Unique
    if (-not $shipped) { Write-Fail "No shippable .lib found under $BuildSub" }
    Write-Info "Shipping $($shipped.Count) libs:"
    foreach ($lib in $shipped) {
        Copy-Item $lib.FullName -Destination $OutLib -Force -Verbose
    }

    # Strip debug info from the shipped .lib files
    Optimize-StaticLibs -LibDir $OutLib

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
        Write-Fail "JAVA_HOME is not set or does not exist. Set it to a JDK installation (e.g. C:\Program Files\Eclipse Adoptium\jdk-21)."
    }
    # CMake's FindJNI.cmake passes JAVA_HOME into a foreach() which treats
    # backslashes as escape characters (e.g. \h in \hostedtoolcache → error).
    # Convert to forward slashes so CMake parses the path correctly.
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
    Invoke-Cmd cmake (@(
        '-S', $ProjectRoot,
        '-B', $BuildSub
    ) + (Get-ToolchainArgs) + @(
        '-DTD_ANDROID_JSON_JAVA=ON',
        '-DTD_PACK_STATIC_DEPS=ON',
        "-DCMAKE_TOOLCHAIN_FILE=$VcpkgToolchain",
        "-DVCPKG_TARGET_TRIPLET=$VcpkgTriplet",
        "-DJAVA_HOME=$JavaHome",
        "-DGPERF_EXECUTABLE=$GperfExe"
    ))

    Invoke-Cmd cmake @(
        '--build', $BuildSub,
        '--target', 'tdjni',
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
# When building with clang-cl, patch td so it uses its MSVC flag path.
if (Find-ClangCl) {
    Invoke-TdPatch -Patch $ClangClPatch -Label 'clang-cl-support'
}

switch ($Target) {
    'tdlib' {
        Build-Static
    }
    'tdlib_jni' {
        Invoke-TdPatch -Patch $PatchFile -Label 'native-bridge-jni'
        Build-Jni
    }
}

Write-Banner 'Build finished successfully'
Write-Ok "Target  : $Target"
Write-Ok "Platform: $Platform"
