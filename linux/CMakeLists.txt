cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "xue_hua_navite_background_downloader")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "xue_hua_navite_background_downloader_plugin")

find_package(PkgConfig REQUIRED)
pkg_check_modules(CURL QUIET IMPORTED_TARGET libcurl)

list(APPEND PLUGIN_SOURCES
  "xue_hua_navite_background_downloader_plugin.cc"
)

add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

if (CURL_FOUND)
  target_compile_definitions(${PLUGIN_NAME} PRIVATE HAVE_LIBCURL=1)
  target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::CURL)
endif()

set(xue_hua_navite_background_downloader_bundled_libraries
  ""
  PARENT_SCOPE
)

if (${include_${PROJECT_NAME}_tests})
if(${CMAKE_VERSION} VERSION_LESS "3.11.0")
message("Unit tests require CMake 3.11.0 or later")
else()
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/release-1.11.0.zip
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)

FetchContent_MakeAvailable(googletest)

add_executable(${TEST_RUNNER}
  test/xue_hua_navite_background_downloader_plugin_test.cc
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${TEST_RUNNER})
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${TEST_RUNNER} PRIVATE flutter)
target_link_libraries(${TEST_RUNNER} PRIVATE PkgConfig::GTK)
if (CURL_FOUND)
  target_compile_definitions(${TEST_RUNNER} PRIVATE HAVE_LIBCURL=1)
  target_link_libraries(${TEST_RUNNER} PRIVATE PkgConfig::CURL)
endif()
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)

include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})

endif()
endif()
