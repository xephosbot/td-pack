# td-pack

Prebuilt [TDLib](https://github.com/tdlib/td) libraries for all major platforms, built with [Bazel](https://bazel.build).

## Supported platforms

### Native static libraries (for Kotlin/Native, C/C++)

| Platform | Architectures | Config |
|----------|--------------|--------|
| iOS | arm64, arm64-simulator, x86_64-simulator | `--config=ios-arm64` etc. |
| macOS | arm64, x86_64 | `--config=macos-arm64` etc. |
| Linux | x86_64, arm64 | `--config=linux-x86_64` etc. |
| Windows | x64, arm64 | `--config=windows-x64` etc. |

### JNI shared libraries (for JVM / Android)

| Platform | Architectures | Config |
|----------|--------------|--------|
| Android | arm64-v8a, armeabi-v7a, x86_64, x86 | `--config=android-arm64-v8a` etc. |
| macOS | arm64, x86_64 | `--config=macos-arm64` |
| Linux | x86_64, arm64 | `--config=linux-x86_64` etc. |

> **Note:** JNI builds produce the **JSONJava** interface library (`libtdjsonjava`) — a shared
> library compiled from `td_jni.cpp` with `TD_JSON_JAVA=1`.

## Building

### Prerequisites

- [Bazel](https://bazel.build) (version in `.bazelversion`)
- `gperf` (install via `apt`, `brew`, or `choco`)
- Android NDK (for Android targets, set `ANDROID_NDK_HOME`)
- Xcode (for iOS/macOS targets)

### Build commands

```bash
# Static library
bazel build //:tdlib --config=linux-x86_64
bazel build //:tdlib --config=macos-arm64
bazel build //:tdlib --config=ios-arm64

# JNI shared library
bazel build //:tdlib_jni --config=linux-x86_64
bazel build //:tdlib_jni --config=macos-arm64
bazel build //:tdlib_jni --config=android-arm64-v8a
bazel build //:tdlib_jni --config=android-armeabi-v7a
bazel build //:tdlib_jni --config=android-x86_64
bazel build //:tdlib_jni --config=android-x86
```

### Available configs

| Config | Platform |
|--------|----------|
| `linux-x86_64` | Linux x86_64 |
| `linux-arm64` | Linux aarch64 |
| `macos-x86_64` | macOS x86_64 |
| `macos-arm64` | macOS arm64 |
| `windows-x64` | Windows x64 |
| `windows-arm64` | Windows arm64 |
| `android-arm64-v8a` | Android arm64-v8a |
| `android-armeabi-v7a` | Android armeabi-v7a |
| `android-x86_64` | Android x86_64 |
| `android-x86` | Android x86 |
| `ios-arm64` | iOS device arm64 |
| `ios-arm64-simulator` | iOS simulator arm64 |
| `ios-x86_64-simulator` | iOS simulator x86_64 |

## Project structure

```
├── BUILD.bazel          # Main build targets (tdlib, tdlib_jni, openssl)
├── MODULE.bazel         # Bazel module deps (@td, @openssl, rules_foreign_cc, etc.)
├── CMakeLists.txt       # JNI wrapper CMake (used by tdlib_jni target)
├── .bazelrc             # Platform config aliases
├── .bazelversion        # Pinned Bazel version
├── platforms/           # Platform definitions (Linux, macOS, Windows, Android, iOS)
├── third_party/         # BUILD overlays for @td and @openssl
├── patches/             # Patches applied to @td via git_repository
└── .github/workflows/   # CI workflow
```

## License

TDLib is licensed under the terms of the Boost Software License. See [LICENSE_1_0.txt](https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt) for details.
