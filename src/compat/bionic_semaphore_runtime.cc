#include "compat/bionic_semaphore_runtime.h"

#include <errno.h>
#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <climits>
#include <cstdint>

namespace {

// Bionic encodes the signed count in bits 31:1 and a process-shared flag in
// bit 0. Waiters park while the count is -1 (all value bits set, shared=0).
constexpr unsigned kSemValueMask = 0xfffffffeu;
constexpr unsigned kSemValueShift = 1u;
constexpr unsigned kSemOne = 1u << kSemValueShift;
constexpr unsigned kSemMinusOne = kSemValueMask;

unsigned* SemCount(sem_t* semaphore) {
  return reinterpret_cast<unsigned*>(semaphore);
}

int SemValue(unsigned encoded) {
  return static_cast<int>(encoded) >> static_cast<int>(kSemValueShift);
}

unsigned SemEncode(unsigned value) {
  return (value << kSemValueShift) & kSemValueMask;
}

int SemFutex(unsigned* count, int op, unsigned val) {
  return static_cast<int>(
      ::syscall(SYS_futex, count, op | FUTEX_PRIVATE_FLAG, val, nullptr,
                nullptr, 0));
}

int SemDec(unsigned* count) {
  unsigned old_value = __atomic_load_n(count, __ATOMIC_RELAXED);
  do {
    if (SemValue(old_value) < 0) {
      break;
    }
  } while (!__atomic_compare_exchange_n(
      count, &old_value, (old_value - kSemOne) & kSemValueMask, true,
      __ATOMIC_SEQ_CST, __ATOMIC_RELAXED));
  return SemValue(old_value);
}

int SemInc(unsigned* count) {
  unsigned old_value = __atomic_load_n(count, __ATOMIC_RELAXED);
  unsigned new_value = 0;
  do {
    const int value = SemValue(old_value);
    if (value == SEM_VALUE_MAX) {
      break;
    }
    if (value < 0) {
      new_value = kSemOne;
    } else {
      new_value = (old_value + kSemOne) & kSemValueMask;
    }
  } while (!__atomic_compare_exchange_n(count, &old_value, new_value, true,
                                        __ATOMIC_SEQ_CST, __ATOMIC_RELAXED));
  return SemValue(old_value);
}

}  // namespace

extern "C" {

int sighter_bionic_sem_init(sem_t* semaphore, int process_shared,
                             unsigned int value) {
  if (semaphore == nullptr || process_shared != 0) {
    errno = EINVAL;
    return -1;
  }
  if (value > static_cast<unsigned>(SEM_VALUE_MAX)) {
    errno = EINVAL;
    return -1;
  }
  __atomic_store_n(SemCount(semaphore), SemEncode(value), __ATOMIC_RELAXED);
  return 0;
}

int sighter_bionic_sem_destroy(sem_t* semaphore) {
  if (semaphore == nullptr) {
    errno = EINVAL;
    return -1;
  }
  return 0;
}

int sighter_bionic_sem_wait(sem_t* semaphore) {
  if (semaphore == nullptr) {
    errno = EINVAL;
    return -1;
  }
  unsigned* count = SemCount(semaphore);
  for (;;) {
    if (SemDec(count) > 0) {
      return 0;
    }
    const int rc = SemFutex(count, FUTEX_WAIT, kSemMinusOne);
    if (rc != 0 && errno == EINTR) {
      continue;
    }
  }
}

int sighter_bionic_sem_post(sem_t* semaphore) {
  if (semaphore == nullptr) {
    errno = EINVAL;
    return -1;
  }
  unsigned* count = SemCount(semaphore);
  const int old_value = SemInc(count);
  if (old_value < 0) {
    (void)SemFutex(count, FUTEX_WAKE, static_cast<unsigned>(INT_MAX));
  } else if (old_value == SEM_VALUE_MAX) {
    errno = EOVERFLOW;
    return -1;
  }
  return 0;
}

}  // extern "C"
