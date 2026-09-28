// Copyright 2026 Sighter Project Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#include <sys/eventfd.h>
#include <unistd.h>

#include <gtest/gtest.h>

struct ALooper;

using ALooperCallback = int (*)(int, int, void*);

extern "C" {
ALooper* ALooper_forThread();
ALooper* ALooper_prepare(int opts);
void ALooper_acquire(ALooper* looper);
void ALooper_release(ALooper* looper);
int ALooper_addFd(ALooper* looper, int fd, int ident, int events,
                  ALooperCallback callback, void* data);
int ALooper_removeFd(ALooper* looper, int fd);
int ALooper_pollOnce(int timeout_ms, int* out_fd, int* out_events,
                     void** out_data);
int ALooper_pollAll(int timeout_ms, int* out_fd, int* out_events,
                    void** out_data);
void ALooper_wake(ALooper* looper);
}

namespace {

constexpr int kPrepareAllowNonCallbacks = 1 << 0;
constexpr int kEventInput = 1 << 0;
constexpr int kPollWake = -1;
constexpr int kPollCallback = -2;
constexpr int kPollTimeout = -3;
constexpr int kPollError = -4;

class ScopedFd {
 public:
  explicit ScopedFd(int fd = -1) : fd_(fd) {}
  ~ScopedFd() {
    if (fd_ >= 0) close(fd_);
  }

  ScopedFd(const ScopedFd&) = delete;
  ScopedFd& operator=(const ScopedFd&) = delete;

  ScopedFd(ScopedFd&& other) noexcept : fd_(other.release()) {}
  ScopedFd& operator=(ScopedFd&& other) noexcept {
    if (this != &other) {
      if (fd_ >= 0) close(fd_);
      fd_ = other.release();
    }
    return *this;
  }

  int get() const { return fd_; }
  int release() {
    const int fd = fd_;
    fd_ = -1;
    return fd;
  }

 private:
  int fd_;
};

ScopedFd MakeEventFd() {
  return ScopedFd(eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC));
}

bool SignalEventFd(int fd) {
  const uint64_t value = 1;
  return write(fd, &value, sizeof(value)) == sizeof(value);
}

bool DrainEventFd(int fd) {
  uint64_t value = 0;
  return read(fd, &value, sizeof(value)) == sizeof(value);
}

int KeepCallback(int, int, void*) { return 1; }

struct CountingCallbackState {
  std::atomic<int>* calls;
  bool remove;
};

int CountingCallback(int fd, int events, void* data) {
  auto* state = static_cast<CountingCallbackState*>(data);
  if ((events & kEventInput) != 0 && DrainEventFd(fd)) {
    state->calls->fetch_add(1, std::memory_order_relaxed);
  }
  return state->remove ? 0 : 1;
}

TEST(AndroidLooperTest, ForThreadIsNullUntilPrepareAndOptionsAreSticky) {
  std::thread thread([] {
    EXPECT_EQ(ALooper_forThread(), nullptr);

    int out_fd = 91;
    int out_events = 92;
    void* out_data = reinterpret_cast<void*>(0x1234);
    EXPECT_EQ(ALooper_pollOnce(0, &out_fd, &out_events, &out_data),
              kPollError);
    EXPECT_EQ(out_fd, 0);
    EXPECT_EQ(out_events, 0);
    EXPECT_EQ(out_data, nullptr);

    ALooper* looper = ALooper_prepare(0);
    ASSERT_NE(looper, nullptr);
    EXPECT_EQ(ALooper_forThread(), looper);
    EXPECT_EQ(ALooper_prepare(kPrepareAllowNonCallbacks), looper);

    ScopedFd fd = MakeEventFd();
    ASSERT_GE(fd.get(), 0);
    EXPECT_EQ(ALooper_addFd(looper, fd.get(), 7, kEventInput, nullptr,
                            nullptr),
              -1);
    EXPECT_EQ(ALooper_addFd(looper, fd.get(), kPollWake, kEventInput,
                            KeepCallback, nullptr),
              -1);
    EXPECT_EQ(ALooper_addFd(looper, fd.get(), kPollCallback, kEventInput,
                            KeepCallback, nullptr),
              1);
    EXPECT_EQ(ALooper_removeFd(looper, fd.get()), 1);
    EXPECT_EQ(ALooper_removeFd(looper, fd.get()), 0);
  });
  thread.join();
}

