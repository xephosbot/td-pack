cmake_minimum_required(VERSION 3.19 FATAL_ERROR)

project(TdAndroid VERSION 1.0 LANGUAGES CXX)

set(TD_DIR ${CMAKE_CURRENT_SOURCE_DIR}/td)

# Conan-provided dependencies
find_package(OpenSSL REQUIRED)
find_package(ZLIB REQUIRED)

# Conan's config-mode find_package creates imported targets but may not set
# the legacy Find-module variables (OPENSSL_INCLUDE_DIR, OPENSSL_CRYPTO_LIBRARY,
# ZLIB_LIBRARIES, etc.) that td's CMakeLists.txt uses for linking.
# Conan 2 CMakeDeps may name targets as openssl::crypto (lowercase) or
# OpenSSL::Crypto (capitalized) depending on recipe configuration.
# Bridge all variants here.

# --- OpenSSL include directory ---
if (NOT OPENSSL_INCLUDE_DIR)
  if (DEFINED OpenSSL_INCLUDE_DIRS)
    set(OPENSSL_INCLUDE_DIR "${OpenSSL_INCLUDE_DIRS}")
  else()
    foreach(_t openssl::crypto openssl::openssl OpenSSL::Crypto OpenSSL::OpenSSL)
      if (TARGET ${_t})
        get_target_property(_ossl_inc ${_t} INTERFACE_INCLUDE_DIRECTORIES)
        if (_ossl_inc)
          set(OPENSSL_INCLUDE_DIR "${_ossl_inc}")
          break()
        endif()
      endif()
    endforeach()
  endif()
endif()

# --- OpenSSL crypto library ---
if (NOT OPENSSL_CRYPTO_LIBRARY)
  foreach(_t openssl::crypto OpenSSL::Crypto openssl::openssl OpenSSL::OpenSSL)
    if (TARGET ${_t})
      set(OPENSSL_CRYPTO_LIBRARY ${_t})
      break()
    endif()
  endforeach()
endif()

# --- OpenSSL ssl library ---
if (NOT OPENSSL_SSL_LIBRARY)
  foreach(_t openssl::ssl OpenSSL::SSL openssl::openssl OpenSSL::OpenSSL)
    if (TARGET ${_t})
      set(OPENSSL_SSL_LIBRARY ${_t})
      break()
    endif()
  endforeach()
endif()

if (NOT OPENSSL_LIBRARIES)
  if (DEFINED OpenSSL_LIBRARIES)
    set(OPENSSL_LIBRARIES "${OpenSSL_LIBRARIES}")
  else()
    set(OPENSSL_LIBRARIES ${OPENSSL_SSL_LIBRARY} ${OPENSSL_CRYPTO_LIBRARY})
  endif()
endif()

# Ensure OPENSSL_FOUND is set (Conan config-mode sets OpenSSL_FOUND)
if (NOT DEFINED OPENSSL_FOUND AND DEFINED OpenSSL_FOUND)
  set(OPENSSL_FOUND ${OpenSSL_FOUND})
endif()

# --- ZLIB ---
if (NOT ZLIB_INCLUDE_DIR)
  if (DEFINED ZLIB_INCLUDE_DIRS)
    set(ZLIB_INCLUDE_DIR "${ZLIB_INCLUDE_DIRS}")
  elseif (TARGET ZLIB::ZLIB)
    get_target_property(_zlib_inc ZLIB::ZLIB INTERFACE_INCLUDE_DIRECTORIES)
    if (_zlib_inc)
      set(ZLIB_INCLUDE_DIR "${_zlib_inc}")
    endif()
  endif()
endif()
if (NOT ZLIB_LIBRARIES AND TARGET ZLIB::ZLIB)
  set(ZLIB_LIBRARIES ZLIB::ZLIB)
endif()

option(TD_ANDROID_JSON "Use \"ON\" to build JSON interface.")
option(TD_ANDROID_JSON_JAVA "Use \"ON\" to build Java wrapper for JSON API.")
option(TD_PACK_LTO "Enable LTO optimization" ON)

