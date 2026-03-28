# td-pack

Prebuilt [TDLib](https://github.com/tdlib/td) libraries for all major platforms, built with CMake and [Conan](https://conan.io).

## Supported platforms

### Native static libraries (for Kotlin/Native, C/C++)

| Platform | Architectures |
|----------|--------------|
| iOS | arm64, arm64-simulator, x86_64-simulator |
| macOS | arm64, x86_64 |
| Linux | x86_64, arm64 |
| Windows | x64, arm64 |

### JNI shared libraries (for JVM / Android)

| Platform | Architectures |
|----------|--------------|
| Android | arm64-v8a, armeabi-v7a, x86_64, x86 |
| macOS | arm64, x86_64 |
| Linux | x86_64, arm64 |
| Windows | x64, arm64 |

> **Note:** JNI builds produce the **JSONJava** interface library (`libtdjsonjava`) — a shared
> library compiled from `td_jni.cpp` with `TD_JSON_JAVA=1`.

## Building

### Prerequisites

- [CMake](https://cmake.org) 3.19+
- [Conan](https://conan.io) 2.x (`pip install conan`)
- `gperf` (install via `apt`, `brew`, or `choco`)
- Android NDK (for Android targets, set `ANDROID_NDK_HOME`)
- Xcode (for iOS/macOS targets)
- Visual Studio 2022 (for Windows targets)
- JDK with `JAVA_HOME` set (for JNI targets)

### Setup

```bash
# Install Conan and detect your default profile
pip install conan
conan profile detect --force
```

### Build commands

**Unix (macOS / Linux / Android / iOS):**

```bash
# Static library
./build.sh macos-arm64 tdlib
./build.sh linux-x86_64 tdlib
./build.sh ios-arm64 tdlib

# JNI shared library
./build.sh macos-arm64 tdlib_jni
./build.sh linux-x86_64 tdlib_jni
./build.sh android-arm64-v8a tdlib_jni
```

**Windows (PowerShell):**

```powershell
# Static library
.\build.ps1 -Platform windows-x64 -Target tdlib

# JNI shared library
.\build.ps1 -Platform windows-x64 -Target tdlib_jni
```

### Available platforms

| Platform | Allowed targets |
|----------|----------------|
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
| `ios-arm64-simulator` | tdlib |
| `ios-x86_64-simulator` | tdlib |

Build outputs are placed in `build/<platform>-<target>/`.

## Project structure

```
├── CMakeLists.txt       # JNI wrapper CMake (uses td/ via add_subdirectory)
├── conanfile.py         # Conan 2.x dependency declaration (OpenSSL, zlib)
├── build.sh             # Unix build script
├── build.ps1            # Windows build script
├── profiles/            # Conan cross-compilation profiles (one per platform)
├── patches/             # Patches applied to TDLib source
└── .github/workflows/   # CI workflow (19 builds)
```

## License

TDLib is licensed under the terms of the Boost Software License. See [LICENSE_1_0.txt](https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt) for details.
