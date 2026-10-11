cmake_minimum_required(VERSION 3.16)
project(bench_protobuf_c C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
# Documented release flags only: no -march=native, no LTO.
set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG")

find_package(PkgConfig REQUIRED)
pkg_check_modules(PROTOBUF_C REQUIRED IMPORTED_TARGET libprotobuf-c)

add_executable(bench bench.c gen/bench.pb-c.c)
target_include_directories(bench PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/gen)
target_compile_options(bench PRIVATE -Wall -Wextra)
target_link_libraries(bench PRIVATE PkgConfig::PROTOBUF_C)
