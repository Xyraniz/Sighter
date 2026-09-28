#include <unistd.h>

#include <array>
#include <charconv>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "update/android_manifest.h"
#include "update/apk_bundle.h"
#include "update/apk_signature.h"
#include "update/apkpure_provider.h"
#include "update/compatibility_catalog.h"
#include "update/host_abi_deriver.h"
#include "update/payload_store.h"
#include "update/update_coordinator.h"
#include "update/zip_archive.h"

#ifndef SIGHTER_DEFAULT_COMPATIBILITY_MANIFEST
#define SIGHTER_DEFAULT_COMPATIBILITY_MANIFEST \
  "config/roblox_compatibility.json"
#endif

#ifndef SIGHTER_DEFAULT_SIGNING_TRUST_MANIFEST
#define SIGHTER_DEFAULT_SIGNING_TRUST_MANIFEST \
  "config/roblox_signing_certificates.json"
#endif

namespace {

std::optional<std::string> Environment(std::string_view name) {
  const char* value = std::getenv(std::string(name).c_str());
  if (value == nullptr || value[0] == '\0') return std::nullopt;
  return value;
}

std::filesystem::path XdgRoot(std::string_view variable,
                              std::string_view fallback_suffix) {
  const auto configured = Environment(variable);
  if (configured.has_value() &&
      std::filesystem::path(*configured).is_absolute()) {
    return *configured;
  }
  return std::filesystem::path(Environment("HOME").value_or("/root")) /
         std::string(fallback_suffix);
}

std::filesystem::path ExecutablePath() {
  std::array<char, 4097> path{};
  const ssize_t size =
      readlink("/proc/self/exe", path.data(), path.size() - 1U);
  if (size <= 0 || static_cast<std::size_t>(size) >= path.size()) return {};
  path[static_cast<std::size_t>(size)] = '\0';
  return path.data();
}

std::filesystem::path InstalledMetadataEntry(std::string_view name,
                                             bool directory_entry) {
  const std::filesystem::path executable = ExecutablePath();
  if (!executable.empty()) {
    const std::filesystem::path directory = executable.parent_path();
    if (directory.filename() == "sighter" &&
        directory.parent_path().filename() == "lib") {
      const std::filesystem::path candidate =
          directory.parent_path().parent_path() / "share/sighter/metadata" /
          std::string(name);
      std::error_code error;
      if (directory_entry ? std::filesystem::is_directory(candidate, error)
                          : std::filesystem::is_regular_file(candidate, error)) {
        return candidate;
      }
    }
  }
  return {};
}

std::filesystem::path InstalledMetadata(std::string_view filename) {
  return InstalledMetadataEntry(filename, false);
}

// A directory of per-Build-ID sidecars wins over the single legacy file.
std::filesystem::path DefaultHostAbiReference() {
  const std::filesystem::path installed_directory =
      InstalledMetadataEntry("host_abi", true);
  if (!installed_directory.empty()) return installed_directory;
  const std::filesystem::path installed_file =
      InstalledMetadata("roblox_host_abi_reference.json");
  if (!installed_file.empty()) return installed_file;
  std::error_code error;
  if (std::filesystem::is_directory("config/host_abi", error)) {
    return "config/host_abi";
  }
  return "config/roblox_host_abi_reference.json";
}

sighter::update::UpdatePaths ResolvePaths() {
  sighter::update::UpdatePaths paths;
  paths.config_file = Environment("SIGHTER_CONFIG_FILE")
                          .value_or((XdgRoot("XDG_CONFIG_HOME", ".config") /
                                     "sighter/config.yaml")
                                        .string());
  paths.data_root =
      Environment("SIGHTER_DATA_ROOT")
          .value_or(
              (XdgRoot("XDG_DATA_HOME", ".local/share") / "sighter").string());
  paths.cache_root =
      Environment("SIGHTER_CACHE_ROOT")
          .value_or(
              (XdgRoot("XDG_CACHE_HOME", ".cache") / "sighter").string());
  paths.state_root =
      Environment("SIGHTER_STATE_ROOT")
          .value_or((XdgRoot("XDG_STATE_HOME", ".local/state") / "sighter")
                        .string());
  const std::filesystem::path installed_compatibility =
      InstalledMetadata("roblox_compatibility.json");
  const std::filesystem::path installed_trust =
      InstalledMetadata("roblox_signing_certificates.json");
  const std::filesystem::path default_host_abi_reference =
      DefaultHostAbiReference();
  paths.compatibility_manifest =
      Environment("SIGHTER_UPDATE_COMPATIBILITY_PATH")
          .value_or(installed_compatibility.empty()
                        ? SIGHTER_DEFAULT_COMPATIBILITY_MANIFEST
                        : installed_compatibility.string());
  paths.signing_trust_manifest =
      Environment("SIGHTER_UPDATE_SIGNING_TRUST_PATH")
          .value_or(installed_trust.empty()
                        ? SIGHTER_DEFAULT_SIGNING_TRUST_MANIFEST
                        : installed_trust.string());
  paths.host_abi_reference_profile =
      Environment("SIGHTER_UPDATE_HOST_ABI_REFERENCE")
          .value_or(default_host_abi_reference.string());
  const std::filesystem::path executable = ExecutablePath();
  std::filesystem::path runtime = executable.parent_path() / "sighter";
  if (executable.parent_path().filename() == "sighter" &&
      executable.parent_path().parent_path().filename() == "lib") {
    const std::filesystem::path public_runtime =
        executable.parent_path().parent_path().parent_path() / "bin/sighter";
    std::error_code error;
    if (std::filesystem::is_regular_file(public_runtime, error)) {
      runtime = public_runtime;
    }
  }
  paths.runtime_binary =
      Environment("SIGHTER_UPDATE_CANARY_BIN").value_or(runtime.string());
  return paths;
}

int ProgressDescriptor() {
  const auto value = Environment("SIGHTER_UPDATE_PROGRESS_FD");
  if (!value.has_value()) return -1;
  int descriptor = -1;
  const auto parsed =
      std::from_chars(value->data(), value->data() + value->size(), descriptor);
  return parsed.ec == std::errc() &&
                 parsed.ptr == value->data() + value->size() && descriptor >= 0
             ? descriptor
             : -1;
}

void Usage(std::ostream& output) {
  output << "Usage: sighter_updater COMMAND [OPTIONS]\n\n"
            "Commands:\n"
            "  update [--startup-preflight] [--no-latest-check] "
            "[--skip-canary]\n"
            "  check-latest\n"
            "  verify-current\n"
            "  verify-apk APK\n"
            "  prepare-apks OUTPUT APK [APK...]\n"
            "  derive-host-abi OUTPUT REF_LIB REF_PROFILE CANDIDATE_DIR "
            "[REF_COMPAT...]\n"
            "  status\n"
            "  rollback\n";
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    Usage(std::cerr);
    return 2;
  }
  const sighter::update::UpdatePaths paths = ResolvePaths();
  const std::string_view command = argv[1];
  sighter::update::PayloadStore store(
      paths.data_root, paths.compatibility_manifest, paths.runtime_binary);
  if (command == "check-latest") {
    if (argc != 2) return 2;
    const sighter::update::ProviderVersion latest =
        sighter::update::ApkPureProvider().CheckLatest();
    if (!latest) {
      std::cerr << "[native-updater] " << latest.error << '\n';
      return 1;
    }
    std::cout << latest.version_name << ' ' << latest.version_code << '\n';
    return 0;
  }
  if (command == "status") {
    if (argc != 2) return 2;
    std::string error;
    const std::string status = store.StatusJson(&error);
    if (!error.empty()) {
      std::cerr << "[native-updater] " << error << '\n';
      return 1;
    }
    std::cout << status;
    return 0;
  }
  if (command == "verify-current") {
    if (argc != 2) return 2;
    const auto current = store.VerifyCurrent();
    if (!current) {
      std::cerr << "[native-updater] " << current.error << '\n';
      return 1;
    }
    std::cout << current.payload_id << '\n';
    return 0;
  }
  if (command == "verify-apk") {
    if (argc != 3) return 2;
    const std::filesystem::path apk = argv[2];
    const auto signature = sighter::update::VerifyApkSignature(apk);
    if (!signature) {
      std::cerr << "[native-updater] " << signature.error << '\n';
      return 1;
    }
    const auto encoded_manifest = sighter::update::ReadZipEntry(
        apk, "AndroidManifest.xml", 16U * 1024U * 1024U);
    if (!encoded_manifest) {
      std::cerr << "[native-updater] " << encoded_manifest.error << '\n';
      return 1;
    }
    const auto identity =
        sighter::update::ParseAndroidManifest(encoded_manifest.bytes);
    if (!identity) {
      std::cerr << "[native-updater] " << identity.error << '\n';
      return 1;
    }
    std::cout << identity.package_name << ' ' << identity.version_name << ' '
              << identity.version_code << ' '
              << (identity.split_name.empty() ? "base" : identity.split_name)
              << '\n';
    for (const std::string& certificate : signature.certificate_sha256) {
      std::cout << certificate << '\n';
    }
    return 0;
  }
  if (command == "prepare-apks") {
    if (argc < 4) return 2;
    std::vector<std::filesystem::path> archives;
    for (int index = 3; index < argc; ++index)
      archives.emplace_back(argv[index]);
    const auto encoded_manifest = sighter::update::ReadZipEntry(
        archives.front(), "AndroidManifest.xml", 16U * 1024U * 1024U);
    if (!encoded_manifest) {
      std::cerr << "[native-updater] " << encoded_manifest.error << '\n';
      return 1;
    }
    const auto identity =
        sighter::update::ParseAndroidManifest(encoded_manifest.bytes);
    const auto catalog = sighter::update::LoadCompatibilityCatalog(
        paths.compatibility_manifest);
    if (!identity || !catalog) {
      std::cerr << "[native-updater] "
                << (!identity ? identity.error : catalog.error) << '\n';
      return 1;
    }
    const auto profile = sighter::update::FindSupportedProfile(
        catalog.profiles, identity.version_name, identity.version_code);
    if (!profile.has_value()) {
      std::cerr << "[native-updater] APK is not exact-supported\n";
      return 1;
    }
    const auto prepared = sighter::update::PreparePayloadFromArchives(
        archives, sighter::update::ExactPayloadIdentity(*profile),
        paths.signing_trust_manifest, argv[2], "native-local-import");
    if (!prepared) {
      std::cerr << "[native-updater] " << prepared.error << '\n';
      return 1;
    }
    std::cout << prepared.directory << '\n';
    return 0;
  }
  if (command == "rollback") {
    if (argc != 2) return 2;
    const auto rolled_back = store.Rollback();
    if (!rolled_back) {
      std::cerr << "[native-updater] " << rolled_back.error << '\n';
      return 1;
    }
    std::cout << rolled_back.payload_id << '\n';
    return 0;
  }
  if (command == "derive-host-abi") {
    if (argc < 6) return 2;
    sighter::update::HostAbiDerivationOptions options;
    options.output_directory = argv[2];
    options.reference_library = argv[3];
    options.reference_profile = argv[4];
    options.candidate_payload_directory = argv[5];
    for (int index = 6; index < argc; ++index) {
      options.reference_compatibility_manifests.emplace_back(argv[index]);
    }
    const auto derived = sighter::update::DeriveHostAbiProfile(options);
    if (!derived) {
      std::cerr << "[native-updater] " << derived.error << '\n';
      return 1;
    }
    std::cout << derived.profile << '\n'
              << derived.compatibility_manifest << '\n';
    return 0;
  }
  if (command != "update") {
    Usage(std::cerr);
    return 2;
  }
  sighter::update::UpdateRequest request;
  request.progress_fd = ProgressDescriptor();
  const std::string graphics_backend =
      Environment("SIGHTER_GRAPHICS_BACKEND").value_or("direct-vulkan");
  if (!sighter::update::ParseCanaryGraphicsBackend(
          graphics_backend, &request.canary_graphics_backend)) {
    std::cerr << "[native-updater] unsupported graphics backend: "
              << graphics_backend << '\n';
    return 2;
  }
  for (int index = 2; index < argc; ++index) {
    const std::string_view option = argv[index];
    if (option == "--startup-preflight") {
      request.startup_preflight = true;
    } else if (option == "--no-latest-check") {
      request.check_latest = false;
    } else if (option == "--skip-canary") {
      request.run_canary = false;
    } else if (option == "--force-run-latest") {
      request.force_run_latest = true;
    } else {
      std::cerr << "[native-updater] unknown option: " << option << '\n';
      return 2;
    }
  }
  if (request.force_run_latest &&
      (request.startup_preflight || !request.check_latest || !request.run_canary)) {
    std::cerr << "[native-updater] --force-run-latest cannot be combined with "
                 "--startup-preflight, --no-latest-check, or --skip-canary\n";
    return 2;
  }
  if (request.force_run_latest) {
    std::cerr << "[native-updater] WARNING: latest Roblox will run once without "
                 "approval and will not become the active payload\n";
  }
  const sighter::update::UpdateResult updated =
      sighter::update::RunUpdate(paths, request);
  for (const std::string& warning : updated.warnings) {
    std::cerr << "[native-updater] warning: " << warning << '\n';
  }
  if (!updated) {
    std::cerr << "[native-updater] " << updated.error << '\n';
    return 1;
  }
  if (!updated.message.empty()) {
    std::cerr << "[native-updater] " << updated.message << '\n';
  }
  // Still exits zero so the session launches, but the user has to be told:
  // it is the Roblox servers, not Sighter, that will refuse the join.
  if (updated.stale) {
    std::cerr << "[native-updater] warning: the active Roblox payload is out "
                 "of date and joining an experience can be refused\n";
  }
  if (!updated.payload_id.empty()) std::cout << updated.payload_id << '\n';
  return 0;
}
