# td-pack

Prebuilt [TDLib](https://github.com/tdlib/td) libraries for all major platforms.

## How it works

The entire build runs in CI; nothing needs to be installed locally to get the binaries.

## Supported platforms

### Static libraries (Kotlin/Native, C/C++)

| Platform | Architectures |
|----------|--------------|
| iOS | arm64, arm64-simulator, x86_64-simulator |
| macOS | arm64, x86_64 |
| Linux | x86_64, arm64 |
| Windows | x64, arm64 |

### JNI shared libraries (JVM / Android)

| Platform | Architectures |
|----------|--------------|
| Android | arm64-v8a, armeabi-v7a, x86_64, x86 |
| macOS | arm64, x86_64 |
| Linux | x86_64, arm64 |
| Windows | x64, arm64 |

## Local build

You can also build locally using the included scripts.

**Unix (macOS / Linux / Android / iOS):**

```bash
./build.sh <target> <platform>
```

**Windows (on Windows host only):**

```powershell
.\build.ps1 -Target <target> -Platform <platform>
```

### Targets and platforms

| Platform | Targets |
|----------|---------|
| `macos-arm64` | tdlib, tdlib_jni |
| `macos-x86_64` | tdlib, tdlib_jni |
| `linux-x86_64` | tdlib, tdlib_jni |
| `linux-arm64` | tdlib, tdlib_jni |
| `windows-x64` | tdlib, tdlib_jni |
| `windows-arm64` | tdlib, tdlib_jni |
| `android-arm64-v8a` | tdlib_jni |
| `android-armeabi-v7a` | tdlib_jni |
| `android-x86_64` | tdlib_jni |
| `android-x86` | tdlib_jni |
| `ios-arm64` | tdlib |

### Prerequisites

**All platforms:**
- [CMake](https://cmake.org) ≥ 3.19
- [OpenSSL](https://www.openssl.org) (static libraries and headers)
- `gperf`
- C/C++ toolchain (GCC, Clang, or MSVC)

**macOS:**
- Xcode (provides the compiler, SDK, and `make`)
- `gperf`, `cmake` via Homebrew (`brew install gperf cmake`)
- Pre-built OpenSSL at `third_party/openssl/macos/<arch>/` — build it with `./scripts/build-openssl-macos.sh` (arm64 + x86_64, from source, no Rosetta)

**Linux:**
- OpenSSL dev package (`apt install libssl-dev` or equivalent) — used by the host code generator and JNI builds
- `make`
- Static (`tdlib`) builds compile with the Kotlin/Native GCC 8.3 toolchains
  (glibc 2.19 for x86_64, 2.25 for arm64) so the archives link against the
  K/N sysroot. The toolchain downloads automatically
  (`scripts/get-linux-toolchain.sh`); build OpenSSL with it first:
  `./scripts/build-openssl-linux.sh`. Requires an x86_64 Linux host
  (arm64 is cross-compiled).

**Windows:**
- Visual Studio 2022
- The build script (`build.ps1`) automatically sets up [vcpkg](https://github.com/microsoft/vcpkg) and installs OpenSSL, zlib, and gperf through it

**JNI targets (`tdlib_jni`):**
- JDK with `JAVA_HOME` set

**Android (`android-*`):**
- Android NDK (set `ANDROID_NDK_ROOT` or `ANDROID_NDK`)
- Pre-built OpenSSL for Android at `third_party/openssl/android/<abi>/` — build it with `./scripts/build-openssl-android.sh`

**iOS (`ios-*`):**
- Xcode
- Pre-built OpenSSL for iOS at `third_party/openssl/ios/<platform>/` — build it with `./scripts/build-openssl-ios.sh`
| `ios-arm64-simulator` | tdlib |
| `ios-x86_64-simulator` | tdlib |

Build outputs go to `out/<platform>/`.

## License

TDLib is licensed under the Boost Software License. See [LICENSE_1_0.txt](https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt).
