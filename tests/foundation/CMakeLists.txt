# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

cmake_minimum_required(VERSION 3.20)
project(SighterPlatformGraphicsFoundation LANGUAGES CXX)

# Standalone compile smoke for the additive foundation targets. The main
# project can include the same module after its dependency declarations.
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
include(${CMAKE_CURRENT_LIST_DIR}/../../cmake/SighterPlatformGraphics.cmake)
