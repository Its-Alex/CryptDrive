cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "cryptdrive_native")
project(${PROJECT_NAME} LANGUAGES CXX)

set(CRYPTDRIVE_NATIVE_LIBRARY "${CMAKE_CURRENT_SOURCE_DIR}/lib/libcryptdrive.so")
if(NOT EXISTS "${CRYPTDRIVE_NATIVE_LIBRARY}")
  message(FATAL_ERROR "${CRYPTDRIVE_NATIVE_LIBRARY} is missing: run `mise run native:linux` first")
endif()

set(cryptdrive_native_bundled_libraries
  "${CRYPTDRIVE_NATIVE_LIBRARY}"
  PARENT_SCOPE
)