TEST(AndroidLooperTest, NonCallbackRegistrationReturnsIdentifierAndPayload) {
  std::thread thread([] {
    ALooper* looper = ALooper_prepare(kPrepareAllowNonCallbacks);
    ASSERT_NE(looper, nullptr);
    ScopedFd fd = MakeEventFd();
    ASSERT_GE(fd.get(), 0);
    int marker = 17;

    EXPECT_EQ(ALooper_addFd(looper, fd.get(), kPollCallback, kEventInput,
                            nullptr, &marker),
              -1);
    ASSERT_EQ(ALooper_addFd(looper, fd.get(), 42, kEventInput, nullptr,
                            &marker),
              1);
    ASSERT_TRUE(SignalEventFd(fd.get()));

    int out_fd = -1;
    int out_events = -1;
    void* out_data = nullptr;
    EXPECT_EQ(ALooper_pollOnce(1000, &out_fd, &out_events, &out_data), 42);
    EXPECT_EQ(out_fd, fd.get());
    EXPECT_NE(out_events & kEventInput, 0);
    EXPECT_EQ(out_data, &marker);
    EXPECT_TRUE(DrainEventFd(fd.get()));

    EXPECT_EQ(ALooper_removeFd(looper, fd.get()), 1);
    EXPECT_EQ(ALooper_removeFd(looper, fd.get()), 0);
    EXPECT_EQ(ALooper_removeFd(looper, -1), -1);
    EXPECT_EQ(ALooper_removeFd(nullptr, fd.get()), -1);
    EXPECT_EQ(ALooper_addFd(nullptr, fd.get(), 1, kEventInput, nullptr,
                            nullptr),
              -1);
  });
  thread.join();
}

TEST(AndroidLooperTest, ClearsOutputsForTimeoutWakeAndCallback) {
  std::thread thread([] {
    ALooper* looper = ALooper_prepare(kPrepareAllowNonCallbacks);
    ASSERT_NE(looper, nullptr);

    int out_fd = 1;
    int out_events = 2;
    void* out_data = reinterpret_cast<void*>(0x1234);
    EXPECT_EQ(ALooper_pollOnce(0, &out_fd, &out_events, &out_data),
              kPollTimeout);
    EXPECT_EQ(out_fd, 0);
    EXPECT_EQ(out_events, 0);
    EXPECT_EQ(out_data, nullptr);

    out_fd = 1;
    out_events = 2;
    out_data = reinterpret_cast<void*>(0x1234);
    ALooper_wake(looper);
    EXPECT_EQ(ALooper_pollOnce(1000, &out_fd, &out_events, &out_data),
              kPollWake);
    EXPECT_EQ(out_fd, 0);
    EXPECT_EQ(out_events, 0);
    EXPECT_EQ(out_data, nullptr);

    ScopedFd fd = MakeEventFd();
    ASSERT_GE(fd.get(), 0);
    std::atomic<int> calls{0};
    CountingCallbackState state{&calls, true};
    ASSERT_EQ(ALooper_addFd(looper, fd.get(), kPollCallback, kEventInput,
                            CountingCallback, &state),
              1);
    ASSERT_TRUE(SignalEventFd(fd.get()));
    out_fd = 1;
    out_events = 2;
    out_data = reinterpret_cast<void*>(0x1234);
    EXPECT_EQ(ALooper_pollOnce(1000, &out_fd, &out_events, &out_data),
              kPollCallback);
    EXPECT_EQ(calls.load(std::memory_order_relaxed), 1);
    EXPECT_EQ(out_fd, 0);
    EXPECT_EQ(out_events, 0);
    EXPECT_EQ(out_data, nullptr);
  });
  thread.join();
}

