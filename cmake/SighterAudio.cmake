# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

include_guard(GLOBAL)

get_filename_component(SIGHTER_AUDIO_ROOT
  "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE
)

# SDL 3.4 provides the callback needed for OpenSL buffer completion.
find_package(SDL3 3.4 REQUIRED CONFIG)
find_package(Threads REQUIRED)

add_library(sighter_audio_core STATIC
  ${SIGHTER_AUDIO_ROOT}/src/audio/audio_sink.cc
)
target_include_directories(sighter_audio_core PUBLIC
  ${SIGHTER_AUDIO_ROOT}/include
)
target_compile_features(sighter_audio_core PUBLIC cxx_std_17)
set_target_properties(sighter_audio_core PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)
add_library(Sighter::AudioCore ALIAS sighter_audio_core)

add_library(sighter_audio_sdl SHARED
  ${SIGHTER_AUDIO_ROOT}/src/audio/sdl_audio_capture.cc
  ${SIGHTER_AUDIO_ROOT}/src/audio/sdl_audio_sink.cc
)
target_include_directories(sighter_audio_sdl PUBLIC
  ${SIGHTER_AUDIO_ROOT}/include
)
target_link_libraries(sighter_audio_sdl PUBLIC
  Sighter::AudioCore
  SDL3::SDL3
)
target_compile_features(sighter_audio_sdl PUBLIC cxx_std_17)
set_target_properties(sighter_audio_sdl PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  BUILD_RPATH_USE_ORIGIN TRUE
  BUILD_RPATH "\$ORIGIN"
  INSTALL_RPATH "\$ORIGIN"
)
add_library(Sighter::AudioSdl ALIAS sighter_audio_sdl)

add_library(sighter_audio_fmod_java_runtime STATIC
  ${SIGHTER_AUDIO_ROOT}/src/audio/fmod_java_audio_runtime.cc
)
target_include_directories(sighter_audio_fmod_java_runtime PUBLIC
  ${SIGHTER_AUDIO_ROOT}/include
)
target_link_libraries(sighter_audio_fmod_java_runtime PUBLIC
  Sighter::AudioSdl
  Threads::Threads
)
target_compile_features(sighter_audio_fmod_java_runtime PUBLIC cxx_std_17)
set_target_properties(sighter_audio_fmod_java_runtime PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)
add_library(Sighter::FmodJavaAudioRuntime ALIAS
  sighter_audio_fmod_java_runtime
)

add_library(sighter_fmod_jni_audio_bridge STATIC
  ${SIGHTER_AUDIO_ROOT}/src/audio/fmod_jni_audio_bridge.cc
  ${SIGHTER_AUDIO_ROOT}/src/audio/webrtc_jni_audio_bridge.cc
)
target_include_directories(sighter_fmod_jni_audio_bridge PUBLIC
  ${SIGHTER_AUDIO_ROOT}/include
)
target_link_libraries(sighter_fmod_jni_audio_bridge PUBLIC
  Sighter::FmodJavaAudioRuntime
  Sighter::LegacyJni
)
target_compile_features(sighter_fmod_jni_audio_bridge PUBLIC cxx_std_17)
set_target_properties(sighter_fmod_jni_audio_bridge PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)
add_library(Sighter::FmodJniAudioBridge ALIAS
  sighter_fmod_jni_audio_bridge
)

add_library(sighter_audio_opensl_adapter STATIC
  ${SIGHTER_AUDIO_ROOT}/src/audio/opensl_simple_buffer_queue.cc
)
target_include_directories(sighter_audio_opensl_adapter PUBLIC
  ${SIGHTER_AUDIO_ROOT}/include
)
target_link_libraries(sighter_audio_opensl_adapter PUBLIC
  Sighter::AudioCore
  Threads::Threads
)
target_compile_features(sighter_audio_opensl_adapter PUBLIC cxx_std_17)
set_target_properties(sighter_audio_opensl_adapter PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)
add_library(Sighter::AudioOpenSlAdapter ALIAS
  sighter_audio_opensl_adapter
)

add_library(sighter_audio INTERFACE)
target_link_libraries(sighter_audio INTERFACE
  Sighter::AudioSdl
  Sighter::AudioOpenSlAdapter
)
add_library(Sighter::Audio ALIAS sighter_audio)

