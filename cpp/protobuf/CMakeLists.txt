cmake_minimum_required(VERSION 3.16)
project(bench_protobuf_cpp CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
# Documented release flags only: no -march=native, no LTO.
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG")

# libprotobuf 36.2 (+ abseil, utf8_range) installed under CMAKE_PREFIX_PATH
# (/usr/local in the Docker image; build.sh passes $PROTOBUF_PREFIX).
find_package(protobuf CONFIG REQUIRED)
if(NOT TARGET absl::strings)
  find_package(absl CONFIG REQUIRED)
endif()
if(NOT TARGET utf8_range)
  find_package(utf8_range CONFIG REQUIRED)
endif()
message(STATUS "protobuf ${protobuf_VERSION} from ${protobuf_DIR}")
file(WRITE "${CMAKE_BINARY_DIR}/version.txt" "${protobuf_VERSION}\n")

add_executable(bench bench.cpp gen/bench.pb.cc)
target_include_directories(bench PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/gen)
set_source_files_properties(bench.cpp PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra")
# Full runtime (not lite): the JSON util needs descriptors/reflection.
target_link_libraries(bench PRIVATE protobuf::libprotobuf)