TEST(AndroidLooperTest, InvokesEveryCallbackInBatchBeforeReturningIdent) {
  std::thread thread([] {
    ALooper* looper = ALooper_prepare(kPrepareAllowNonCallbacks);
    ASSERT_NE(looper, nullptr);

    constexpr int kCallbackCount = 6;
    std::atomic<int> calls{0};
    std::vector<ScopedFd> callback_fds;
    std::vector<CountingCallbackState> states;
    callback_fds.reserve(kCallbackCount);
    states.reserve(kCallbackCount);
    for (int i = 0; i < kCallbackCount; ++i) {
      callback_fds.push_back(MakeEventFd());
      ASSERT_GE(callback_fds.back().get(), 0);
      states.push_back({&calls, true});
      ASSERT_EQ(ALooper_addFd(looper, callback_fds.back().get(),
                              kPollCallback, kEventInput, CountingCallback,
                              &states.back()),
                1);
    }

    ScopedFd identified_fd = MakeEventFd();
    ASSERT_GE(identified_fd.get(), 0);
    int marker = 99;
    ASSERT_EQ(ALooper_addFd(looper, identified_fd.get(), 777, kEventInput,
                            nullptr, &marker),
              1);

    for (const ScopedFd& fd : callback_fds) {
      ASSERT_TRUE(SignalEventFd(fd.get()));
    }
    ASSERT_TRUE(SignalEventFd(identified_fd.get()));

    int out_fd = 0;
    int out_events = 0;
    void* out_data = nullptr;
    EXPECT_EQ(ALooper_pollOnce(1000, &out_fd, &out_events, &out_data), 777);
    EXPECT_EQ(calls.load(std::memory_order_relaxed), kCallbackCount);
    EXPECT_EQ(out_fd, identified_fd.get());
    EXPECT_EQ(out_data, &marker);
    EXPECT_TRUE(DrainEventFd(identified_fd.get()));
    EXPECT_EQ(ALooper_removeFd(looper, identified_fd.get()), 1);
    for (const ScopedFd& fd : callback_fds) {
      EXPECT_EQ(ALooper_removeFd(looper, fd.get()), 0);
    }
  });
  thread.join();
}

TEST(AndroidLooperTest, SupportsMoreThanThirtyTwoRegistrations) {
  std::thread thread([] {
    ALooper* looper = ALooper_prepare(kPrepareAllowNonCallbacks);
    ASSERT_NE(looper, nullptr);
    constexpr int kFdCount = 48;
    std::vector<ScopedFd> fds;
    fds.reserve(kFdCount);
    for (int i = 0; i < kFdCount; ++i) {
      fds.push_back(MakeEventFd());
      ASSERT_GE(fds.back().get(), 0);
      ASSERT_EQ(ALooper_addFd(looper, fds.back().get(), 1000 + i,
                              kEventInput, nullptr, nullptr),
                1);
    }

    ASSERT_TRUE(SignalEventFd(fds.back().get()));
    EXPECT_EQ(ALooper_pollOnce(1000, nullptr, nullptr, nullptr),
              1000 + kFdCount - 1);
    EXPECT_TRUE(DrainEventFd(fds.back().get()));
    for (const ScopedFd& fd : fds) {
      EXPECT_EQ(ALooper_removeFd(looper, fd.get()), 1);
    }
  });
  thread.join();
}

TEST(AndroidLooperTest, PollAllConsumesCallbacksButReturnsWake) {
  std::thread thread([] {
    ALooper* looper = ALooper_prepare(kPrepareAllowNonCallbacks);
    ASSERT_NE(looper, nullptr);
    ScopedFd fd = MakeEventFd();
    ASSERT_GE(fd.get(), 0);
    std::atomic<int> calls{0};
    CountingCallbackState state{&calls, true};
    ASSERT_EQ(ALooper_addFd(looper, fd.get(), kPollCallback, kEventInput,
                            CountingCallback, &state),
              1);
    ASSERT_TRUE(SignalEventFd(fd.get()));

    EXPECT_EQ(ALooper_pollAll(1000, nullptr, nullptr, nullptr), kPollTimeout);
    EXPECT_EQ(calls.load(std::memory_order_relaxed), 1);

    ALooper_wake(looper);
    EXPECT_EQ(ALooper_pollAll(1000, nullptr, nullptr, nullptr), kPollWake);
  });
  thread.join();
}

struct AbaCallbackState {
  ALooper* looper = nullptr;
  int target_fd = -1;
  int replacement_source_fd = -1;
  int remove_result = -99;
  int dup_result = -99;
  int add_result = -99;
  bool signal_result = false;
};

int ReplaceReadyRegistration(int fd, int, void* data) {
  auto* state = static_cast<AbaCallbackState*>(data);
  (void)DrainEventFd(fd);
  state->remove_result = ALooper_removeFd(state->looper, state->target_fd);
  close(state->target_fd);
  state->dup_result =
      dup2(state->replacement_source_fd, state->target_fd);
  if (state->dup_result >= 0) {
    state->add_result = ALooper_addFd(state->looper, state->target_fd, 22,
                                      kEventInput, nullptr, state);
    state->signal_result = SignalEventFd(state->target_fd);
  }
  return 0;
}