# Desktop builds use opensl_abi.h when NDK headers are unavailable.
find_path(SIGHTER_OPENSL_CORE_INCLUDE_DIR SLES/OpenSLES.h)
find_path(SIGHTER_OPENSL_ANDROID_INCLUDE_DIR SLES/OpenSLES_Android.h)
if(SIGHTER_OPENSL_CORE_INCLUDE_DIR AND SIGHTER_OPENSL_ANDROID_INCLUDE_DIR)
  target_include_directories(sighter_audio_opensl_adapter PUBLIC
    ${SIGHTER_OPENSL_CORE_INCLUDE_DIR}
    ${SIGHTER_OPENSL_ANDROID_INCLUDE_DIR}
  )
  target_compile_definitions(sighter_audio_opensl_adapter PUBLIC
    SIGHTER_USE_SYSTEM_OPENSL_HEADERS=1
  )
  message(STATUS "Sighter audio: using system Android OpenSL headers")
else()
  message(STATUS
    "Sighter audio: Android OpenSL headers unavailable; using minimal queue ABI boundary"
  )
endif()

add_library(sighter_opensles SHARED
  ${SIGHTER_AUDIO_ROOT}/src/audio/opensl_playback_runtime.cc
)
target_include_directories(sighter_opensles PUBLIC
  ${SIGHTER_AUDIO_ROOT}/include
)
target_link_libraries(sighter_opensles PRIVATE
  Sighter::Audio
)
target_compile_features(sighter_opensles PRIVATE cxx_std_17)
set_target_properties(sighter_opensles PROPERTIES
  OUTPUT_NAME OpenSLES
  PREFIX "lib"
  SUFFIX ".so"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES
  BUILD_RPATH_USE_ORIGIN TRUE
  BUILD_RPATH "\$ORIGIN"
  INSTALL_RPATH "\$ORIGIN"
)
target_link_options(sighter_opensles PRIVATE
  "-Wl,-soname,libOpenSLES.so"
  "-Wl,--exclude-libs,ALL"
)

if(BUILD_TESTING AND TARGET GTest::gtest_main)
  add_executable(audio_foundation_test
    ${SIGHTER_AUDIO_ROOT}/tests/audio_foundation_test.cc
    ${SIGHTER_AUDIO_ROOT}/stubs/libopensl_stub.cc
  )
  target_link_libraries(audio_foundation_test PRIVATE
    Sighter::Audio
    GTest::gtest_main
  )
  target_compile_features(audio_foundation_test PRIVATE cxx_std_17)
  include(GoogleTest)
  gtest_discover_tests(audio_foundation_test
    PROPERTIES ENVIRONMENT "SDL_AUDIODRIVER=dummy"
  )

  add_executable(opensl_playback_runtime_test
    ${SIGHTER_AUDIO_ROOT}/tests/opensl_playback_runtime_test.cc
  )
  target_link_libraries(opensl_playback_runtime_test PRIVATE
    sighter_opensles
    Sighter::AudioSdl
    GTest::gtest_main
  )
  target_compile_features(opensl_playback_runtime_test PRIVATE cxx_std_17)
  gtest_discover_tests(opensl_playback_runtime_test
    PROPERTIES ENVIRONMENT "SDL_AUDIODRIVER=dummy"
  )

  add_executable(fmod_java_audio_runtime_test
    ${SIGHTER_AUDIO_ROOT}/tests/fmod_java_audio_runtime_test.cc
  )
  target_link_libraries(fmod_java_audio_runtime_test PRIVATE
    Sighter::FmodJavaAudioRuntime
    GTest::gtest_main
    Threads::Threads
  )
  target_compile_features(fmod_java_audio_runtime_test PRIVATE cxx_std_17)
  gtest_discover_tests(fmod_java_audio_runtime_test
    PROPERTIES ENVIRONMENT "SDL_AUDIODRIVER=dummy"
  )

  add_executable(fmod_jni_audio_bridge_test
    ${SIGHTER_AUDIO_ROOT}/tests/fmod_jni_audio_bridge_test.cc
  )
  target_link_libraries(fmod_jni_audio_bridge_test PRIVATE
    Sighter::FmodJniAudioBridge
    GTest::gtest_main
  )
  target_compile_features(fmod_jni_audio_bridge_test PRIVATE cxx_std_17)
  gtest_discover_tests(fmod_jni_audio_bridge_test
    PROPERTIES ENVIRONMENT "SDL_AUDIODRIVER=dummy"
  )
endif()
