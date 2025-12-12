cmake_minimum_required(VERSION 3.15)
project(TdBuild LANGUAGES C CXX)

set(TD_DIR ${CMAKE_CURRENT_SOURCE_DIR}/td)

find_package(OpenSSL REQUIRED)
find_package(ZLIB REQUIRED)

set(OPENSSL_CRYPTO_LIBRARY OpenSSL::Crypto CACHE STRING "" FORCE)
set(OPENSSL_SSL_LIBRARY OpenSSL::SSL CACHE STRING "" FORCE)

add_subdirectory(${TD_DIR})
