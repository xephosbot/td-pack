cmake_minimum_required(VERSION 3.19 FATAL_ERROR)
project(tdlib-jni CXX)

# JNI package path, slash-separated
set(TD_JNI_PACKAGE "io/xbot/tdlib" CACHE STRING
    "JNI package path slash-separated (e.g. io/xbot/tdlib)")

# ── Find pre-built TDLib (installed in pass1) ──────────────────────────────
find_package(Td REQUIRED)

# ── Find JNI ───────────────────────────────────────────────────────────────
if(NOT JNI_FOUND)
  find_package(JNI REQUIRED COMPONENTS JVM)
endif()
message(STATUS "JNI includes : ${JNI_INCLUDE_DIRS}")
message(STATUS "JNI libraries: ${JNI_LIBRARIES}")

# ── libtdjni shared library ────────────────────────────────────────────────
# Source from TDLib submodule — patched before build
add_library(tdjni SHARED ${CMAKE_CURRENT_SOURCE_DIR}/td/example/java/td_jni.cpp)

target_compile_features(tdjni PRIVATE cxx_std_14)

target_compile_definitions(tdjni PRIVATE
  "PACKAGE_NAME=\"${TD_JNI_PACKAGE}\""
  TD_JSON_JAVA=1
)

target_include_directories(tdjni SYSTEM PRIVATE ${JNI_INCLUDE_DIRS})

target_link_libraries(tdjni PRIVATE
  Td::TdJsonStatic
  ${JAVA_JVM_LIBRARY}
)

# Flat output name (no lib prefix on Windows is handled by cmake automatically)
set_target_properties(tdjni PROPERTIES OUTPUT_NAME "tdjni")

if(APPLE)
  set_target_properties(tdjni PROPERTIES
    MACOSX_RPATH FALSE
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH ""
  )
endif()

install(TARGETS tdjni
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION lib
)
