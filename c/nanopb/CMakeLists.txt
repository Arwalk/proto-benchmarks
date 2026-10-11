cmake_minimum_required(VERSION 3.16)
project(bench_nanopb C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
# Documented release flags only: no -march=native, no LTO.
set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG")

# nanopb runtime sources, downloaded by build.sh into build/nanopb-src
set(NANOPB_SRC "${CMAKE_CURRENT_SOURCE_DIR}/build/nanopb-src" CACHE PATH "nanopb source tree")
if(NOT EXISTS "${NANOPB_SRC}/pb.h")
  message(FATAL_ERROR "nanopb sources not found at ${NANOPB_SRC}; run build.sh")
endif()

add_executable(bench
  bench.c
  gen/bench.pb.c
  ${NANOPB_SRC}/pb_common.c
  ${NANOPB_SRC}/pb_encode.c
  ${NANOPB_SRC}/pb_decode.c)
target_include_directories(bench PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/gen ${NANOPB_SRC})
# PB_ENABLE_MALLOC: dynamic allocation for FT_POINTER fields (see bench.options).
# PB_FIELD_32BIT: 32-bit pb_size_t so byte arrays / repeated fields > 65535 elements fit (large.blob is 64 KiB = 65536 B, one more than the 16-bit pb_size_t can hold).
target_compile_definitions(bench PRIVATE PB_ENABLE_MALLOC=1 PB_FIELD_32BIT=1)
set_source_files_properties(bench.c PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra")
