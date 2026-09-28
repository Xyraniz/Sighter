#include "compat/bionic_rwlock_runtime.h"

#include <gtest/gtest.h>

#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <thread>

namespace {

TEST(BionicRwlockRuntimeTest, SerializesGuestReadersAndWriter) {
  pthread_rwlock_t guest_storage{};
  ASSERT_EQ(sighter_bionic_pthread_rwlock_init(&guest_storage, nullptr), 0);
  ASSERT_EQ(sighter_bionic_pthread_rwlock_rdlock(&guest_storage), 0);

  std::atomic<bool> writer_entered{false};
  std::thread writer([&] {
    EXPECT_EQ(sighter_bionic_pthread_rwlock_wrlock(&guest_storage), 0);
    writer_entered.store(true, std::memory_order_release);
    EXPECT_EQ(sighter_bionic_pthread_rwlock_unlock(&guest_storage), 0);
  });

  EXPECT_FALSE(writer_entered.load(std::memory_order_acquire));
  EXPECT_EQ(sighter_bionic_pthread_rwlock_unlock(&guest_storage), 0);
  writer.join();
  EXPECT_TRUE(writer_entered.load(std::memory_order_acquire));
  EXPECT_EQ(sighter_bionic_pthread_rwlock_destroy(&guest_storage), 0);
}

TEST(BionicRwlockRuntimeTest, UnlockWakesRawGuestFutexWait) {
  pthread_rwlock_t guest_storage{};
  ASSERT_EQ(sighter_bionic_pthread_rwlock_init(&guest_storage, nullptr), 0);
  ASSERT_EQ(sighter_bionic_pthread_rwlock_rdlock(&guest_storage), 0);

  auto* state = reinterpret_cast<int*>(&guest_storage);
  std::atomic<bool> waiting{false};
  std::atomic<int> wait_result{EINVAL};
  std::thread waiter([&] {
    const int old_state = __atomic_load_n(state, __ATOMIC_RELAXED);
    waiting.store(true, std::memory_order_release);
    wait_result.store(
        static_cast<int>(::syscall(SYS_futex, state, FUTEX_WAIT_PRIVATE,
                                   old_state, nullptr, nullptr, 0)),
        std::memory_order_release);
  });
  while (!waiting.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  EXPECT_EQ(sighter_bionic_pthread_rwlock_unlock(&guest_storage), 0);
  waiter.join();
  EXPECT_EQ(0, wait_result.load(std::memory_order_acquire));
  EXPECT_EQ(sighter_bionic_pthread_rwlock_destroy(&guest_storage), 0);
}

TEST(BionicRwlockRuntimeTest, SupportsZeroInitializedGuestLock) {
  pthread_rwlock_t guest_storage{};
  EXPECT_EQ(sighter_bionic_pthread_rwlock_wrlock(&guest_storage), 0);
  EXPECT_EQ(sighter_bionic_pthread_rwlock_unlock(&guest_storage), 0);
  EXPECT_EQ(sighter_bionic_pthread_rwlock_destroy(&guest_storage), 0);
}

}  // namespace