TEST(AndroidLooperTest, RejectsStaleReadyEventAfterDescriptorReuse) {
  std::thread thread([] {
    ALooper* looper = ALooper_prepare(kPrepareAllowNonCallbacks);
    ASSERT_NE(looper, nullptr);
    ScopedFd trigger = MakeEventFd();
    ScopedFd old_target = MakeEventFd();
    ScopedFd replacement_source = MakeEventFd();
    ASSERT_GE(trigger.get(), 0);
    ASSERT_GE(old_target.get(), 0);
    ASSERT_GE(replacement_source.get(), 0);

    AbaCallbackState state;
    state.looper = looper;
    state.target_fd = old_target.release();
    state.replacement_source_fd = replacement_source.get();
    ASSERT_EQ(ALooper_addFd(looper, trigger.get(), kPollCallback, kEventInput,
                            ReplaceReadyRegistration, &state),
              1);
    ASSERT_EQ(ALooper_addFd(looper, state.target_fd, 11, kEventInput, nullptr,
                            nullptr),
              1);
    ASSERT_TRUE(SignalEventFd(trigger.get()));
    ASSERT_TRUE(SignalEventFd(state.target_fd));

    EXPECT_EQ(ALooper_pollOnce(1000, nullptr, nullptr, nullptr),
              kPollCallback);
    EXPECT_EQ(state.remove_result, 1);
    EXPECT_EQ(state.dup_result, state.target_fd);
    EXPECT_EQ(state.add_result, 1);
    EXPECT_TRUE(state.signal_result);

    int returned_fd = -1;
    EXPECT_EQ(ALooper_pollOnce(1000, &returned_fd, nullptr, nullptr), 22);
    EXPECT_EQ(returned_fd, state.target_fd);
    EXPECT_TRUE(DrainEventFd(state.target_fd));
    EXPECT_EQ(ALooper_removeFd(looper, state.target_fd), 1);
    close(state.target_fd);
  });
  thread.join();
}

TEST(AndroidLooperTest, AcquiredLooperSurvivesOwnerAndCrossThreadOperations) {
  struct SharedState {
    std::mutex mutex;
    std::condition_variable cv;
    ALooper* looper = nullptr;
    bool published = false;
    bool first_poll_done = false;
    bool continue_polling = false;
    int first_result = kPollError;
    int second_result = kPollError;
  } state;

  std::thread owner([&state] {
    ALooper* looper = ALooper_prepare(kPrepareAllowNonCallbacks);
    ASSERT_NE(looper, nullptr);
    ALooper_acquire(looper);
    {
      std::lock_guard lock(state.mutex);
      state.looper = looper;
      state.published = true;
    }
    state.cv.notify_all();

    state.first_result = ALooper_pollOnce(2000, nullptr, nullptr, nullptr);
    {
      std::unique_lock lock(state.mutex);
      state.first_poll_done = true;
      state.cv.notify_all();
      state.cv.wait(lock, [&state] { return state.continue_polling; });
    }
    state.second_result = ALooper_pollOnce(0, nullptr, nullptr, nullptr);
  });

  ALooper* shared_looper = nullptr;
  {
    std::unique_lock lock(state.mutex);
    state.cv.wait(lock, [&state] { return state.published; });
    shared_looper = state.looper;
  }
  ASSERT_NE(shared_looper, nullptr);

  ScopedFd fd = MakeEventFd();
  ASSERT_GE(fd.get(), 0);
  EXPECT_EQ(ALooper_addFd(shared_looper, fd.get(), 314, kEventInput, nullptr,
                          nullptr),
            1);
  EXPECT_TRUE(SignalEventFd(fd.get()));
  {
    std::unique_lock lock(state.mutex);
    state.cv.wait(lock, [&state] { return state.first_poll_done; });
  }
  EXPECT_EQ(state.first_result, 314);
  EXPECT_TRUE(DrainEventFd(fd.get()));
  EXPECT_EQ(ALooper_removeFd(shared_looper, fd.get()), 1);
  ALooper_wake(shared_looper);
  {
    std::lock_guard lock(state.mutex);
    state.continue_polling = true;
  }
  state.cv.notify_all();
  owner.join();
  EXPECT_EQ(state.second_result, kPollWake);

  // The associated thread has exited; the explicitly acquired reference still
  // owns the looper and permits cross-thread management until release.
  ScopedFd after_exit = MakeEventFd();
  ASSERT_GE(after_exit.get(), 0);
  EXPECT_EQ(ALooper_addFd(shared_looper, after_exit.get(), 2718, kEventInput,
                          nullptr, nullptr),
            1);
  EXPECT_EQ(ALooper_removeFd(shared_looper, after_exit.get()), 1);
  ALooper_release(shared_looper);
}

}  // namespace
