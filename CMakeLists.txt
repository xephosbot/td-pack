cmake_minimum_required(VERSION 3.15)
project(TdBuild LANGUAGES C CXX)

find_package(OpenSSL REQUIRED)
find_package(ZLIB REQUIRED)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(TD_DIR ${CMAKE_CURRENT_SOURCE_DIR}/td)

add_subdirectory(${TD_DIR})
