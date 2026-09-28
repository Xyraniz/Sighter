#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "compat/elf_build_id.h"
#include "compat/host_abi_profile.h"
#include "compat/payload_compatibility.h"
#include "legacy/legacy_runtime.h"
#include "libc_shim/libc_shim.h"
#include "sighter/audio/fmod_jni_audio_bridge.h"
#include "sighter/audio/webrtc_jni_audio_bridge.h"
#include "sighter/audio/roblox_output_device_bridge.h"
#include "runtime/auth_runtime_composition.h"
#include "runtime/command_line.h"
#include "runtime/crash_report_policy.h"
#include "runtime/environment.h"
#include "runtime/external_launch_broker.h"
#include "runtime/failure_dialog.h"
#include "runtime/fleasion.h"
#include "runtime/game_mode.h"
#include "runtime/graphics_launch_policy.h"
#include "runtime/memory_limit.h"
#include "runtime/payload_update_preflight.h"
#include "runtime/performance_policy.h"
#include "runtime/platform_cache_migration.h"
#include "runtime/process_diagnostics.h"
#include "runtime/process_launch_policy.h"
#include "runtime/roblox_desktop_app_policy.h"
#include "runtime/roblox_experience_launch_bridge.h"
#include "runtime/roblox_fullscreen_runtime_bridge.h"
#include "runtime/runtime_config_bootstrap.h"
#include "runtime/runtime_config_file.h"
#include "runtime/runtime_paths.h"
#include "runtime/session_log.h"
#include "runtime/single_instance_lock.h"
#include "runtime/support_bundle.h"
#include "runtime/supported_launch_policy.h"
#include "runtime/system_proxy.h"
#include "runtime/webview_helper_launcher.h"
#include "services/auth_service.h"
#include "services/browser_tracker_service.h"
#include "services/client_settings_service.h"
#include "services/http_client.h"
#include "window/window.h"

namespace {

struct AndroidWindowBridgeContext {};

class ExternalLaunchBrokerScope final {
 public:
  ~ExternalLaunchBrokerScope() { (void)Shutdown(); }

  std::shared_ptr<sighter::runtime::ExternalLaunchBroker>& broker() {
    return broker_;
  }

  sighter::Status Shutdown() {
    if (broker_ == nullptr) {
      return sighter::Status::Ok();
    }
    sighter::runtime::ClearActiveExternalLaunchBroker(broker_.get());
    sighter::Status status = broker_->Shutdown();
    broker_.reset();
    return status;
  }

