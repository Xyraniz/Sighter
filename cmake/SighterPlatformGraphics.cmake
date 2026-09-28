# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

include_guard(GLOBAL)

get_filename_component(SIGHTER_PLATFORM_GRAPHICS_ROOT
  "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE
)

find_package(SDL3 3.4 REQUIRED CONFIG)
find_path(SIGHTER_EGL_INCLUDE_DIR EGL/egl.h REQUIRED)
find_path(SIGHTER_GLES3_INCLUDE_DIR GLES3/gl3.h REQUIRED)

set(SIGHTER_WINDOW_ICON_PNG
  "${SIGHTER_PLATFORM_GRAPHICS_ROOT}/packaging/icons/hicolor/48x48/apps/space.bigrat.sighter.png"
)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${SIGHTER_WINDOW_ICON_PNG}"
)
file(READ "${SIGHTER_WINDOW_ICON_PNG}" SIGHTER_WINDOW_ICON_HEX HEX)
string(LENGTH "${SIGHTER_WINDOW_ICON_HEX}" SIGHTER_WINDOW_ICON_HEX_LENGTH)
set(SIGHTER_WINDOW_ICON_BYTES "")
set(SIGHTER_WINDOW_ICON_HEX_OFFSET 0)
set(SIGHTER_WINDOW_ICON_COLUMN 0)
while(SIGHTER_WINDOW_ICON_HEX_OFFSET LESS SIGHTER_WINDOW_ICON_HEX_LENGTH)
  string(SUBSTRING "${SIGHTER_WINDOW_ICON_HEX}"
    ${SIGHTER_WINDOW_ICON_HEX_OFFSET} 2 SIGHTER_WINDOW_ICON_BYTE
  )
  string(APPEND SIGHTER_WINDOW_ICON_BYTES
    "0x${SIGHTER_WINDOW_ICON_BYTE}, "
  )
  math(EXPR SIGHTER_WINDOW_ICON_HEX_OFFSET
    "${SIGHTER_WINDOW_ICON_HEX_OFFSET} + 2"
  )
  math(EXPR SIGHTER_WINDOW_ICON_COLUMN
    "${SIGHTER_WINDOW_ICON_COLUMN} + 1"
  )
  if(SIGHTER_WINDOW_ICON_COLUMN EQUAL 12)
    string(APPEND SIGHTER_WINDOW_ICON_BYTES "\n    ")
    set(SIGHTER_WINDOW_ICON_COLUMN 0)
  endif()
endwhile()

set(SIGHTER_PLATFORM_GENERATED_INCLUDE_DIR
  "${CMAKE_CURRENT_BINARY_DIR}/generated"
)
file(MAKE_DIRECTORY
  "${SIGHTER_PLATFORM_GENERATED_INCLUDE_DIR}/sighter/platform"
)
configure_file(
  "${SIGHTER_PLATFORM_GRAPHICS_ROOT}/cmake/templates/sdl_window_icon_data.h.in"
  "${SIGHTER_PLATFORM_GENERATED_INCLUDE_DIR}/sighter/platform/sdl_window_icon_data.h"
  @ONLY
)

set(SIGHTER_ANGLE_HEADERS_INCLUDE_DIR
  "${SIGHTER_PLATFORM_GRAPHICS_ROOT}/third_party/angle_headers/include"
)
if(NOT EXISTS
    "${SIGHTER_ANGLE_HEADERS_INCLUDE_DIR}/EGL/eglext_angle.h")
  message(FATAL_ERROR "pinned ANGLE EGL extension header is unavailable")
endif()
add_library(sighter_angle_headers INTERFACE)
target_include_directories(sighter_angle_headers SYSTEM INTERFACE
  "${SIGHTER_ANGLE_HEADERS_INCLUDE_DIR}"
)
add_library(Sighter::AngleHeaders ALIAS sighter_angle_headers)

add_library(sighter_platform_sdl STATIC
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/platform/sdl_application_metadata.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/platform/sdl_display_refresh_capabilities.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/platform/sdl_event_converter.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/platform/sdl_gamepad_manager.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/platform/sdl_platform_runtime.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/platform/sdl_text_clipboard.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/platform/sdl_window_icon.cc
)
target_include_directories(sighter_platform_sdl PUBLIC
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/include
)
target_include_directories(sighter_platform_sdl PRIVATE
  ${SIGHTER_PLATFORM_GENERATED_INCLUDE_DIR}
)
target_link_libraries(sighter_platform_sdl PUBLIC SDL3::SDL3)
target_compile_features(sighter_platform_sdl PUBLIC cxx_std_17)
target_compile_definitions(sighter_platform_sdl PRIVATE
  SIGHTER_PROJECT_VERSION="${PROJECT_VERSION}"
)
add_library(Sighter::PlatformSdl ALIAS sighter_platform_sdl)

