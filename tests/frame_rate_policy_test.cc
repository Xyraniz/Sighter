#include "runtime/frame_rate_policy.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <string>

namespace sighter {
namespace runtime {
namespace {

TEST(FrameRatePolicyTest, ParsesSupportedModes) {
  EXPECT_EQ(ParseFrameRatePolicy("").mode,
            FrameRateLimitMode::kUnmanaged);
  EXPECT_EQ(ParseFrameRatePolicy("-1").mode,
            FrameRateLimitMode::kUnmanaged);
  EXPECT_EQ(ParseFrameRatePolicy("display").mode, FrameRateLimitMode::kDisplay);
  EXPECT_EQ(ParseFrameRatePolicy("10").fixed_fps, 10);
  EXPECT_EQ(ParseFrameRatePolicy("70").fixed_fps, 70);
  EXPECT_EQ(ParseFrameRatePolicy("144").fixed_fps, 144);
  EXPECT_EQ(ParseFrameRatePolicy("unlimited").mode,
            FrameRateLimitMode::kUnlimited);
  EXPECT_EQ(ParseFrameRatePolicy("999").fixed_fps, 999);
  EXPECT_FALSE(ParseFrameRatePolicy("0").valid());
  EXPECT_FALSE(ParseFrameRatePolicy("-10").valid());
  EXPECT_FALSE(ParseFrameRatePolicy("10fps").valid());
  EXPECT_FALSE(ParseFrameRatePolicy("10 ").valid());
}

TEST(FrameRatePolicyTest, UnmanagedOnlyEnablesRobloxBasicSettingsCap) {
  std::string merged;
  std::string error;
  ASSERT_TRUE(MergeFrameRateClientSettingsOverrides(
      ParseFrameRatePolicy("-1"),
      R"({"FStringGraphicsVulkanShaderMTDenyPattern":"4318:.*"})", &merged,
      &error))
      << error;
  const nlohmann::json parsed =
      nlohmann::json::parse(merged, nullptr, false, true);
  ASSERT_TRUE(parsed.is_object());
  EXPECT_EQ(parsed.at("FFlagGameBasicSettingsFramerateCap5"), "True");
  EXPECT_FALSE(parsed.contains("DFIntTaskSchedulerTargetFps"));
  EXPECT_FALSE(parsed.contains("FFlagTaskSchedulerLimitTargetFpsTo2402"));
  EXPECT_EQ(parsed.at("FStringGraphicsVulkanShaderMTDenyPattern"), "4318:.*");
}

TEST(FrameRatePolicyTest, MergesArbitraryFixedValueIntoSchedulerFflag) {
  std::string merged;
  std::string error;
  ASSERT_TRUE(MergeFrameRateClientSettingsOverrides(
      ParseFrameRatePolicy("10"), "{}", &merged, &error));
  EXPECT_NE(merged.find("\"DFIntTaskSchedulerTargetFps\":\"10\""),
            std::string::npos);
  EXPECT_NE(merged.find("\"FFlagGameBasicSettingsFramerateCap5\":\"True\""),
            std::string::npos);
}

TEST(FrameRatePolicyTest, MergesUnlimitedWithoutLosingGraphicsPolicy) {
  std::string merged;
  std::string error;
  ASSERT_TRUE(MergeFrameRateClientSettingsOverrides(
      ParseFrameRatePolicy("unlimited"),
      R"({"FStringGraphicsVulkanShaderMTDenyPattern":"4318:.*"})", &merged,
      &error));
  EXPECT_NE(merged.find("DFIntTaskSchedulerTargetFps\":\"240"),
            std::string::npos);
  EXPECT_EQ(merged.find("DFIntTaskSchedulerTargetFps\":\"0"),
            std::string::npos);
  EXPECT_EQ(merged.find("FFlagTaskSchedulerLimitTargetFpsTo2402"),
            std::string::npos);
  EXPECT_NE(merged.find("FStringGraphicsVulkanShaderMTDenyPattern"),
            std::string::npos);
}

TEST(FrameRatePolicyTest, RejectsMalformedAndConflictingOverrides) {
  std::string merged;
  std::string error;
  EXPECT_FALSE(MergeFrameRateClientSettingsOverrides(
      ParseFrameRatePolicy("120"), "not-json", &merged, &error));
  EXPECT_FALSE(MergeFrameRateClientSettingsOverrides(
      ParseFrameRatePolicy("120"), R"({"DFIntTaskSchedulerTargetFps":"60"})",
      &merged, &error));
}

} // namespace
} // namespace runtime
} // namespace sighter
