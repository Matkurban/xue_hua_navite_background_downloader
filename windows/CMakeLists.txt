cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "xue_hua_navite_background_downloader")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "xue_hua_navite_background_downloader_plugin")

list(APPEND PLUGIN_SOURCES
  "xue_hua_navite_background_downloader_plugin.cpp"
  "xue_hua_navite_background_downloader_plugin.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/xue_hua_navite_background_downloader/xue_hua_navite_background_downloader_plugin_c_api.h"
  "xue_hua_navite_background_downloader_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  winhttp
  bcrypt
  shell32
  ole32
)

set(xue_hua_navite_background_downloader_bundled_libraries
  ""
  PARENT_SCOPE
)

# Native googletest target disabled: long plugin name makes MSBuild .tlog paths
# exceed Windows MAX_PATH under typical Flutter example/build trees. Integration
# tests cover the Windows download API. googletest pin kept for easy re-enable.
#
# Keep this condition as if(FALSE) until those paths fit. To re-enable, use:
#   if(${include_${PROJECT_NAME}_tests})
# Do not write `if(FALSE AND ${include_${PROJECT_NAME}_tests})`. When that
# variable is unset it expands to nothing and CMake errors on `if(FALSE AND)`.
if(FALSE)
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

include(FetchContent)
# googletest 1.11.0 is incompatible with CMake 4.x (requires <3.5).
# Pin a newer release and allow policy fallback for transitive deps.
set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/refs/tags/v1.15.2.zip
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
FetchContent_MakeAvailable(googletest)

add_executable(${TEST_RUNNER}
  test/xue_hua_navite_background_downloader_plugin_test.cpp
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${TEST_RUNNER})
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${TEST_RUNNER} PRIVATE
  flutter_wrapper_plugin
  winhttp
  bcrypt
  shell32
  ole32
  gtest_main
  gmock
)
add_custom_command(TARGET ${TEST_RUNNER} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
  "${FLUTTER_LIBRARY}" $<TARGET_FILE_DIR:${TEST_RUNNER}>
)

include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})
endif()