add_library(sighter_graphics_foundation STATIC
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/graphics/graphics_backend.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/graphics/angle_probe.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/graphics/bionic_egl_bridge.cc
)
target_include_directories(sighter_graphics_foundation
  PUBLIC ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/include
  PRIVATE ${SIGHTER_EGL_INCLUDE_DIR}
)
target_link_libraries(sighter_graphics_foundation PRIVATE
  Sighter::AngleHeaders
  ${CMAKE_DL_LIBS}
)
target_compile_features(sighter_graphics_foundation PUBLIC cxx_std_17)
add_library(Sighter::GraphicsFoundation ALIAS sighter_graphics_foundation)

add_library(sighter_gles_text_overlay STATIC
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/graphics/gles_text_overlay_compositor.cc
)
target_include_directories(sighter_gles_text_overlay
  PUBLIC ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/include
  PRIVATE ${SIGHTER_GLES3_INCLUDE_DIR}
)
target_link_libraries(sighter_gles_text_overlay PUBLIC SDL3::SDL3)
target_compile_features(sighter_gles_text_overlay PUBLIC cxx_std_17)
sighter_apply_compile_options(sighter_gles_text_overlay)
add_library(Sighter::GlesTextOverlay ALIAS sighter_gles_text_overlay)

add_library(sighter_sdl_vulkan_wsi STATIC
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/graphics/sdl_vulkan_wsi.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/graphics/android_vulkan_wsi_adapter.cc
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/src/graphics/present_mode_policy.cc
)
set_target_properties(sighter_sdl_vulkan_wsi PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)
target_include_directories(sighter_sdl_vulkan_wsi PUBLIC
  ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/include
)
target_link_libraries(sighter_sdl_vulkan_wsi PUBLIC SDL3::SDL3)
target_link_libraries(sighter_sdl_vulkan_wsi PUBLIC Vulkan::Headers)
target_compile_features(sighter_sdl_vulkan_wsi PUBLIC cxx_std_17)
add_library(Sighter::SdlVulkanWsi ALIAS sighter_sdl_vulkan_wsi)

if(BUILD_TESTING AND TARGET GTest::gtest_main)
  add_executable(gles_text_overlay_compositor_test
    ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/tests/gles_text_overlay_compositor_test.cc
  )
  target_include_directories(gles_text_overlay_compositor_test PRIVATE
    ${SIGHTER_GLES3_INCLUDE_DIR}
  )
  target_link_libraries(gles_text_overlay_compositor_test PRIVATE
    Sighter::GlesTextOverlay
    GTest::gtest_main
  )
  add_executable(bionic_egl_bridge_test
    ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/tests/bionic_egl_bridge_test.cc
  )
  target_link_libraries(bionic_egl_bridge_test PRIVATE
    Sighter::GraphicsFoundation
    GTest::gtest_main
  )
  add_dependencies(bionic_egl_bridge_test stub_egl)

  add_executable(platform_graphics_foundation_test
    ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/tests/platform_graphics_foundation_test.cc
  )
  add_executable(display_refresh_capabilities_test
    ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/tests/display_refresh_capabilities_test.cc
  )
  add_executable(present_mode_policy_test
    ${SIGHTER_PLATFORM_GRAPHICS_ROOT}/tests/present_mode_policy_test.cc
  )
  target_link_libraries(present_mode_policy_test PRIVATE
    Sighter::SdlVulkanWsi
    GTest::gtest_main
  )
  target_link_libraries(display_refresh_capabilities_test PRIVATE
    Sighter::PlatformSdl
    GTest::gtest_main
  )
  target_link_libraries(platform_graphics_foundation_test PRIVATE
    Sighter::PlatformSdl
    Sighter::GraphicsFoundation
    Sighter::SdlVulkanWsi
    GTest::gtest_main
  )
  include(GoogleTest)
  gtest_discover_tests(gles_text_overlay_compositor_test)
  gtest_discover_tests(bionic_egl_bridge_test)
  gtest_discover_tests(platform_graphics_foundation_test)
  gtest_discover_tests(display_refresh_capabilities_test)
  gtest_discover_tests(present_mode_policy_test)
endif()
