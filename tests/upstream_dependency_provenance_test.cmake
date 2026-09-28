# Copyright 2026 Sighter Project Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

if(NOT DEFINED SIGHTER_SOURCE_DIR)
  message(FATAL_ERROR "SIGHTER_SOURCE_DIR is required")
endif()

set(manifest "${SIGHTER_SOURCE_DIR}/config/upstream_dependencies.json")
file(READ "${manifest}" manifest_json)

string(JSON schema_version GET "${manifest_json}" schema_version)
if(NOT schema_version EQUAL 1)
  message(FATAL_ERROR "unsupported upstream dependency manifest schema")
endif()

function(read_dependency_field output dependency field)
  string(JSON value GET "${manifest_json}" dependencies "${dependency}" "${field}")
  set("${output}" "${value}" PARENT_SCOPE)
endfunction()

function(require_git_object_id field_name value)
  string(LENGTH "${value}" value_length)
  if(NOT value_length EQUAL 40 OR NOT value MATCHES "^[0-9a-f]+$")
    message(FATAL_ERROR "${field_name} must be a full lowercase Git object ID")
  endif()
endfunction()

function(require_sha256 field_name value)
  string(LENGTH "${value}" value_length)
  if(NOT value_length EQUAL 64 OR NOT value MATCHES "^[0-9a-f]+$")
    message(FATAL_ERROR "${field_name} must be a lowercase SHA-256 digest")
  endif()
endfunction()