 private:
  std::shared_ptr<sighter::runtime::ExternalLaunchBroker> broker_;
};

void SecureErase(char* data, std::size_t size) {
  volatile char* bytes = data;
  for (std::size_t index = 0; bytes != nullptr && index < size; ++index) {
    bytes[index] = '\0';
  }
}

void SecureEraseArguments(std::vector<std::string>* arguments) {
  if (arguments == nullptr) return;
  for (std::string& argument : *arguments) {
    SecureErase(argument.data(), argument.size());
  }
  arguments->clear();
}

bool QueueAndroidWindowFlags(void*, int flags, int mask) {
  return sighter::window::RequestFullscreenFromAndroidWindowFlags(flags, mask);
}

sighter::Status ShutdownPlatformBridges(jnivm::VM* vm) {
  if (vm == nullptr) {
    return sighter::Status::Error(sighter::StatusCode::kInvalidArgument,
                                   "platform bridge shutdown requires a VM");
  }
  vm->ClearAndroidWindowCallbacks();
  const sighter::Status voice_status =
      sighter::audio::ShutdownWebRtcJniAudioBridge(vm);
  const sighter::Status playback_status =
      sighter::audio::ShutdownFmodJniAudioBridge(vm);
  return !voice_status.ok() ? voice_status : playback_status;
}

void PromptFirstLaunchSignIn(
    const sighter::runtime::ProcessEnvironment& environment,
    const sighter::runtime::RuntimePaths& paths,
    sighter::services::AuthService& auth_service,
    const std::shared_ptr<sighter::services::HttpClient>& http_client,
    sighter::runtime::AuthRuntimeComposition* composition) {
  if (composition == nullptr ||
      composition->status != sighter::runtime::AuthRuntimeStatus::kGuest ||
      environment.Get("SIGHTER_GUEST") == "1" ||
      environment.Get("SIGHTER_SKIP_FIRST_LAUNCH_LOGIN") == "1") {
    return;
  }
  if (environment.Get("SIGHTER_NATIVE_LOGIN") != "0") {
    std::cout << "  [auth] native sign-in selected; opening Roblox welcome screen\n";
    return;
  }

  std::filesystem::path helper;
  const char* helper_override = std::getenv("SIGHTER_WEBVIEW_HELPER");
  if (helper_override != nullptr && helper_override[0] != '\0') {
    helper = helper_override;
  } else {
    std::error_code error;
    const std::filesystem::path executable =
        std::filesystem::read_symlink("/proc/self/exe", error);
    if (!error && !executable.empty()) {
      helper = executable.parent_path() / "sighter_webview_helper";
    }
  }
  if (helper.empty() || !std::filesystem::exists(helper)) {
    return;
  }

  std::cout << "\n======================================================\n"
            << "  First-Time Setup: Roblox Sign-In\n"
            << "======================================================\n"
            << "  [auth] no saved session found; opening desktop sign-in window...\n"
            << "  [auth] tip: you can use Quick Log In (QR code) or username/password\n"
            << "  [auth] (close the sign-in window to play as guest)\n\n";

  struct FirstLaunchContext {
    std::mutex mutex;
    std::string captured_cookie;
    bool finished = false;
  };
  auto context = std::make_shared<FirstLaunchContext>();

  sighter::runtime::WebViewHelperExitObserver exit_observer;
  exit_observer.context = context;
  exit_observer.on_exit = [](void* ctx) {
    auto* c = static_cast<FirstLaunchContext*>(ctx);
    std::lock_guard<std::mutex> lock(c->mutex);
    c->finished = true;
  };

  const auto launched = sighter::runtime::LaunchWebViewHelper(
      helper, "https://www.roblox.com/login", exit_observer);
  if (!launched || launched.process == nullptr) {
    return;
  }
  if (!launched.process->WaitUntilReady(std::chrono::milliseconds(5000))) {
    (void)launched.process->RequestClose();
    return;
  }
  (void)launched.process->SetRobloxCookie("");
  (void)launched.process->SetTitle("Roblox sign in");
  (void)launched.process->SetVisible(true);

  std::vector<sighter::runtime::WebViewHelperEvent> events;
  while (true) {
    {
      std::lock_guard<std::mutex> lock(context->mutex);
      if (context->finished) {
        break;
      }
    }
    if (launched.process->DrainEvents(&events)) {
      for (const auto& event : events) {
        if (event.type ==
            sighter::runtime::WebViewHelperEventType::kRobloxCookie) {
          std::lock_guard<std::mutex> lock(context->mutex);
          context->captured_cookie = event.payload;
          (void)launched.process->RequestClose();
          break;
        }
      }
      events.clear();
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
  }

  if (!context->captured_cookie.empty()) {
    if (sighter::runtime::PersistRobloxCookie(paths.cookie_file(),
                                               context->captured_cookie)) {
      sighter::runtime::AuthRuntimeComposition new_comp =
          sighter::runtime::ComposeAuthRuntime(environment, paths,
                                                auth_service, http_client);
      if (new_comp.status ==
          sighter::runtime::AuthRuntimeStatus::kAuthenticated) {
        *composition = std::move(new_comp);
        std::cout << "  [auth] desktop sign-in successful; launching authenticated session\n";
      }
    }
  } else {
    std::cout << "  [auth] desktop sign-in window closed; continuing as guest\n";
  }
}

void ConfigureHostDriverEnvironment() {
  auto set_if_unset = [](const char* name, const char* value) {
    if (std::getenv(name) == nullptr) {
      setenv(name, value, 1);
    }
  };
  // Bypass X11 compositor redirection to eliminate presentation latency on X11/XWayland.
  set_if_unset("SDL_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR", "1");
  // Allow Adaptive Sync / Variable Refresh Rate (G-Sync/FreeSync) where supported.
  set_if_unset("__GL_VRR_ALLOWED", "1");
  // Expand shader disk cache to 2GB so compiled Vulkan/GL shaders are preserved across runs.
  set_if_unset("__GL_SHADER_DISK_CACHE", "1");
  set_if_unset("__GL_SHADER_DISK_CACHE_SIZE", "2147483648");
  // Avoid busy-spin vblank waits on NVIDIA Linux driver.
  set_if_unset("__GL_YIELD", "USLEEP");
  set_if_unset("__GL_THREADED_OPTIMIZATIONS", "1");
}

}  // namespace

int main(int argc, char* argv[]) {
  ConfigureHostDriverEnvironment();
  const auto process_started_at = std::chrono::system_clock::now();
  sighter::runtime::CommandLineParseResult command_line =
      sighter::runtime::ParseCommandLine(argc, argv);
  if (!command_line) {
    std::cerr << command_line.error << "\n\n"
              << sighter::runtime::CommandLineUsage(
                     command_line.options.program_name);
    return EXIT_FAILURE;
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kHelp) {
    std::cout << sighter::runtime::CommandLineUsage(
        command_line.options.program_name);
    return EXIT_SUCCESS;
  }
  // Normalize inherited process state before bootstrap or helpers can create
  // threads. Keep research/canary resource limits under their caller's control.
  const std::string process_launch_diagnostics =
      command_line.options.mode == sighter::runtime::CommandMode::kRun
          ? sighter::runtime::ApplyInteractiveProcessLaunchPolicy()
          : std::string{};
  std::string command_line_error;
  if (!sighter::runtime::ApplySupportedLaunchPolicy(
          command_line.options.mode == sighter::runtime::CommandMode::kRun,
          &command_line_error)) {
    std::cerr << "[FATAL] " << command_line_error << '\n';
    return EXIT_FAILURE;
  }
  if (!sighter::runtime::ApplyCommandLineEnvironment(command_line.options,
                                                      &command_line_error)) {
    std::cerr << command_line_error << '\n';
    return EXIT_FAILURE;
  }

  const sighter::runtime::ProcessEnvironment environment;
  const std::string built_in_compatibility_manifest = environment.GetOr(
      "SIGHTER_UPDATE_COMPATIBILITY_PATH",
      environment.GetOr("SIGHTER_COMPATIBILITY_MANIFEST",
                        SIGHTER_DEFAULT_COMPATIBILITY_MANIFEST));
  const sighter::runtime::RuntimePaths paths =
      sighter::runtime::RuntimePaths::FromEnvironment(environment);
  if (command_line.options.force_run_latest) {
    std::cerr << "[runtime] WARNING: latest Roblox will run once without "
                 "approval and will not become the active payload\n";
    const sighter::runtime::PayloadUpdatePreflightResult force_latest =
        sighter::runtime::RunPayloadUpdatePreflight(environment, paths, true);
    if (!force_latest) {
      std::cerr << "[FATAL] " << force_latest.error;
      if (!force_latest.details.empty()) {
        std::cerr << ": " << force_latest.details;
      }
      std::cerr << '\n';
      return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
  }
  std::optional<sighter::runtime::RobloxExperienceLaunchRequest>
      external_launch_request;
  if (!command_line.options.launch_request_json.empty()) {
    external_launch_request.emplace();
    const sighter::Status launch_status =
        sighter::runtime::ParseRobloxExperienceLaunchJson(
            command_line.options.launch_request_json,
            &*external_launch_request);
    if (!launch_status.ok()) {
      std::cerr << "[FATAL] Invalid controlled website launch request\n";
      return EXIT_FAILURE;
    }
  }
  std::vector<std::string> cgroup_reexec_arguments;
  if (!sighter::runtime::BuildCommandLineReexecArguments(
          command_line.options, argc, argv, &cgroup_reexec_arguments,
          &command_line_error)) {
    std::cerr << "[FATAL] " << command_line_error << '\n';
    return EXIT_FAILURE;
  }
  sighter::runtime::ScrubCommandLineLaunchArguments(&command_line.options,
                                                     argc, argv);
  sighter::runtime::SessionLog session_log;
  sighter::runtime::FailureSupportBundleGuard support_bundle_guard(
      environment, paths,
      command_line.options.mode == sighter::runtime::CommandMode::kRun);
  std::optional<sighter::runtime::SingleInstanceLock> instance_lock;
  ExternalLaunchBrokerScope external_launch_broker;
  sighter::runtime::ExternalLaunchBrokerOptions broker_options;
  const bool isolated_canary =
      environment.GetOr("SIGHTER_ISOLATED_CANARY", "0") == "1";
  if (isolated_canary && external_launch_request.has_value()) {
    std::cerr << "[FATAL] Website launches are unavailable inside isolated "
                 "canary\n";
    return EXIT_FAILURE;
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    instance_lock.emplace(
        sighter::runtime::SingleInstanceLock::AcquireForLaunch(environment,
                                                                paths));
    if (!instance_lock->acquired()) {
      if (!isolated_canary && instance_lock->already_running() &&
          external_launch_request.has_value()) {
        const sighter::Status forward_status =
            sighter::runtime::ExternalLaunchBroker::ForwardToOwner(
                broker_options, *external_launch_request);
        if (forward_status.ok()) {
          std::cout << "  [launch] sent website join to running Sighter\n";
          support_bundle_guard.SetExitCode(EXIT_SUCCESS);
          return EXIT_SUCCESS;
        }
        std::cerr << "[FATAL] Cannot send website join to running Sighter: "
                  << forward_status.message() << '\n';
        (void)sighter::runtime::ShowFailureDialog(
            environment,
            "Sighter is already running, but the requested experience "
            "could not be sent to it.");
      } else if (instance_lock->already_running()) {
        std::cerr << "[FATAL] Sighter is already running for this user\n";
        (void)sighter::runtime::ShowFailureDialog(
            environment, "An instance of Sighter is already running.");
      } else {
        std::cerr << "[FATAL] " << instance_lock->error() << '\n';
        (void)sighter::runtime::ShowFailureDialog(
            environment, "Sighter could not acquire its launch lock.");
      }
      return EXIT_FAILURE;
    }
  }
  const sighter::runtime::RuntimeConfigBootstrapResult config_bootstrap =
      sighter::runtime::EnsureRuntimeConfigFile(paths.config_file());
  if (!config_bootstrap) {
    std::cerr << "[FATAL] Cannot prepare " << paths.config_file() << ": "
              << config_bootstrap.error << '\n';
    if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
      (void)sighter::runtime::ShowFailureDialog(
          environment, "Sighter could not prepare its configuration.");
    }
    return EXIT_FAILURE;
  }
  sighter::runtime::RuntimeConfigLoadResult runtime_config =
      sighter::runtime::LoadRuntimeConfig(environment, paths.config_file());
  if (!runtime_config) {
    std::cerr << "[FATAL] Cannot load " << paths.config_file() << ": "
              << runtime_config.error << '\n';
    if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
      (void)sighter::runtime::ShowFailureDialog(
          environment, "Sighter could not load its configuration.");
    }
    return EXIT_FAILURE;
  }
  if (runtime_config.config.use_system_proxy()) {
    const sighter::runtime::SystemProxyResult system_proxy =
        sighter::runtime::ResolveSystemProxy();
    const std::string proxy_host = system_proxy.proxy.has_value()
                                       ? system_proxy.proxy->host
                                       : std::string();
    const std::string proxy_port =
        system_proxy.proxy.has_value()
            ? std::to_string(system_proxy.proxy->port)
            : std::string();
    const std::string proxy_scheme = system_proxy.proxy.has_value()
                                         ? system_proxy.proxy->scheme
                                         : std::string();
    if (!system_proxy ||
        setenv("SIGHTER_HTTP_PROXY_HOST", proxy_host.c_str(), 1) != 0 ||
        setenv("SIGHTER_HTTP_PROXY_PORT", proxy_port.c_str(), 1) != 0 ||
        setenv("SIGHTER_HTTP_PROXY_SCHEME", proxy_scheme.c_str(), 1) != 0) {
      std::cerr << "[FATAL] Cannot resolve host system proxy";
      if (!system_proxy.error.empty()) {
        std::cerr << ": " << system_proxy.error;
      }
      std::cerr << '\n';
      return EXIT_FAILURE;
    }
    runtime_config = sighter::runtime::LoadRuntimeConfig(
        environment, paths.config_file());
    if (!runtime_config) {
      std::cerr << "[FATAL] Cannot apply host system proxy: "
                << runtime_config.error << '\n';
      return EXIT_FAILURE;
    }
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun &&
      runtime_config.config.has_unsafe_detached_thread_overrides()) {
    std::cerr << "[FATAL] Unsupported detached legacy thread overrides:\n";
    for (const std::string& name :
         runtime_config.config.unsafe_detached_thread_overrides()) {
      std::cerr << "  - " << name << '\n';
    }
    std::cerr << "  Supported runtime requires synchronous or owned worker "
                 "execution.\n";
    (void)sighter::runtime::ShowFailureDialog(
        environment,
        "Sighter cannot start with unsupported legacy thread "
        "overrides enabled.");
    return EXIT_FAILURE;
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun &&
      !sighter::runtime::ApplyGraphicsLaunchPolicy(runtime_config.config,
                                                     &command_line_error)) {
    std::cerr << "[FATAL] " << command_line_error << '\n';
    return EXIT_FAILURE;
  }
  sighter::runtime::FailureDialogMonitor failure_dialog;
  sighter::runtime::MemoryLimitWatchdog memory_limit_watchdog;
  const bool use_memory_limit =
      command_line.options.mode == sighter::runtime::CommandMode::kRun &&
      runtime_config.config.performance().memory_limit_enabled();
  const std::uint64_t memory_limit_bytes =
      use_memory_limit
          ? runtime_config.config.performance().memory_limit_bytes()
          : 0;
  sighter::runtime::CgroupMemoryLimitResult cgroup_limit;
  if (use_memory_limit) {
    cgroup_limit = sighter::runtime::MaybeReexecWithCgroupMemoryLimit(
        argc, argv, memory_limit_bytes, &cgroup_reexec_arguments);
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    session_log = sighter::runtime::SessionLog::Start(
        environment, paths, process_started_at);
    if (session_log) {
      std::cout << session_log.Header(
                       environment, paths,
                       runtime_config.config.graphics_backend_name())
                << std::flush;
    } else if (session_log.attempted()) {
      std::cerr << "  [session] automatic logging unavailable: "
                << session_log.error() << '\n';
    }
    std::cout << process_launch_diagnostics << std::flush;
    sighter::runtime::InstallCpuLimitDiagnostics();
    sighter::runtime::LogProcessDiagnostics(
        sighter::runtime::ProcessDiagnosticStage::kStartup);
  }
  if (runtime_config.config.fleasion_enabled()) {
    const auto fleasion = sighter::runtime::PrepareFleasion(
        runtime_config.config, environment, paths);
    if (!fleasion ||
        setenv("SIGHTER_CA_BUNDLE", fleasion.bundle.c_str(), 1) != 0 ||
        setenv("SIGHTER_FLEASION_BASE_CA_BUNDLE", fleasion.base_bundle.c_str(), 1) != 0 ||
        setenv("SIGHTER_FLEASION_GENERATED_BUNDLE", fleasion.bundle.c_str(), 1) != 0 ||
        setenv("SIGHTER_FLEASION_CA_CERTIFICATE", fleasion.certificate.c_str(), 1) != 0) {
      std::cerr << "[FATAL] Cannot prepare Fleasion: "
                << (!fleasion ? fleasion.error : "cannot export certificate paths") << '\n';
      return EXIT_FAILURE;
    }
    if (const auto& proxy = runtime_config.config.network_proxy(); proxy &&
        (setenv("SIGHTER_HTTP_PROXY_HOST", proxy->host.c_str(), 1) != 0 ||
         setenv("SIGHTER_HTTP_PROXY_PORT", std::to_string(proxy->port).c_str(), 1) != 0 ||
         setenv("SIGHTER_HTTP_PROXY_SCHEME", proxy->scheme.c_str(), 1) != 0)) {
      std::cerr << "[FATAL] Cannot export Fleasion proxy\n";
      return EXIT_FAILURE;
    }
    runtime_config = sighter::runtime::LoadRuntimeConfig(environment, paths.config_file());
    if (!runtime_config) {
      std::cerr << "[FATAL] Cannot apply Fleasion: " << runtime_config.error << '\n';
      return EXIT_FAILURE;
    }
    std::cout << "  [fleasion] mode=" << runtime_config.config.fleasion_proxy_mode()
              << " certificate=" << fleasion.certificate
              << " trust_bundle=" << fleasion.bundle << '\n';
    if (runtime_config.config.network_proxy()) {
      std::cout << "  [fleasion] proxy=" << sighter::runtime::BuildNetworkProxyUrl(
          *runtime_config.config.network_proxy()) << "; start Fleasion before Roblox\n";
    }
  }
  if (config_bootstrap.created()) {
    std::cout << "  [runtime] created first-run configuration: "
              << paths.config_file() << '\n';
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun &&
      runtime_config.config.use_system_proxy()) {
    if (runtime_config.config.network_proxy().has_value()) {
      std::cout << "  [network] system proxy="
                << sighter::runtime::BuildNetworkProxyUrl(
                       *runtime_config.config.network_proxy())
                << '\n';
    } else {
      std::cout << "  [network] system proxy=direct\n";
    }
  }
  if (use_memory_limit) {
    if (cgroup_limit.active()) {
      std::cout << "  [memory] hard process-tree limit active: "
                << runtime_config.config.performance().memory_limit_mb
                << " MiB RAM, swap disabled\n";
    }
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    std::cout << "  [runtime] graphics backend="
              << runtime_config.config.graphics_backend_name()
              << (runtime_config.config.graphics_backend() ==
                          sighter::runtime::GraphicsBackend::kSystem
                      ? " (EGL/OpenGL ES)"
                      : "")
              << '\n';
  }

