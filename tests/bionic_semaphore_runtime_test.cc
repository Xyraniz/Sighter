#include "compat/bionic_semaphore_runtime.h"

#include <gtest/gtest.h>

#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <thread>

namespace {

TEST(BionicSemaphoreRuntimeTest, WaiterReleasedByPost) {
  alignas(sem_t) std::array<unsigned char, sizeof(sem_t)> guest_storage{};
  auto* semaphore = reinterpret_cast<sem_t*>(guest_storage.data());

  ASSERT_EQ(sighter_bionic_sem_init(semaphore, 0, 0), 0);
  std::atomic<bool> released{false};
  std::thread waiter([&] {
    EXPECT_EQ(sighter_bionic_sem_wait(semaphore), 0);
    released.store(true, std::memory_order_release);
  });

  EXPECT_FALSE(released.load(std::memory_order_acquire));
  EXPECT_EQ(sighter_bionic_sem_post(semaphore), 0);
  waiter.join();
  EXPECT_TRUE(released.load(std::memory_order_acquire));
  EXPECT_EQ(sighter_bionic_sem_destroy(semaphore), 0);
}

TEST(BionicSemaphoreRuntimeTest, SemPostWakesRawGuestFutexWait) {
  sem_t guest_storage{};
  ASSERT_EQ(sighter_bionic_sem_init(&guest_storage, 0, 0), 0);

  std::atomic<bool> waiting{false};
  std::atomic<int> wait_result{EINVAL};
  std::thread waiter([&] {
    waiting.store(true, std::memory_order_release);
    EXPECT_EQ(sighter_bionic_sem_wait(&guest_storage), 0);
    wait_result.store(0, std::memory_order_release);
  });
  while (!waiting.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(20));

  auto* count = reinterpret_cast<unsigned*>(&guest_storage);
  const unsigned expected = __atomic_load_n(count, __ATOMIC_RELAXED);
  std::atomic<int> raw_result{EINVAL};
  std::thread raw([&] {
    raw_result.store(
        static_cast<int>(::syscall(SYS_futex, count, FUTEX_WAIT_PRIVATE,
                                   expected, nullptr, nullptr, 0)),
        std::memory_order_release);
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  EXPECT_EQ(sighter_bionic_sem_post(&guest_storage), 0);
  waiter.join();
  raw.join();
  EXPECT_EQ(0, wait_result.load(std::memory_order_acquire));
  EXPECT_EQ(0, raw_result.load(std::memory_order_acquire));
  EXPECT_EQ(sighter_bionic_sem_destroy(&guest_storage), 0);
}

TEST(BionicSemaphoreRuntimeTest, RejectsProcessSharedSemaphore) {
  sem_t guest_storage{};
  errno = 0;
  EXPECT_EQ(sighter_bionic_sem_init(&guest_storage, 1, 0), -1);
  EXPECT_EQ(errno, EINVAL);
}

}  // namespace
