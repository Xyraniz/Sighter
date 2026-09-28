# Copyright 2026 Sighter Project Authors
# Licensed under the Apache License, Version 2.0.

include_guard(GLOBAL)

get_filename_component(SIGHTER_ELF_COMPAT_ROOT
  "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE
)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBELF REQUIRED IMPORTED_TARGET libelf)
find_package(nlohmann_json CONFIG REQUIRED)

add_library(sighter_compat STATIC
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_atfork_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_dns_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_host_libc_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_large_file_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_prctl_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_rwlock_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_signal_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_socket_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_semaphore_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_pthread_create_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_pthread_key_runtime.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/bionic_sysconf.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/elf_build_id.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/build_profile.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/payload_compatibility.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/host_allocator_bridge.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/host_abi_experiment.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/host_abi_profile.cc
  ${SIGHTER_ELF_COMPAT_ROOT}/src/compat/host_abi_profile_loader.cc
)
add_library(Sighter::Compat ALIAS sighter_compat)
target_include_directories(sighter_compat PUBLIC
  ${SIGHTER_ELF_COMPAT_ROOT}/include
)
target_compile_definitions(sighter_compat PRIVATE
  "SIGHTER_INSTALL_LIBDIR=\"${CMAKE_INSTALL_LIBDIR}\""
)
target_link_libraries(sighter_compat PUBLIC
  PkgConfig::LIBELF
  nlohmann_json::nlohmann_json
  Threads::Threads
)
target_link_libraries(sighter_compat PRIVATE OpenSSL::Crypto)
target_compile_features(sighter_compat PUBLIC cxx_std_17)

if(COMMAND sighter_apply_compile_options)
  sighter_apply_compile_options(sighter_compat)
endif()
