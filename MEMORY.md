# Memory Index — td-pack

- [TDLib Cross-Platform Integration Plan](#tdlib-cross-platform-integration-plan) — 19 архивов .tar.gz для KMP, 6 фаз, имена ассетов, структура содержимого, матрица CI/CD

---

# TDLib Cross-Platform Integration Plan

**Версия 1.0 · Март 2026**

**Цель:** Собрать TDLib для KMP-проекта в виде 19 независимых `.tar.gz` архивов, публикуемых на GitHub Releases. Gradle-плагин (`TdlibDependencies`) скачивает только нужные архивы лениво по имени ассета.

## Матрица 19 архивов

| Платформа / ABI | Имя архива (.tar.gz) | Локальная папка в libs/ |
|---|---|---|
| Windows x64 — static | `tdlib-windows-x64` | windows-x64 |
| Windows arm64 — static | `tdlib-windows-arm64` | windows-arm64 |
| macOS x86_64 — static | `tdlib-macos-x86_64` | macos-x86_64 |
| macOS arm64 — static | `tdlib-macos-arm64` | macos-arm64 |
| Linux x86_64 — static | `tdlib-linux-x86_64` | linux-x86_64 |
| Linux arm64 — static | `tdlib-linux-arm64` | linux-arm64 |
| Windows x64 — jni | `tdlib-windows-jni-x64` | windows-x64-jni |
| Windows arm64 — jni | `tdlib-windows-jni-arm64` | windows-arm64-jni |
| macOS x86_64 — jni | `tdlib-macos-jni-x86_64` | macos-x86_64-jni |
| macOS arm64 — jni | `tdlib-macos-jni-arm64` | macos-arm64-jni |
| Linux x86_64 — jni | `tdlib-linux-jni-x86_64` | linux-x86_64-jni |
| Linux arm64 — jni | `tdlib-linux-jni-arm64` | linux-arm64-jni |
| Android arm64-v8a | `tdlib-android-arm64-v8a` | android-arm64-v8a |
| Android armeabi-v7a | `tdlib-android-armeabi-v7a` | android-armeabi-v7a |
| Android x86 | `tdlib-android-x86` | android-x86 |
| Android x86_64 | `tdlib-android-x86_64` | android-x86_64 |
| iOS arm64 device | `tdlib-ios-arm64` | ios-arm64 |
| iOS x86_64 simulator | `tdlib-ios-x86_64-simulator` | ios-x86_64-simulator |
| iOS arm64 simulator | `tdlib-ios-arm64-simulator` | ios-arm64-simulator |

**Итого: 19 архивов = 12 десктоп (6 static + 6 JNI) + 4 Android JNI + 3 iOS static**

## Структура содержимого архивов

| Тип сборки | Содержимое архива |
|---|---|
| Статика (десктоп, iOS) | `lib/libtdjson_static.a`, `lib/libtdjson_private.a`, `lib/libtdclient.a`, `lib/libtdcore.a`, `lib/libtdapi.a`, `lib/libtdactor.a`, `lib/libtdutils.a`, `lib/libtddb.a`, `lib/libtdsqlite.a`, `lib/libtdnet.a`, `lib/libtdmtproto.a`, `lib/libtde2e.a`, `lib/libcrypto.a`, `lib/libssl.a`, `include/` |
| JNI десктоп | `lib/libtdjni.so` (Linux) / `lib/libtdjni.dylib` (macOS) / `lib/tdjni.dll` (Windows) + `include/` |
| JNI Android | `lib/libtdjni.so` (без `include/` — берут из static-архива) |

**Ключевые правила:**
- `TD_ENABLE_JNI=ON` — только JNI-сборки (desktop JVM + Android). Статика и iOS — без JNI
- iOS — три отдельных `.a` (не XCFramework). Каждый слайс — отдельный архив
- macOS/Windows/Linux: две независимые сборки — static и jni (разные `build-dir`)
- 13 статических `.a` на архив (включая `libcrypto` и `libssl`)
- JNI-архив десктоп содержит `include/` — Android JNI `include/` не нужен

## Фазы реализации

### Фаза 1 — Анализ и Подготовка (~2–3 дня, Высокий приоритет)
- Аудит CMake-флагов TDLib (общие / Windows / macOS / Linux / Android / iOS)
- Аудит зависимостей: OpenSSL (≥1.1.1), zlib (≥1.2.11)
- Выбор менеджера зависимостей (vcpkg / Conan / FetchContent)
- Статическая vs динамическая линковка OpenSSL и zlib

### Фаза 2 — Структура CMake (~4–6 дней, Высокий приоритет)
- Платформо-зависимые файлы: `cmake/platforms/{windows,macos,linux,android,ios}.cmake`
- Интеграция toolchain (`find_package(OpenSSL)`, `find_package(ZLIB)`)
- Профиль **static**: `TD_ENABLE_JNI=OFF`, `BUILD_SHARED_LIBS=OFF`
- Профиль **jni**: `TD_ENABLE_JNI=ON`, `BUILD_SHARED_LIBS=ON`, `find_package(JNI REQUIRED)`
- `BUILD_TESTING=OFF` во всех профилях
- iOS: `CMAKE_OSX_ARCHITECTURES` и `IPHONEOS_DEPLOYMENT_TARGET >= 13.0`

### Фаза 3 — Сборка зависимостей (~3–5 дней, Высокий приоритет)
- **OpenSSL** статически: Windows (vcpkg), macOS (brew), Linux (apt/src), Android (prebuilt per ABI), iOS (per sysroot)
- **zlib** статически: Windows (vcpkg), macOS/Linux (системная), Android (NDK `-lz`), iOS (`libz.tbd`)
- **JDK** только для десктоп JNI; Android JNI использует NDK, не JDK

### Фаза 4 — CI/CD (~4–6 дней, Высокий приоритет)

**21 job (19 сборок + release job):**

| Платформа | Раннер | Jobs |
|---|---|---|
| Windows x64 | `windows-latest` | static + jni |
| Windows arm64 | `windows-11-arm` | static + jni |
| macOS x86_64 | `macos-15-intel` | static + jni |
| macOS arm64 | `macos-15` | static + jni |
| Linux x86_64 | `ubuntu-latest` | static + jni |
| Linux arm64 | `ubuntu-24.04-arm` | static + jni |
| Android (4 ABI) | `ubuntu-latest` + NDK | jni (двухпроходная) |
| iOS (3 слайса) | `macos-15` | static (двухпроходная) |

**Двухпроходная сборка (Android + iOS):**
1. Проход 1 (хост): `cmake ... && make prepare_cross_compiling`
2. Проход 2 (таргет): cmake с NDK/Xcode toolchain

**Публикация:**
- `tar -czf tdlib-{os}-{arch}.tar.gz lib/ include/` (strip root dir)
- Финальный job `release` (needs: все 19) публикует на GitHub Releases
- URL: `github.com/xephosbot/td-pack/releases/download/v{ver}/{asset}.tar.gz`
- Имя ассета должно точно совпадать с `assetName()` в `TdlibDependencies.kt`

**Кэширование:** ccache, vcpkg `installed/`, `prepare_cross_compiling` артефакты

### Фаза 5 — Тестирование (внешнее репо)
- Интеграционные тесты — в KMP-проекте-потребителе (отдельный CI пайплайн)
- `td-pack` отвечает только за сборку и публикацию артефактов

### Фаза 6 — Документация (~1–2 дня, Низкий приоритет)
- README: таблица всех 19 архивов, логика `assetName()` и `localDir()`
- Troubleshooting: 404 не найден, OpenSSL not found, Windows `/MD` vs `/MT`, iOS sysroot, Android NDK версии

## Сводная таблица фаз

| # | Фаза | Оценка | Приоритет |
|---|---|---|---|
| 1 | Анализ и Подготовка | 2–3 дня | Высокий |
| 2 | Структура CMake | 4–6 дней | Высокий |
| 3 | Сборка зависимостей | 3–5 дней | Высокий |
| 4 | CI/CD (19 job) | 4–6 дней | Высокий |
| 5 | Тестирование (внешнее репо) | — | Внешний |
| 6 | Документация | 1–2 дня | Низкий |

**Итого: ~16–26 рабочих дней до первого стабильного релиза всех 19 артефактов.**
