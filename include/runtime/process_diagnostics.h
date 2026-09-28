#ifndef SIGHTER_RUNTIME_PROCESS_DIAGNOSTICS_H_
#define SIGHTER_RUNTIME_PROCESS_DIAGNOSTICS_H_

namespace sighter::runtime {

enum class ProcessDiagnosticStage { kStartup, kNativeRuntime, kShutdown };

// Installs a diagnostic handler only if SIGXCPU still has its default action.
// The handler logs to stderr and re-delivers SIGXCPU with the default action.
void InstallCpuLimitDiagnostics();
void LogProcessDiagnostics(ProcessDiagnosticStage stage);

}  // namespace sighter::runtime

#endif  // SIGHTER_RUNTIME_PROCESS_DIAGNOSTICS_H_