function(read_index_entry output dependency_path)
  execute_process(
    COMMAND git -C "${SIGHTER_SOURCE_DIR}" write-tree
    RESULT_VARIABLE tree_result
    OUTPUT_VARIABLE index_tree
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  if(NOT tree_result EQUAL 0 OR index_tree STREQUAL "")
    message(FATAL_ERROR "cannot materialise the Git index tree")
  endif()
  execute_process(
    COMMAND git -C "${SIGHTER_SOURCE_DIR}" ls-tree "${index_tree}" --
            "${dependency_path}"
    RESULT_VARIABLE result
    OUTPUT_VARIABLE entry
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  if(NOT result EQUAL 0 OR entry STREQUAL "")
    message(FATAL_ERROR "cannot read Git entry for ${dependency_path}")
  endif()
  set("${output}" "${entry}" PARENT_SCOPE)
endfunction()

read_dependency_field(libjnivm_mode libjnivm mode)
read_dependency_field(libjnivm_url libjnivm url)
read_dependency_field(libjnivm_commit libjnivm commit)
read_dependency_field(libjnivm_tree libjnivm tree)
read_dependency_field(jni_headers_mode OpenJDK-JNI-Headers mode)
read_dependency_field(jni_headers_url OpenJDK-JNI-Headers url)
read_dependency_field(jni_headers_tag OpenJDK-JNI-Headers tag)
read_dependency_field(jni_headers_commit OpenJDK-JNI-Headers upstream_commit)
foreach(jni_file IN ITEMS
    third_party/jni/include/jni.h
    third_party/jni/include/jni_md.h
    third_party/jni/LICENSE
    third_party/jni/ASSEMBLY_EXCEPTION)
  string(JSON jni_sha256_${jni_file} GET "${manifest_json}" dependencies
         OpenJDK-JNI-Headers files "${jni_file}" sha256)
endforeach()
read_dependency_field(linker_mode mcpelauncher-linker mode)
read_dependency_field(linker_upstream_commit mcpelauncher-linker upstream_commit)
read_dependency_field(linker_tree mcpelauncher-linker vendor_tree)
read_dependency_field(linker_patch mcpelauncher-linker patch)
string(JSON linker_bionic_url GET "${manifest_json}" dependencies
       mcpelauncher-linker nested_sources android_bionic url)
string(JSON linker_bionic_commit GET "${manifest_json}" dependencies
       mcpelauncher-linker nested_sources android_bionic upstream_commit)
string(JSON linker_bionic_tree GET "${manifest_json}" dependencies
       mcpelauncher-linker nested_sources android_bionic vendor_tree)
string(JSON linker_core_mode GET "${manifest_json}" dependencies
       mcpelauncher-linker nested_sources android_core mode)
string(JSON linker_core_url GET "${manifest_json}" dependencies
       mcpelauncher-linker nested_sources android_core url)
string(JSON linker_core_commit GET "${manifest_json}" dependencies
       mcpelauncher-linker nested_sources android_core upstream_commit)
string(JSON linker_core_upstream_tree GET "${manifest_json}" dependencies
       mcpelauncher-linker nested_sources android_core upstream_tree)
string(JSON linker_core_vendor_tree GET "${manifest_json}" dependencies
       mcpelauncher-linker nested_sources android_core vendor_tree)
foreach(core_subtree IN ITEMS base libcutils liblog libziparchive)
  string(JSON linker_core_${core_subtree}_tree GET "${manifest_json}"
         dependencies mcpelauncher-linker nested_sources android_core
         vendored_subtrees "${core_subtree}")
endforeach()
read_dependency_field(vulkan_mode Vulkan-Headers mode)
read_dependency_field(vulkan_url Vulkan-Headers url)
read_dependency_field(vulkan_commit Vulkan-Headers commit)
read_dependency_field(angle_mode ANGLE-Headers mode)
read_dependency_field(angle_url ANGLE-Headers url)
read_dependency_field(angle_commit ANGLE-Headers upstream_commit)
read_dependency_field(angle_tree ANGLE-Headers upstream_tree)
string(JSON angle_header_blob GET "${manifest_json}" dependencies
       ANGLE-Headers files include/EGL/eglext_angle.h git_blob)
string(JSON angle_header_sha256 GET "${manifest_json}" dependencies
       ANGLE-Headers files include/EGL/eglext_angle.h sha256)
string(JSON angle_license_blob GET "${manifest_json}" dependencies
       ANGLE-Headers files LICENSE git_blob)
string(JSON angle_license_sha256 GET "${manifest_json}" dependencies
       ANGLE-Headers files LICENSE sha256)

require_git_object_id("libjnivm commit" "${libjnivm_commit}")
require_git_object_id("libjnivm tree" "${libjnivm_tree}")
require_git_object_id("OpenJDK JNI headers upstream commit"
                      "${jni_headers_commit}")
foreach(jni_file IN ITEMS
    third_party/jni/include/jni.h
    third_party/jni/include/jni_md.h
    third_party/jni/LICENSE
    third_party/jni/ASSEMBLY_EXCEPTION)
  require_sha256("OpenJDK JNI ${jni_file}"
                 "${jni_sha256_${jni_file}}")
endforeach()
require_git_object_id("mcpelauncher-linker upstream commit"
                      "${linker_upstream_commit}")
require_git_object_id("mcpelauncher-linker vendor tree" "${linker_tree}")
require_git_object_id("android_bionic upstream commit"
                      "${linker_bionic_commit}")
require_git_object_id("android_bionic vendor tree" "${linker_bionic_tree}")
require_git_object_id("android_core upstream commit" "${linker_core_commit}")
require_git_object_id("android_core upstream tree"
                      "${linker_core_upstream_tree}")
require_git_object_id("android_core vendor tree"
                      "${linker_core_vendor_tree}")
foreach(core_subtree IN ITEMS base libcutils liblog libziparchive)
  require_git_object_id(
    "android_core ${core_subtree} tree"
    "${linker_core_${core_subtree}_tree}")
endforeach()
require_git_object_id("Vulkan-Headers commit" "${vulkan_commit}")
require_git_object_id("ANGLE-Headers upstream commit" "${angle_commit}")
require_git_object_id("ANGLE-Headers upstream tree" "${angle_tree}")
require_git_object_id("ANGLE header blob" "${angle_header_blob}")
require_git_object_id("ANGLE license blob" "${angle_license_blob}")

if(linker_bionic_url STREQUAL "")
  message(FATAL_ERROR "android_bionic upstream URL must be recorded")
endif()
if(NOT linker_core_mode STREQUAL "vendored-unmodified-subtree-snapshot")
  message(FATAL_ERROR "android_core ownership mode differs")
endif()
if(NOT linker_core_url STREQUAL
   "https://github.com/minecraft-linux/android_core")
  message(FATAL_ERROR "android_core canonical upstream URL differs")
endif()

if(NOT libjnivm_mode STREQUAL "git-submodule" OR
   NOT vulkan_mode STREQUAL "git-submodule" OR
   NOT jni_headers_mode STREQUAL "vendored-unmodified-header-snapshot" OR
   NOT linker_mode STREQUAL "vendored-patched-snapshot" OR
   NOT angle_mode STREQUAL "vendored-unmodified-header-snapshot")
  message(FATAL_ERROR "dependency ownership modes do not match the supported layout")
endif()

if(NOT jni_headers_url STREQUAL "https://github.com/openjdk/jdk17u.git" OR
   NOT jni_headers_tag STREQUAL "jdk-17.0.20+8")
  message(FATAL_ERROR "standalone JNI header provenance differs")
endif()

foreach(jni_file IN ITEMS
    third_party/jni/include/jni.h
    third_party/jni/include/jni_md.h
    third_party/jni/LICENSE
    third_party/jni/ASSEMBLY_EXCEPTION)
  set(jni_path "${SIGHTER_SOURCE_DIR}/${jni_file}")
  if(NOT EXISTS "${jni_path}")
    message(FATAL_ERROR "standalone JNI snapshot is missing ${jni_file}")
  endif()
  file(SHA256 "${jni_path}" checkout_jni_sha256)
  if(NOT checkout_jni_sha256 STREQUAL "${jni_sha256_${jni_file}}")
    message(FATAL_ERROR "standalone JNI snapshot differs: ${jni_file}")
  endif()
endforeach()

if(NOT angle_url STREQUAL
   "https://chromium.googlesource.com/angle/angle.git")
  message(FATAL_ERROR "ANGLE-Headers canonical upstream URL differs")
endif()

set(angle_root "${SIGHTER_SOURCE_DIR}/third_party/angle_headers")
set(angle_header "${angle_root}/include/EGL/eglext_angle.h")
set(angle_license "${angle_root}/LICENSE")
if(NOT EXISTS "${angle_header}" OR NOT EXISTS "${angle_license}")
  message(FATAL_ERROR "vendored ANGLE header snapshot is incomplete")
endif()
file(SHA256 "${angle_header}" checkout_angle_header_sha256)
file(SHA256 "${angle_license}" checkout_angle_license_sha256)
if(NOT checkout_angle_header_sha256 STREQUAL angle_header_sha256 OR
   NOT checkout_angle_license_sha256 STREQUAL angle_license_sha256)
  message(FATAL_ERROR "vendored ANGLE header snapshot differs from provenance")
endif()
execute_process(
  COMMAND git hash-object "${angle_header}"
  RESULT_VARIABLE angle_header_blob_result
  OUTPUT_VARIABLE checkout_angle_header_blob
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
execute_process(
  COMMAND git hash-object "${angle_license}"
  RESULT_VARIABLE angle_license_blob_result
  OUTPUT_VARIABLE checkout_angle_license_blob
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT angle_header_blob_result EQUAL 0 OR
   NOT checkout_angle_header_blob STREQUAL angle_header_blob OR
   NOT angle_license_blob_result EQUAL 0 OR
   NOT checkout_angle_license_blob STREQUAL angle_license_blob)
  message(FATAL_ERROR "vendored ANGLE Git blobs differ from provenance")
endif()
if(EXISTS "${angle_root}/.git")
  message(FATAL_ERROR "vendored ANGLE header snapshot contains Git metadata")
endif()

read_index_entry(libjnivm_entry third_party/libjnivm)
if(NOT libjnivm_entry MATCHES "^160000 commit ${libjnivm_commit}")
  message(FATAL_ERROR "libjnivm is not pinned as the declared Git submodule")
endif()

read_index_entry(vulkan_entry third_party/Vulkan-Headers)
if(NOT vulkan_entry MATCHES "^160000 commit ${vulkan_commit}")
  message(FATAL_ERROR "Vulkan-Headers is not pinned as the declared Git submodule")
endif()

read_index_entry(linker_entry third_party/mcpelauncher-linker)
if(NOT linker_entry MATCHES "^040000 tree ${linker_tree}")
  message(FATAL_ERROR "mcpelauncher-linker vendored tree differs from the lock manifest")
endif()

read_index_entry(linker_bionic_entry third_party/mcpelauncher-linker/bionic)
if(NOT linker_bionic_entry MATCHES "^040000 tree ${linker_bionic_tree}")
  message(FATAL_ERROR "vendored android_bionic tree differs from the lock manifest")
endif()

read_index_entry(linker_core_entry third_party/mcpelauncher-linker/core)
if(NOT linker_core_entry MATCHES
   "^040000 tree ${linker_core_vendor_tree}")
  message(FATAL_ERROR "vendored android_core subset differs from the lock manifest")
endif()
foreach(core_subtree IN ITEMS base libcutils liblog libziparchive)
  read_index_entry(
    linker_core_${core_subtree}_entry
    third_party/mcpelauncher-linker/core/${core_subtree})
  if(NOT linker_core_${core_subtree}_entry MATCHES
     "^040000 tree ${linker_core_${core_subtree}_tree}")
    message(FATAL_ERROR
            "vendored android_core ${core_subtree} tree differs from provenance")
  endif()
endforeach()

execute_process(
  COMMAND git -C "${SIGHTER_SOURCE_DIR}" config -f .gitmodules --get
          submodule.third_party/libjnivm.url
  RESULT_VARIABLE libjnivm_url_result
  OUTPUT_VARIABLE configured_libjnivm_url
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT libjnivm_url_result EQUAL 0 OR
   NOT configured_libjnivm_url STREQUAL libjnivm_url)
  message(FATAL_ERROR "libjnivm submodule URL differs from the lock manifest")
endif()

execute_process(
  COMMAND git -C "${SIGHTER_SOURCE_DIR}" config -f .gitmodules --get
          submodule.third_party/Vulkan-Headers.url
  RESULT_VARIABLE vulkan_url_result
  OUTPUT_VARIABLE configured_vulkan_url
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT vulkan_url_result EQUAL 0 OR
   NOT configured_vulkan_url STREQUAL vulkan_url)
  message(FATAL_ERROR "Vulkan-Headers submodule URL differs from the lock manifest")
endif()

execute_process(
  COMMAND git -C "${SIGHTER_SOURCE_DIR}" config -f .gitmodules --get
          submodule.third_party/mcpelauncher-linker.url
  RESULT_VARIABLE linker_submodule_result
  OUTPUT_QUIET
  ERROR_QUIET
)
if(linker_submodule_result EQUAL 0)
  message(FATAL_ERROR "vendored mcpelauncher-linker must not masquerade as a submodule")
endif()

if(EXISTS "${SIGHTER_SOURCE_DIR}/third_party/mcpelauncher-linker/.git")
  message(FATAL_ERROR "vendored mcpelauncher-linker contains stale Git metadata")
endif()
if(EXISTS "${SIGHTER_SOURCE_DIR}/third_party/mcpelauncher-linker/core/.git")
  message(FATAL_ERROR "vendored android_core subset contains stale Git metadata")
endif()
execute_process(
  COMMAND git config -f
          "${SIGHTER_SOURCE_DIR}/third_party/mcpelauncher-linker/.gitmodules"
          --get submodule.core.url
  RESULT_VARIABLE linker_core_url_result
  OUTPUT_VARIABLE configured_linker_core_url
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT linker_core_url_result EQUAL 0 OR
   NOT configured_linker_core_url STREQUAL linker_core_url)
  message(FATAL_ERROR "android_core URL differs from linker upstream metadata")
endif()
if(NOT EXISTS "${SIGHTER_SOURCE_DIR}/${linker_patch}")
  message(FATAL_ERROR "declared mcpelauncher-linker patch is missing")
endif()
execute_process(
  COMMAND git -C "${SIGHTER_SOURCE_DIR}" apply --reverse --check
          --unidiff-zero
          --directory=third_party/mcpelauncher-linker
          "${SIGHTER_SOURCE_DIR}/${linker_patch}"
  RESULT_VARIABLE linker_patch_result
  OUTPUT_QUIET
  ERROR_QUIET
)
if(NOT linker_patch_result EQUAL 0)
  message(FATAL_ERROR "vendored mcpelauncher-linker does not contain the declared patch")
endif()

execute_process(
  COMMAND git -C "${SIGHTER_SOURCE_DIR}/third_party/libjnivm" rev-parse HEAD
  RESULT_VARIABLE checkout_result
  OUTPUT_VARIABLE checkout_commit
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT checkout_result EQUAL 0 OR NOT checkout_commit STREQUAL libjnivm_commit)
  message(FATAL_ERROR "libjnivm checkout is unavailable or not at the pinned commit")
endif()

execute_process(
  COMMAND git -C "${SIGHTER_SOURCE_DIR}/third_party/libjnivm" rev-parse
          "HEAD^{tree}"
  RESULT_VARIABLE libjnivm_tree_result
  OUTPUT_VARIABLE checkout_libjnivm_tree
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT libjnivm_tree_result EQUAL 0 OR
   NOT checkout_libjnivm_tree STREQUAL libjnivm_tree)
  message(FATAL_ERROR "libjnivm checkout tree differs from the lock manifest")
endif()

execute_process(
  COMMAND git -C "${SIGHTER_SOURCE_DIR}/third_party/Vulkan-Headers"
          rev-parse HEAD
  RESULT_VARIABLE vulkan_checkout_result
  OUTPUT_VARIABLE vulkan_checkout_commit
  OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT vulkan_checkout_result EQUAL 0 OR
   NOT vulkan_checkout_commit STREQUAL vulkan_commit)
  message(FATAL_ERROR
          "Vulkan-Headers checkout is unavailable or not at the pinned commit")
endif()

message(STATUS "upstream dependency provenance is pinned and internally consistent")
