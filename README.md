# td-pack

Prebuilt [TDLib](https://github.com/tdlib/td) static libraries and headers for all major platforms. Builds are produced automatically via GitHub Actions and published as GitHub Releases.

## Supported platforms

### Native static libraries (for Kotlin/Native, C/C++)

| Platform | Architectures | Artifact |
|----------|--------------|----------|
| iOS | arm64 | `tdlib-ios-arm64` |
| macOS | arm64, x86_64 | `tdlib-macos-{arch}` |
| Linux | x86_64, arm64 | `tdlib-linux-{arch}` |
| Windows | x64, arm64 | `tdlib-windows-{arch}` |

### JNI shared libraries (for JVM / Android)

| Platform | Architectures | Artifact | Library |
|----------|--------------|----------|---------|
| Android | arm64-v8a, armeabi-v7a, x86_64, x86 | `tdlib-android` | `libtdjsonjava.so` |
| macOS | arm64, x86_64 | `tdlib-macos-jni-{arch}` | `libtdjsonjava.dylib` |
| Linux | x86_64, arm64 | `tdlib-linux-jni-{arch}` | `libtdjsonjava.so` |
| Windows | x64, arm64 | `tdlib-windows-jni-{arch}` | `tdjsonjava.dll` |

> **Note:** JNI builds produce the **JSONJava** interface library (`libtdjsonjava`) — a shared
> library compiled from `td_jni.cpp` with `TD_JSON_JAVA=1`.  It contains `JNI_OnLoad` +
> `RegisterNatives` that bind `nativeCreateClientId`, `nativeSend`, `nativeReceive`, and `nativeExecute` native methods
> to the Kotlin object **`io.xbot.tdlib.NativeBridge`** (custom package name and class, patched from the
> upstream default `org.drinkless.tdlib.JsonClient`).

## Artifact structure

Each native (static) artifact contains:

```
tdlib/{platform}/{arch}/
├── lib/
│   ├── libtdjson_static.a   (.lib on Windows)
│   ├── libtdjson_private.a   (and other TDLib internal libs)
│   ├── libcrypto.a           (.lib on Windows)
│   └── libssl.a              (.lib on Windows)
└── include/
    ├── td_json_client.h
    ├── td_log.h
    └── td/telegram/
        └── tdjson_export.h
```

---

## Using with Kotlin/Native

### 1. Download prebuilt libraries

Download the required platform archives from the [Releases](../../releases) page and unpack them into your project:

```
your-project/
├── libs/
│   └── tdlib/
│       ├── ios/
│       │   └── arm64/
│       │       ├── lib/  (*.a files)
│       │       └── include/  (*.h files)
│       ├── macos/
│       │   ├── arm64/
│       │   │   ├── lib/
│       │   │   └── include/
│       │   └── x86_64/
│       │       ├── lib/
│       │       └── include/
│       ├── linux/
│       │   └── x86_64/
│       │       ├── lib/
│       │       └── include/
│       └── windows/
│           └── x64/
│               ├── lib/
│               └── include/
├── src/
│   ├── nativeMain/
│   │   └── kotlin/
│   └── nativeInterop/
│       └── cinterop/
│           └── tdjson.def
└── build.gradle.kts
```

### 2. Create a cinterop definition file

Create `src/nativeInterop/cinterop/tdjson.def`:

```def
headers = td_json_client.h td_log.h
headerFilter = td_json_client.h td_log.h td/telegram/**

compilerOpts.osx = -I/path/to/libs/tdlib/macos/arm64/include
compilerOpts.linux_x64 = -I/path/to/libs/tdlib/linux/x86_64/include
compilerOpts.mingw_x64 = -I/path/to/libs/tdlib/windows/x64/include
compilerOpts.ios_arm64 = -I/path/to/libs/tdlib/ios/arm64/include

linkerOpts.osx = \
    -L/path/to/libs/tdlib/macos/arm64/lib \
    -ltdjson_static -ltdjson_private -ltdclient -ltdcore -ltddb -ltdsqlite -ltdnet -ltdactor -ltdutils \
    -lssl -lcrypto -lz -lc++

linkerOpts.linux_x64 = \
    -L/path/to/libs/tdlib/linux/x86_64/lib \
    -ltdjson_static -ltdjson_private -ltdclient -ltdcore -ltddb -ltdsqlite -ltdnet -ltdactor -ltdutils \
    -lssl -lcrypto -lz -lstdc++ -lm -ldl -lpthread

linkerOpts.ios_arm64 = \
    -L/path/to/libs/tdlib/ios/arm64/lib \
    -ltdjson_static -ltdjson_private -ltdclient -ltdcore -ltddb -ltdsqlite -ltdnet -ltdactor -ltdutils \
    -lssl -lcrypto -lz -lc++
```

> **Tip:** Use relative paths from your project root (e.g. `libs/tdlib/macos/arm64/...`) or set the paths via Gradle properties.

### 3. Configure `build.gradle.kts`

```kotlin
plugins {
    kotlin("multiplatform") version "2.1.0"
}

kotlin {
    // Choose your targets:
    macosArm64()
    macosX64()
    linuxX64()
    // iosArm64()
    // mingwX64()

    sourceSets {
        val nativeMain by creating {
            // Shared native code
        }
        
        // Link each target to nativeMain
        val macosArm64Main by getting { dependsOn(nativeMain) }
        val macosX64Main by getting { dependsOn(nativeMain) }
        val linuxX64Main by getting { dependsOn(nativeMain) }
    }

    targets.withType<org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget> {
        compilations["main"].cinterops {
            val tdjson by creating {
                defFile("src/nativeInterop/cinterop/tdjson.def")
            }
        }
    }
}
```

### 4. Use TDLib in Kotlin

After building, the cinterop plugin generates Kotlin bindings in the `tdjson` package:

```kotlin
import tdjson.*
import kotlinx.cinterop.*

fun main() {
    // Create a TDLib client
    val clientId = td_create_client_id()

    // Send a request (JSON string)
    td_send(clientId, """{"@type":"getOption","name":"version"}""")

    // Receive responses
    val response = td_receive(10.0)
    if (response != null) {
        println(response.toKString())
    }
}
```

### 5. Alternative: using `.def` with Gradle-configured paths

Instead of hardcoding paths in the `.def` file, you can configure them dynamically in Gradle:

```kotlin
targets.withType<org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget> {
    val libsDir = rootProject.file("libs/tdlib")
    
    val platformDir = when {
        name.startsWith("macos") && name.contains("Arm64") -> "macos/arm64"
        name.startsWith("macos") && name.contains("X64") -> "macos/x86_64"
        name.startsWith("linux") -> "linux/x86_64"
        name.startsWith("ios") && name.contains("Arm64") -> "ios/arm64"
        name.startsWith("mingw") -> "windows/x64"
        else -> error("Unsupported target: $name")
    }
    
    val tdlibDir = libsDir.resolve(platformDir)

    compilations["main"].cinterops {
        val tdjson by creating {
            defFile("src/nativeInterop/cinterop/tdjson.def")
            includeDirs(tdlibDir.resolve("include"))
        }
    }

    compilations["main"].kotlinOptions {
        freeCompilerArgs = listOf(
            "-linker-option", "-L${tdlibDir.resolve("lib").absolutePath}"
        )
    }
}
```

With this approach, the `.def` file can be simplified — Gradle sets the include/library search paths, while the `.def` only lists library names and platform-specific flags:

```def
headers = td_json_client.h td_log.h
headerFilter = td_json_client.h td_log.h td/telegram/**

# Library names only (search paths are set by Gradle above)
linkerOpts = -ltdjson_static -ltdjson_private -ltdclient -ltdcore -ltddb -ltdsqlite -ltdnet -ltdactor -ltdutils -lssl -lcrypto -lz

# Platform-specific system libraries
linkerOpts.osx = -lc++
linkerOpts.linux_x64 = -lstdc++ -lm -ldl -lpthread
linkerOpts.ios_arm64 = -lc++
```

---

## Build workflow

All platform builds run **in parallel** via GitHub Actions. The workflow is triggered manually (`workflow_dispatch`) and produces a GitHub Release with all artifacts.

```
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────────┐
│ version  │  │ android  │  │   ios    │  │  macos   │  │ macos-jni │
└────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └─────┬─────┘
     │             │             │             │               │
     │  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌───────────────┐
     │  │  linux   │  │linux-jni │  │  windows  │  │  windows-jni  │
     │  └────┬─────┘  └────┬─────┘  └─────┬─────┘  └──────┬────────┘
     │       │             │               │               │
     ▼       ▼             ▼               ▼               ▼
  ┌──────────────────────────────────────────────────────────┐
  │                       release                            │
  │  (collects all artifacts → creates GitHub Release)       │
  └──────────────────────────────────────────────────────────┘
```

### Running the build

1. Go to **Actions** → **Build** → **Run workflow**
2. Wait for all jobs to complete (~30–60 minutes)
3. A new release is created at **Releases** with tag `v{tdlib_version}`

### Building locally

Each platform has a pair of build scripts:

```bash
# 1. Build OpenSSL
./build-openssl-macos.sh openssl third-party/openssl arm64

# 2. Build TDLib
./build-tdlib-macos.sh td third-party/openssl arm64
```

Available scripts:

| Platform | OpenSSL script | TDLib static | TDLib JNI |
|----------|---------------|-------------|-----------|
| Android | `build-openssl-android.sh` | `build-tdlib-android.sh` | _(included)_ |
| iOS | `build-openssl-ios.sh` | `build-tdlib-ios.sh` | — |
| macOS | `build-openssl-macos.sh` | `build-tdlib-macos.sh` | `build-tdlib-jni-macos.sh` |
| Linux | `build-openssl-linux.sh` | `build-tdlib-linux.sh` | `build-tdlib-jni-linux.sh` |
| Windows | `build-openssl-windows.ps1` | `build-tdlib-windows.ps1` | `build-tdlib-windows.ps1 -EnableJni` |

## License

TDLib is licensed under the terms of the Boost Software License. See [td/LICENSE_1_0.txt](https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt) for details.