  // Register before starting helper processes or loading the Android payload.
  // libgamemode caches its shared
  // D-Bus connection, so the first use must happen in the final game process.
  const sighter::runtime::GameModePolicy game_mode_policy =
      runtime_config.config.performance().game_mode;
  sighter::runtime::GameModeSession game_mode_session =
      command_line.options.mode == sighter::runtime::CommandMode::kRun
          ? sighter::runtime::GameModeSession::Start(game_mode_policy)
          : sighter::runtime::GameModeSession();
  switch (game_mode_session.state()) {
    case sighter::runtime::GameModeSessionState::kActive:
      std::cout << "  [gamemode] performance request active\n";
      break;
    case sighter::runtime::GameModeSessionState::kAlreadyActive:
      std::cout << "  [gamemode] already active for this process\n";
      break;
    case sighter::runtime::GameModeSessionState::kUnavailable:
    case sighter::runtime::GameModeSessionState::kRequestFailed:
      if (game_mode_policy == sighter::runtime::GameModePolicy::kOn) {
        std::cerr << "  [gamemode] requested but unavailable: "
                  << game_mode_session.detail()
                  << "; continuing without GameMode\n";
      } else {
        std::cout << "  [gamemode] unavailable; continuing normally\n";
      }
      break;
    case sighter::runtime::GameModeSessionState::kDisabled:
      if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
        std::cout << "  [gamemode] disabled by runtime policy\n";
      }
      break;
    case sighter::runtime::GameModeSessionState::kStopped:
    case sighter::runtime::GameModeSessionState::kStopFailed:
      break;
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    failure_dialog = sighter::runtime::FailureDialogMonitor::Start(
        environment,
        "Sighter could not start Roblox because of an internal error.");
  }
  if (use_memory_limit) {
    if (!memory_limit_watchdog.Start(memory_limit_bytes, &command_line_error)) {
      failure_dialog.SetMessage(
          "Sighter could not start its memory safety monitor.");
      std::cerr << "[FATAL] " << command_line_error << '\n';
      return EXIT_FAILURE;
    }
    std::cout << "  [memory] RSS+swap watchdog active at "
              << runtime_config.config.performance().memory_limit_mb
              << " MiB\n";
  }
  SecureEraseArguments(&cgroup_reexec_arguments);
  const bool uses_managed_payload =
      !environment.HasNonEmpty("ROBLOX_LIB_PATH") &&
      runtime_config.config.roblox_library_path() ==
          std::filesystem::path("rbx_bin/libroblox.so");
  if (!uses_managed_payload &&
      !environment.HasNonEmpty("SIGHTER_ASSET_PATH")) {
    const std::filesystem::path adjacent_assets =
        sighter::runtime::ResolveAdjacentRobloxAssetPath(
            runtime_config.config.roblox_library_path(),
            paths.working_directory());
    if (adjacent_assets.empty() ||
        setenv("SIGHTER_ASSET_PATH", adjacent_assets.c_str(), 1) != 0) {
      std::cerr << "[FATAL] Cannot bind assets to explicit Roblox library\n";
      return EXIT_FAILURE;
    }
    std::cout << "  [runtime] explicit Roblox library uses adjacent assets: "
              << adjacent_assets << '\n';
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun &&
      uses_managed_payload) {
    failure_dialog.SetMessage(
        "Sighter could not update or verify the Roblox installation.");
    const sighter::runtime::PayloadUpdatePreflightResult update_preflight =
        sighter::runtime::RunPayloadUpdatePreflight(environment, paths);
    if (!update_preflight) {
      std::cerr << "[FATAL] " << update_preflight.error;
      if (!update_preflight.details.empty()) {
        // Without this the dialog only ever said "could not update or verify",
        // which is indistinguishable between a provider outage, a rejected
        // signature, and a full disk.
        std::cerr << ": " << update_preflight.details;
        failure_dialog.SetMessage(
            "Sighter could not update or verify the Roblox installation.\n\n" +
            update_preflight.details + "\n\nSession log: " +
            (paths.logs_root() / "sessions").string());
      }
      std::cerr << '\n';
      return EXIT_FAILURE;
    }
    failure_dialog.SetMessage(
        "Sighter could not finish starting Roblox because of an internal "
        "error.");
  }
  if (!sighter::runtime::ExportRuntimePathEnvironment(paths,
                                                       &command_line_error)) {
    std::cerr << "[FATAL] " << command_line_error << '\n';
    return EXIT_FAILURE;
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    const sighter::Status window_state_status =
        sighter::window::ConfigureWindowStatePersistence(paths.state_root() /
                                                          "window-state.json");
    if (!window_state_status.ok()) {
      std::cerr << "[FATAL] Cannot configure window state persistence: "
                << window_state_status.message() << '\n';
      return EXIT_FAILURE;
    }
  }
  std::filesystem::path app_storage_file;
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    const sighter::runtime::InputCapabilityConfig& input =
        runtime_config.config.input_capabilities();
    const std::string platform_profile =
        sighter::runtime::BuildPlatformProfileRevision(
            runtime_config.config.device_profile().cache_key,
            input.touch_enabled, input.mouse_enabled, input.keyboard_enabled);
    const sighter::runtime::PlatformCacheMigrationResult cache_migration =
        sighter::runtime::MigratePlatformProfileCaches(environment, paths,
                                                        platform_profile);
    if (!cache_migration) {
      std::cerr << "[FATAL] Platform cache migration failed: "
                << cache_migration.error << '\n';
      return EXIT_FAILURE;
    }
    app_storage_file = cache_migration.app_storage_file;
    setenv("SIGHTER_APP_STORAGE_FILE_INTERNAL", app_storage_file.c_str(), 1);
    if (cache_migration.transitioned) {
      std::cout << "  [runtime] platform cache profile transitioned; "
                << "refreshable identity and policy caches invalidated="
                << (cache_migration.app_storage_updated ? 1 : 0) << '\n';
    }
  }
  const bool needs_active_library =
      !environment.HasNonEmpty("ROBLOX_LIB_PATH") &&
      runtime_config.config.roblox_library_path() ==
          std::filesystem::path("rbx_bin/libroblox.so");
  const bool needs_active_assets =
      !environment.HasNonEmpty("SIGHTER_ASSET_PATH");
  if (needs_active_library || needs_active_assets) {
    const sighter::runtime::ActivePayloadPaths active =
        paths.ResolveActivePayload();
    if (!active) {
      std::cerr << "[FATAL] Cannot resolve " << paths.active_payload_manifest()
                << ": " << active.error << '\n';
      return EXIT_FAILURE;
    }
    if (active.active) {
      if (uses_managed_payload &&
          !sighter::runtime::PrepareManagedPayloadWorkingDirectory(
              paths, active, &command_line_error)) {
        std::cerr << "[FATAL] " << command_line_error << '\n';
        return EXIT_FAILURE;
      }
      if ((needs_active_library &&
           setenv("ROBLOX_LIB_PATH", active.roblox_library.c_str(), 1) != 0) ||
          (needs_active_assets &&
           setenv("SIGHTER_ASSET_PATH", active.assets_content.c_str(), 1) !=
               0)) {
        std::cerr << "[FATAL] Cannot activate resolved Roblox payload\n";
        return EXIT_FAILURE;
      }
      if (uses_managed_payload) {
        bool use_external_profile = !active.compatibility_manifest.empty();
        if (use_external_profile) {
          const sighter::compat::BuildIdResult active_build_id =
              sighter::compat::ReadElfBuildId(active.roblox_library.string());
          if (!active_build_id) {
            std::cerr << "[FATAL] Cannot identify active Roblox payload: "
                      << active_build_id.error << '\n';
            return EXIT_FAILURE;
          }
          // Built-in profiles supersede stale probation receipts and never
          // use external overrides.
          use_external_profile = sighter::compat::FindHostAbiProfile(
                                     active_build_id.build_id) == nullptr;
        }
        if (use_external_profile) {
          if (setenv("SIGHTER_COMPATIBILITY_MANIFEST",
                     active.compatibility_manifest.c_str(), 1) != 0 ||
              setenv("SIGHTER_HOST_ABI_PROFILE_FILE",
                     active.host_abi_profile.c_str(), 1) != 0 ||
              setenv("SIGHTER_HOST_ABI_APPROVAL_RECEIPT",
                     active.host_abi_approval_receipt.c_str(), 1) != 0) {
            std::cerr
                << "[FATAL] Cannot activate approved Roblox ABI profile\n";
            return EXIT_FAILURE;
          }
        } else if (setenv("SIGHTER_COMPATIBILITY_MANIFEST",
                          built_in_compatibility_manifest.c_str(), 1) != 0 ||
                   unsetenv("SIGHTER_HOST_ABI_PROFILE_FILE") != 0 ||
                   unsetenv("SIGHTER_HOST_ABI_APPROVAL_RECEIPT") != 0) {
          std::cerr << "[FATAL] Cannot activate built-in Roblox ABI profile\n";
          return EXIT_FAILURE;
        }
      }
      runtime_config = sighter::runtime::LoadRuntimeConfig(
          environment, paths.config_file());
      if (!runtime_config) {
        std::cerr << "[FATAL] Cannot resolve runtime configuration: "
                  << runtime_config.error << '\n';
        return EXIT_FAILURE;
      }
    }
  }
  if (!sighter::runtime::ExportRuntimeConfigEnvironment(runtime_config.config,
                                                         &command_line_error)) {
    std::cerr << command_line_error << '\n';
    return EXIT_FAILURE;
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun &&
      !environment.HasNonEmpty("SIGHTER_NATIVE_SET_DEFAULT_POLICY_FILE") &&
      setenv("SIGHTER_NATIVE_SET_DEFAULT_POLICY_FILE", "1", 1) != 0) {
    std::cerr << "[FATAL] Cannot enable Roblox default app-policy file\n";
    return EXIT_FAILURE;
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    std::cout << "  [runtime] device profile="
              << runtime_config.config.device_profile().name << " class="
              << sighter::runtime::DeviceClassName(
                     runtime_config.config.device_profile().device_class)
              << " model=\""
              << runtime_config.config.device_profile().display_name << "\"\n";
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    const std::filesystem::path fflags_path =
        paths.config_root() / "fflags.json";
    const auto fflags = sighter::services::LoadAndMergeFflagsFile(
        fflags_path,
        environment.GetOr("SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON", "{}"));
    if (!fflags.error.empty()) {
      std::cerr << "[FATAL] Cannot load FFlag overrides from " << fflags_path
                << ": " << fflags.error << '\n';
      return EXIT_FAILURE;
    }
    if (fflags.loaded) {
      std::cout << "  [runtime] loaded " << fflags.count
                << " FFlag overrides from " << fflags_path << '\n';
    }
    std::string client_settings_overrides;
    if (!sighter::runtime::MergeRuntimeClientSettingsOverrides(
            runtime_config.config.frame_rate(),
            runtime_config.config.performance(), fflags.json,
            &client_settings_overrides, &command_line_error)) {
      std::cerr << "[FATAL] Cannot apply runtime client-settings policy: "
                << command_line_error << '\n';
      return EXIT_FAILURE;
    }
    std::string audio_capture_overrides;
    if (!sighter::runtime::MergeAudioCaptureClientSettingsOverrides(
            runtime_config.config.microphone_enabled(),
            client_settings_overrides, &audio_capture_overrides,
            &command_line_error)) {
      std::cerr << "[FATAL] Cannot apply microphone permission policy: "
                << command_line_error << '\n';
      return EXIT_FAILURE;
    }
    if (setenv("SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON",
               audio_capture_overrides.c_str(), 1) != 0) {
      std::cerr << "[FATAL] Cannot export runtime client-settings policy\n";
      return EXIT_FAILURE;
    }
    std::cout << "  [runtime] HttpClient compatibility mode enabled: "
                 "generic LuaApp retry and RuntimeMutexRv disabled\n";
    std::string fast_flags_overrides;
    if (!sighter::runtime::MergeCrashReportFastFlagsOverrides(
            environment.GetOr("SIGHTER_FAST_FLAGS_JSON", "{}"),
            &fast_flags_overrides, &command_line_error)) {
      std::cerr << "[FATAL] Cannot apply crash-report fast-flags policy: "
                << command_line_error << '\n';
      return EXIT_FAILURE;
    }
    if (setenv("SIGHTER_FAST_FLAGS_JSON", fast_flags_overrides.c_str(), 1) !=
        0) {
      std::cerr << "[FATAL] Cannot export crash-report fast-flags policy\n";
      return EXIT_FAILURE;
    }
    std::cout << "  [runtime] Roblox crash-report uploads disabled by "
                 "mandatory policy\n";
    const auto physics_worker_mode =
        runtime_config.config.performance().physics_worker_mode;
    const int physical_core_count =
        runtime_config.config.performance().physical_core_count;
    const int engine_worker_count =
        physics_worker_mode == sighter::runtime::PhysicsWorkerMode::kThroughput
            ? sighter::runtime::CalculateThroughputWorkerCount(
                  physical_core_count)
            : physical_core_count;
    if (physics_worker_mode == sighter::runtime::PhysicsWorkerMode::kLatency) {
      std::cout << "  [runtime] physics worker mode=latency: Roblox-managed "
                   "worker pools, midphase batch=128\n";
    } else if (physics_worker_mode ==
               sighter::runtime::PhysicsWorkerMode::kThroughput) {
      std::cout << "  [runtime] physics worker mode=throughput: "
                << engine_worker_count << " scheduler workers, async minimum="
                << std::min(engine_worker_count, 3) << ", midphase batch=128\n";
    }
    if ((runtime_config.config.performance().multithreaded_rendering ||
         physics_worker_mode ==
             sighter::runtime::PhysicsWorkerMode::kThroughput) &&
        physics_worker_mode != sighter::runtime::PhysicsWorkerMode::kLatency) {
      std::cout << "  [runtime] full multithreaded engine queues enabled: "
                << engine_worker_count << " scheduler workers, "
                << std::max(1, engine_worker_count / 2)
                << " occlusion workers\n";
    } else if (runtime_config.config.performance().multithreaded_rendering &&
               physics_worker_mode ==
                   sighter::runtime::PhysicsWorkerMode::kLatency) {
      std::cout << "  [runtime] latency mode leaves scheduler/render worker "
                   "counts under Roblox client-settings control\n";
    }
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun &&
      runtime_config.config.frame_rate().mode ==
          sighter::runtime::FrameRateLimitMode::kUnlimited) {
    std::cout << "  [runtime] frame-rate mode=unlimited scheduler_target="
              << sighter::runtime::kMaximumSupportedRobloxSchedulerFps
              << " vsync=" << runtime_config.config.vsync_mode() << '\n';
  }

  const libc_shim::HostCaBundleResolution ca_bundle =
      libc_shim::ResolveHostCaBundle();
  if (ca_bundle.status == libc_shim::HostCaBundleStatus::kInvalidOverride) {
    std::cerr << "Invalid SIGHTER_CA_BUNDLE: expected a readable, non-empty "
                 "absolute regular file\n";
    return 2;
  }

  sighter::runtime::RobloxFullscreenRuntimeBridge fullscreen_bridge;
  sighter::audio::RobloxOutputDeviceBridge output_device_bridge;
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    const std::string compatibility_manifest =
        environment.GetOr("SIGHTER_COMPATIBILITY_MANIFEST",
                          SIGHTER_DEFAULT_COMPATIBILITY_MANIFEST);
    const sighter::compat::PayloadCompatibilityResult compatibility =
        sighter::compat::CheckPayloadCompatibility(
            runtime_config.config.roblox_library_path().string(),
            compatibility_manifest,
            command_line.options.allow_unverified_build);
    if (!compatibility) {
      std::cerr << "[FATAL] " << compatibility.error << '\n';
      return EXIT_FAILURE;
    }
    const sighter::Status fullscreen_status =
        fullscreen_bridge.Install(compatibility.profile);
    if (!fullscreen_status.ok()) {
      std::cerr << "[FATAL] Cannot install fullscreen runtime bridge: "
                << fullscreen_status.message() << '\n';
      return EXIT_FAILURE;
    }
    if (compatibility.profile.fmod_output_device_bridge &&
        compatibility.profile.fmod_output_device_bridge->has_input_devices()) {
      std::string menu_settings;
      const char *settings =
          std::getenv("SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON");
      if (!sighter::runtime::MergeAudioDeviceMenuClientSettingsOverrides(
              settings ? settings : "{}", &menu_settings,
              &command_line_error) ||
          setenv("SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON",
                 menu_settings.c_str(), 1) != 0) {
        std::cerr << "[FATAL] Cannot configure host audio device menu: "
                  << command_line_error << '\n';
        return EXIT_FAILURE;
      }
    }
    const sighter::Status output_device_status =
        output_device_bridge.Install(compatibility.profile);
    if (!output_device_status.ok()) {
      std::cerr << "[FATAL] Cannot install Roblox output-device bridge: "
                << output_device_status.message() << '\n';
      return EXIT_FAILURE;
    }
  }

  sighter::legacy::RuntimeDependencies dependencies;
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    auto http_client = std::make_shared<sighter::services::CurlHttpClient>();
    sighter::services::BrowserTrackerService browser_tracker(*http_client);
    std::filesystem::path tracker_cookie_file =
        paths.data_root() / "browser_tracker.cookie";
    bool tracker_cookie_owned = true;
    if (environment.HasNonEmpty("SIGHTER_COOKIE_FILE")) {
      tracker_cookie_file = environment.GetOr("SIGHTER_COOKIE_FILE", "");
      tracker_cookie_owned = false;
    } else if (sighter::runtime::RuntimePaths::Exists(paths.cookie_file())) {
      tracker_cookie_file = paths.cookie_file();
    }
    const sighter::services::BrowserTrackerResult browser_tracker_result =
        browser_tracker.EnsureInitialized(app_storage_file, tracker_cookie_file,
                                          tracker_cookie_owned);
    if (!browser_tracker_result) {
      std::cerr << "  [runtime] BrowserTracker bootstrap skipped: "
                << browser_tracker_result.error;
      if (browser_tracker_result.http_status != 0) {
        std::cerr << " (HTTP " << browser_tracker_result.http_status << ')';
      }
      std::cerr << '\n';
    } else {
      std::cout << "  [runtime] BrowserTracker identity "
                << (browser_tracker_result.status ==
                            sighter::services::BrowserTrackerStatus::kCreated
                        ? "initialized"
                        : "loaded")
                << " before engine startup\n";
    }
    sighter::services::AuthService auth_service(*http_client);
    sighter::runtime::AuthRuntimeComposition composition =
        sighter::runtime::ComposeAuthRuntime(environment, paths, auth_service,
                                              http_client);
    if (!external_launch_request.has_value() &&
        command_line.options.window_mode !=
            sighter::runtime::WindowMode::kHeadless) {
      PromptFirstLaunchSignIn(environment, paths, auth_service, http_client,
                              &composition);
    }
    if (!composition) {
      std::cerr << "[FATAL] Typed Roblox authentication preflight failed: "
                << composition.error;
      if (composition.http_status != 0) {
        std::cerr << " (HTTP " << composition.http_status << ')';
      }
      std::cerr << '\n';
      return EXIT_FAILURE;
    }
    composition.jni_vm->SetPlatformIdentity(jnivm::PlatformIdentity{
        runtime_config.config.input_capabilities().touch_enabled,
        runtime_config.config.input_capabilities().mouse_enabled,
        runtime_config.config.input_capabilities().keyboard_enabled,
        runtime_config.config.device_profile().pc_hardware,
        std::string(runtime_config.config.device_profile().platform_name),
        std::string(runtime_config.config.device_profile().display_name),
        std::string(runtime_config.config.device_profile().manufacturer),
        std::string(runtime_config.config.device_profile().model),
        std::string(runtime_config.config.device_profile().brand),
        std::string(runtime_config.config.device_profile().device_code),
        std::string(runtime_config.config.device_profile().device_sku),
        std::string(runtime_config.config.device_profile().soc_model),
    });
    if (composition.rejected_credential_retired) {
      constexpr std::string_view kSignedOutMessage =
          "Your saved Roblox session is no longer valid. Sign in again to "
          "continue.";
      std::cout << "  [auth] saved Roblox session expired; continuing with "
                   "native sign-in\n";
      (void)sighter::runtime::ShowWarningDialog(environment,
                                                 kSignedOutMessage);
    }
    if (composition.status ==
        sighter::runtime::AuthRuntimeStatus::kAuthenticated) {
      if (setenv("SIGHTER_NATIVE_SET_USER_ID", "1", 1) != 0) {
        std::cerr << "[FATAL] Cannot enable authenticated NativeSettings "
                     "identity\n";
        return EXIT_FAILURE;
      }
      std::cout
          << "  [auth] typed Roblox identity resolved for production VM\n";
    } else {
      std::cout
          << "  [auth] explicit guest identity selected for production VM\n";
    }
    if (runtime_config.config.desktop_playability()) {
      std::filesystem::path assets = paths.DefaultAssetPath();
      if (environment.HasNonEmpty("SIGHTER_ASSET_PATH")) {
        assets = environment.GetOr("SIGHTER_ASSET_PATH", "");
      }
      const std::filesystem::path default_app_policy =
          assets / "guac/defaultConfigs/GuacDefaultPolicy-GlobalDist.json";
      const std::int64_t app_policy_user_id =
          composition.status ==
                  sighter::runtime::AuthRuntimeStatus::kAuthenticated
              ? composition.account_identity.user_id
              : -1;
      const sighter::runtime::DesktopAppPolicyResult desktop_policy =
          sighter::runtime::ApplyDesktopAppPolicy(
              app_storage_file, default_app_policy, app_policy_user_id,
              runtime_config.config.theme_mode());
      if (!desktop_policy) {
        std::cerr << "[FATAL] Desktop Roblox app-policy failed: "
                  << desktop_policy.error << '\n';
        return EXIT_FAILURE;
      }
      std::string desktop_client_settings;
      if (!sighter::runtime::MergeDesktopAppPolicyClientSettingsOverride(
              desktop_policy.policy_json,
              environment.GetOr("SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON",
                                "{}"),
              &desktop_client_settings, &command_line_error)) {
        std::cerr << "[FATAL] Cannot activate desktop Roblox app-policy: "
                  << command_line_error << '\n';
        return EXIT_FAILURE;
      }
      if (setenv("SIGHTER_CLIENT_SETTINGS_OVERRIDES_JSON",
                 desktop_client_settings.c_str(), 1) != 0) {
        std::cerr << "[FATAL] Cannot export desktop Roblox app-policy\n";
        return EXIT_FAILURE;
      }
      std::cout << "  [runtime] desktop app-policy ready: normalized="
                << desktop_policy.normalized_policy_count
                << " updated=" << (desktop_policy.updated ? 1 : 0)
                << " runtime_override=1\n";
    }
    auto android_window_context =
        std::make_shared<AndroidWindowBridgeContext>();
    jnivm::AndroidWindowCallbacks android_window_callbacks;
    android_window_callbacks.set_flags = &QueueAndroidWindowFlags;
    composition.jni_vm->SetAndroidWindowCallbacks(
        std::move(android_window_context), android_window_callbacks);
    const sighter::Status audio_status =
        sighter::audio::InstallFmodJniAudioBridge(composition.jni_vm.get());
    if (!audio_status.ok()) {
      std::cerr << "[FATAL] Typed FMOD Java audio composition failed: "
                << audio_status.message() << '\n';
      return EXIT_FAILURE;
    }
    const sighter::Status voice_status =
        sighter::audio::InstallWebRtcJniAudioBridge(
            composition.jni_vm.get());
    if (!voice_status.ok()) {
      (void)sighter::audio::ShutdownFmodJniAudioBridge(
          composition.jni_vm.get());
      std::cerr << "[FATAL] WebRTC voice audio composition failed: "
                << voice_status.message() << '\n';
      return EXIT_FAILURE;
    }
    dependencies = sighter::legacy::RuntimeDependencies(
        std::move(composition), &ShutdownPlatformBridges);
  }
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun &&
      !isolated_canary) {
    // Listen only after re-exec, preflight, and bridge setup, so an ACK cannot
    // precede a known startup failure. Isolated canaries expose no endpoint.
    sighter::Status broker_status =
        sighter::runtime::ExternalLaunchBroker::StartOwnerAfterLockAcquired(
            broker_options, &external_launch_broker.broker(),
            external_launch_request.has_value() ? &*external_launch_request
                                                : nullptr);
    if (broker_status.ok()) external_launch_request.reset();
    if (broker_status.ok()) {
      broker_status = sighter::runtime::InstallActiveExternalLaunchBroker(
          external_launch_broker.broker());
    }
    if (!broker_status.ok()) {
      std::cerr << "[FATAL] Cannot activate website launch bridge: "
                << broker_status.message() << '\n';
      return EXIT_FAILURE;
    }
  }
  failure_dialog.SetMessage(
      "Roblox closed unexpectedly because of an internal error.");
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    sighter::runtime::LogProcessDiagnostics(
        sighter::runtime::ProcessDiagnosticStage::kNativeRuntime);
  }
  int runtime_status =
      sighter::legacy::Run(command_line.options, std::move(dependencies));
  if (command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    sighter::runtime::LogProcessDiagnostics(
        sighter::runtime::ProcessDiagnosticStage::kShutdown);
    std::cerr << "[diagnostic] native runtime exit_status=" << runtime_status
              << '\n';
  }
  const sighter::Status launch_broker_shutdown_status =
      external_launch_broker.Shutdown();
  if (!launch_broker_shutdown_status.ok()) {
    std::cerr << "  [launch] website bridge shutdown failed: "
              << launch_broker_shutdown_status.message() << '\n';
    runtime_status = EXIT_FAILURE;
  }
  if (runtime_status != EXIT_SUCCESS) {
    failure_dialog.SetMessage("Roblox stopped with error code " +
                              std::to_string(runtime_status) + ".");
  }
  support_bundle_guard.SetExitCode(runtime_status);
  output_device_bridge.Shutdown();
  fullscreen_bridge.Shutdown();
  memory_limit_watchdog.Stop();
  const sighter::Status game_mode_stop_status = game_mode_session.Stop();
  if (!game_mode_stop_status.ok()) {
    std::cerr << "  [gamemode] release failed: "
              << game_mode_stop_status.message() << '\n';
  }
  if (runtime_status == EXIT_SUCCESS &&
      command_line.options.mode == sighter::runtime::CommandMode::kRun) {
    failure_dialog.MarkSuccessful();
    support_bundle_guard.Disarm();
    // Guest atexit handlers target workers that cannot be joined. Host
    // shutdown is already complete here, so do not re-enter guest teardown.
    std::cout.flush();
    std::cerr.flush();
    std::_Exit(EXIT_SUCCESS);
  }
  if (runtime_status == EXIT_SUCCESS) {
    failure_dialog.MarkSuccessful();
    support_bundle_guard.Disarm();
  }
  return runtime_status;
}
