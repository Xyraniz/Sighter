#include "window/input_pump_pacer.h"

#include <gtest/gtest.h>

namespace sighter {
namespace window {
namespace {

TEST(InputPumpPacerTest, FirstTickAndMissedDeadlineDoNotSleep) {
  constexpr uint64_t kInterval = 4000000;
  InputPumpPacer pacer(kInterval);

  EXPECT_EQ(pacer.DelayBeforeNextPump(1000000), 0U);
  EXPECT_EQ(pacer.DelayBeforeNextPump(2000000), kInterval - 1000000);
}

TEST(InputPumpPacerTest, OnTimeRemainderSleepsOnlyUntilNextSlot) {
  constexpr uint64_t kInterval = 4000000;
  InputPumpPacer pacer(kInterval);

  EXPECT_EQ(pacer.DelayBeforeNextPump(1000000), 0U);
  EXPECT_EQ(pacer.DelayBeforeNextPump(2000000), kInterval - 1000000);
  EXPECT_EQ(pacer.DelayBeforeNextPump(6500000), kInterval - 1500000);
}

TEST(InputPumpPacerTest, ExactDeadlineDoesNotInsertAnotherFrameDelay) {
  constexpr uint64_t kInterval = 4000000;
  InputPumpPacer pacer(kInterval);

  EXPECT_EQ(pacer.DelayBeforeNextPump(1000000), 0U);
  EXPECT_EQ(pacer.DelayBeforeNextPump(5000000), 0U);
  EXPECT_EQ(pacer.DelayBeforeNextPump(5000000), kInterval);
}

TEST(InputPumpPacerTest, MissedDeadlineRebasesWithoutSleeping) {
  constexpr uint64_t kInterval = 4000000;
  InputPumpPacer pacer(kInterval);

  EXPECT_EQ(pacer.DelayBeforeNextPump(1000000), 0U);
  EXPECT_EQ(pacer.DelayBeforeNextPump(12000000), 0U);
  EXPECT_EQ(pacer.DelayBeforeNextPump(13000000), kInterval - 1000000);
}

TEST(InputPumpPacerTest, ConsecutiveLateTicksDoNotStackSleep) {
  constexpr uint64_t kInterval = 4000000;
  InputPumpPacer pacer(kInterval);

  EXPECT_EQ(pacer.DelayBeforeNextPump(1000000), 0U);
  EXPECT_EQ(pacer.DelayBeforeNextPump(12000000), 0U);
  EXPECT_EQ(pacer.DelayBeforeNextPump(20000000), 0U);
}

TEST(InputPumpPacerTest, ResetStartsAFreshCadence) {
  constexpr uint64_t kInterval = 4000000;
  InputPumpPacer pacer(kInterval);

  EXPECT_EQ(pacer.DelayBeforeNextPump(1000000), 0U);
  pacer.Reset();
  EXPECT_EQ(pacer.DelayBeforeNextPump(100000000), 0U);
  EXPECT_EQ(pacer.DelayBeforeNextPump(101000000), kInterval - 1000000);
}

}  // namespace
}  // namespace window
}  // namespace sighter
