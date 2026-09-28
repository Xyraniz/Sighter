# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

cmake_minimum_required(VERSION 3.20)
project(SighterAudioFoundation LANGUAGES CXX)

include(CTest)
find_package(GTest CONFIG QUIET)
if(NOT TARGET GTest::gtest_main)
  include(FetchContent)
  FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG v1.14.0
  )
  set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(googletest)
endif()

include(${CMAKE_CURRENT_LIST_DIR}/../../cmake/SighterAudio.cmake)