if (TD_ANDROID_JSON)
  if (TD_PACK_LTO)
    if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
      string(APPEND CMAKE_CXX_FLAGS_RELWITHDEBINFO " -flto -Os")
    elseif (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
      string(APPEND CMAKE_CXX_FLAGS_RELWITHDEBINFO " -flto=thin -Oz")
    endif()
  endif()
  add_subdirectory(${TD_DIR} td)
  return()
endif()

set(TD_JNI_PACKAGE_NAME "org/drinkless/tdlib" CACHE STRING "JNI package name (e.g. io/xbot/tdlib)")

if (TD_ANDROID_JSON_JAVA)
  set(TD_ENABLE_JNI ON CACHE BOOL "Enable JNI-compatible TDLib API" FORCE)
else()
  option(TD_ENABLE_JNI "Enable JNI-compatible TDLib API" ON)
endif()

if (CMAKE_CROSSCOMPILING)
  set(CMAKE_MODULE_PATH "${TD_DIR}/CMake")

  include(TdSetUpCompiler)
  td_set_up_compiler()
  if (TD_PACK_LTO)
    if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
      string(APPEND CMAKE_CXX_FLAGS_RELWITHDEBINFO " -flto -Os")
    elseif (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
      string(APPEND CMAKE_CXX_FLAGS_RELWITHDEBINFO " -flto=thin -Oz")
    endif()
  endif()

  add_subdirectory(${TD_DIR} td)

  add_library(tdjni SHARED "${TD_DIR}/example/java/td_jni.cpp")
  target_include_directories(tdjni SYSTEM PRIVATE ${JAVA_INCLUDE_PATH} ${JAVA_INCLUDE_PATH2})

  if (TD_ANDROID_JSON_JAVA)
    target_link_libraries(tdjni PRIVATE Td::TdJsonStatic)
    target_compile_definitions(tdjni PRIVATE TD_JSON_JAVA=1)
    set_target_properties(tdjni PROPERTIES OUTPUT_NAME "tdjsonjava")
  else()
    target_link_libraries(tdjni PRIVATE Td::TdStatic)
  endif()
  target_compile_definitions(tdjni PRIVATE PACKAGE_NAME="${TD_JNI_PACKAGE_NAME}")

  if (NOT WIN32)
    if (APPLE)
      add_custom_command(TARGET tdjni POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E rename $<TARGET_FILE:tdjni> $<TARGET_FILE:tdjni>.debug
        COMMAND ${CMAKE_STRIP} -S -x $<TARGET_FILE:tdjni>.debug -o $<TARGET_FILE:tdjni>)
    else()
      add_custom_command(TARGET tdjni POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E rename $<TARGET_FILE:tdjni> $<TARGET_FILE:tdjni>.debug
        COMMAND ${CMAKE_STRIP} --strip-debug --strip-unneeded $<TARGET_FILE:tdjni>.debug -o $<TARGET_FILE:tdjni>)
    endif()
  endif()
else()
  if (TD_PACK_LTO)
    if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
      string(APPEND CMAKE_CXX_FLAGS_RELWITHDEBINFO " -flto -Os")
    elseif (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
      string(APPEND CMAKE_CXX_FLAGS_RELWITHDEBINFO " -flto=thin -Oz")
    endif()
  endif()

  add_subdirectory(${TD_DIR} td)

  if (TD_ANDROID_JSON_JAVA)
    return()
  endif()

  set(TD_API_JAVA_PACKAGE "${TD_JNI_PACKAGE_NAME}")
  set(TD_API_JAVA_PATH "${CMAKE_CURRENT_SOURCE_DIR}/${TD_API_JAVA_PACKAGE}/TdApi.java")
  set(TD_API_TLO_PATH "${TD_DIR}/td/generate/auto/tlo/td_api.tlo")
  set(TD_API_TL_PATH "${TD_DIR}/td/generate/scheme/td_api.tl")
  set(JAVADOC_TL_DOCUMENTATION_GENERATOR_PATH "${TD_DIR}/td/generate/JavadocTlDocumentationGenerator.php")
  set(GENERATE_JAVA_CMD td_generate_java_api TdApi ${TD_API_TLO_PATH} ${CMAKE_CURRENT_SOURCE_DIR} ${TD_API_JAVA_PACKAGE})
  if (PHP_EXECUTABLE)
    set(GENERATE_JAVA_CMD ${GENERATE_JAVA_CMD} &&
        ${PHP_EXECUTABLE} ${JAVADOC_TL_DOCUMENTATION_GENERATOR_PATH} ${TD_API_TL_PATH} ${TD_API_JAVA_PATH} androidx.annotation.Nullable @Nullable &&
        ${PHP_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/AddIntDef.php ${TD_API_JAVA_PATH})
  endif()

  file(MAKE_DIRECTORY ${TD_API_JAVA_PACKAGE})
  add_custom_target(tl_generate_java
    COMMAND ${GENERATE_JAVA_CMD}
    COMMENT "Generate Java TL source files"
    DEPENDS td_generate_java_api tl_generate_tlo ${TD_API_TLO_PATH} ${TD_API_TL_PATH}
  )
endif()
