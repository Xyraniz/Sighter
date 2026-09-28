#ifndef SIGHTER_UPDATE_CANDIDATE_APPROVAL_H_
#define SIGHTER_UPDATE_CANDIDATE_APPROVAL_H_

#include <array>
#include <filesystem>
#include <string>
#include <string_view>

#include "update/payload_integrity.h"

namespace sighter::update {

struct CandidateApprovalOptions {
  std::filesystem::path store_root;
  std::filesystem::path payload_directory;
  std::filesystem::path profile;
  std::filesystem::path compatibility_manifest;
  std::filesystem::path runtime_binary;
  std::array<std::filesystem::path, 2> canary_logs;
};

struct CandidateApprovalResult {
  std::string generation;
  std::filesystem::path profile;
  std::filesystem::path compatibility_manifest;
  std::filesystem::path receipt;
  std::string error;

  explicit operator bool() const {
    return error.empty() && !generation.empty();
  }
};

CandidateApprovalResult CreateCandidateApproval(
    const CandidateApprovalOptions& options,
    const PayloadIntegrityResult& verified_payload);

bool ValidateCandidateApproval(const std::filesystem::path& store_root,
                               std::string_view activation_json,
                               const PayloadIntegrityResult& payload,
                               CandidateApprovalResult* approval,
                               std::string* error);

std::string PayloadRuntimeFingerprint(
    const std::filesystem::path& payload_directory,
    const PayloadIntegrityResult& payload, std::string* error);

}  // namespace sighter::update

#endif  // SIGHTER_UPDATE_CANDIDATE_APPROVAL_H_
