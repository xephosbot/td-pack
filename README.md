# td-pack

Готовые сборки [TDLib](https://github.com/tdlib/td) под все основные платформы.

## Как это работает

Вся сборка полностью автоматизирована через **GitHub Actions**. Никаких Conan, Bazel и прочих менеджеров зависимостей — только CMake и shell-скрипты.

При пуше тега `v*.*.*` (или ручном запуске workflow) CI собирает библиотеки под все платформы и выкладывает артефакты в релиз.

## Форк для своих нужд

1. Сделайте форк репозитория
2. При необходимости измените патчи, настройки или платформы в `.github/workflows/build.yml`
3. Запустите workflow вручную или создайте тег — готовые библиотеки появятся в артефактах

Сборка работает полностью в CI, локально ничего ставить не нужно.

## Поддерживаемые платформы

### Статические библиотеки (Kotlin/Native, C/C++)

| Платформа | Архитектуры |
|-----------|------------|
| iOS | arm64, arm64-simulator, x86_64-simulator |
| macOS | arm64, x86_64 |
| Linux | x86_64, arm64 |
| Windows | x64, arm64 |

### JNI shared-библиотеки (JVM / Android)

| Платформа | Архитектуры |
|-----------|------------|
| Android | arm64-v8a, armeabi-v7a, x86_64, x86 |
| macOS | arm64, x86_64 |
| Linux | x86_64, arm64 |
| Windows | x64, arm64 |

## Структура проекта

```
├── CMakeLists.txt          # CMake-обёртка для JNI (использует td/ через add_subdirectory)
├── build.sh                # Скрипт сборки для Unix
├── build.ps1               # Скрипт сборки для Windows
├── scripts/                # Вспомогательные скрипты (сборка OpenSSL для iOS и т.д.)
├── patches/                # Патчи к исходникам TDLib
├── td/                     # Субмодуль TDLib
└── .github/workflows/      # CI-конфигурация (GitHub Actions)
```

## Лицензия

TDLib лицензирован на условиях Boost Software License. См. [LICENSE_1_0.txt](https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt).
