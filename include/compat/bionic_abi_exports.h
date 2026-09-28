#ifndef SIGHTER_COMPAT_BIONIC_ABI_EXPORTS_H_
#define SIGHTER_COMPAT_BIONIC_ABI_EXPORTS_H_

// Transitional ABI exports retained for the isolated legacy runtime. New
// Android libraries must register owned symbols through the per-SONAME linker
// API instead of adding process-global functions here.

#include <pthread.h>
#include <sys/types.h>
#include <time.h>

#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>

#include "compat/bionic_stdio_runtime.h"

// Updated by the legacy loader after libroblox is mapped. The abort bridge
// uses it only to report a caller-relative diagnostic offset.
extern volatile uintptr_t g_sighter_abort_libroblox_base;

namespace sighter::compat {

// Enables diagnostics that contain offsets from the researched legacy Roblox
// binary. The default is false and Build-ID policy is the only caller allowed
// to enable it.
void SetLegacyBionicDiagnosticsEnabled(bool enabled);

}  // namespace sighter::compat

// Bionic x86-64 defines pthread_mutexattr_t as an eight-byte long. Keep that
// guest layout explicit instead of exposing the incompatible host libc type.
using SighterBionicMutexAttr = int64_t;

// Bionic LP64 pthread_attr_t: 56 bytes with explicit field offsets. The host
// glibc layout is opaque and wider on aarch64, so guest buffers must be read
// and written through this struct only.
struct SighterBionicPthreadAttr {
  std::uint32_t flags;
  void* stack_base;
  std::size_t stack_size;
  std::size_t guard_size;
  std::int32_t sched_policy;
  std::int32_t sched_priority;
  char reserved[16];
};
static_assert(sizeof(SighterBionicPthreadAttr) == 56);

inline constexpr std::uint32_t kSighterBionicAttrFlagDetached = 0x1;
inline constexpr std::uint32_t kSighterBionicAttrFlagUserStack = 0x2;

extern "C" {

void sighter_set_current_jni_env(void* env);
void* sighter_get_current_jni_env();

[[noreturn]] void sighter_abort();
int __system_property_get(const char* name, char* value);

void* __memcpy_chk(void* dst, const void* src, size_t count, size_t dst_len);
char* __strcpy_chk(char* dst, const char* src, size_t dst_len);
int __vsprintf_chk(char* dst, int flags, size_t dst_len, const char* format,
                   va_list args);
int __vsnprintf_chk(char* dst, size_t count, int flags, size_t dst_len,
                    const char* format, va_list args);
ssize_t __read_chk(int fd, void* buf, size_t count, size_t buf_len);

int sighter_pthread_condattr_init(pthread_condattr_t* attr);
int sighter_pthread_condattr_destroy(pthread_condattr_t* attr);
int sighter_pthread_condattr_setclock(pthread_condattr_t* attr,
                                       clockid_t clock_id);
int sighter_pthread_cond_init(pthread_cond_t* cond,
                               const pthread_condattr_t* attr);
int sighter_pthread_cond_destroy(pthread_cond_t* cond);
int sighter_pthread_cond_signal(pthread_cond_t* cond);
int sighter_pthread_cond_broadcast(pthread_cond_t* cond);
int sighter_pthread_cond_wait(pthread_cond_t* cond, pthread_mutex_t* mutex);
int sighter_pthread_cond_timedwait(pthread_cond_t* cond,
                                    pthread_mutex_t* mutex,
                                    const timespec* abstime);
int sighter_pthread_mutexattr_init(SighterBionicMutexAttr* attr);
int sighter_pthread_mutexattr_destroy(SighterBionicMutexAttr* attr);
int sighter_pthread_mutexattr_settype(SighterBionicMutexAttr* attr, int type);
int sighter_pthread_mutex_init(pthread_mutex_t* mutex,
                                const SighterBionicMutexAttr* attr);
int sighter_pthread_mutex_destroy(pthread_mutex_t* mutex);
int sighter_pthread_mutex_lock(pthread_mutex_t* mutex);
int sighter_pthread_mutex_trylock(pthread_mutex_t* mutex);
int sighter_pthread_mutex_unlock(pthread_mutex_t* mutex);
int sighter_pthread_once(pthread_once_t* once_control,
                          void (*init_routine)(void));
int sighter_pthread_spin_init(pthread_spinlock_t* lock, int pshared);
int sighter_pthread_spin_destroy(pthread_spinlock_t* lock);
int sighter_pthread_spin_lock(pthread_spinlock_t* lock);
int sighter_pthread_spin_trylock(pthread_spinlock_t* lock);
int sighter_pthread_spin_unlock(pthread_spinlock_t* lock);
int sighter_pthread_barrier_init(pthread_barrier_t* barrier,
                                  const pthread_barrierattr_t* attr,
                                  unsigned count);
int sighter_pthread_barrier_destroy(pthread_barrier_t* barrier);
int sighter_pthread_barrier_wait(pthread_barrier_t* barrier);

int sighter_pthread_attr_init(SighterBionicPthreadAttr* attr);
int sighter_pthread_attr_destroy(SighterBionicPthreadAttr* attr);
int sighter_pthread_attr_setstacksize(SighterBionicPthreadAttr* attr,
                                       size_t stack_size);
int sighter_pthread_attr_setdetachstate(SighterBionicPthreadAttr* attr,
                                         int detach_state);
int sighter_pthread_attr_setschedparam(SighterBionicPthreadAttr* attr,
                                        const struct sched_param* parameters);
int sighter_pthread_getattr_np(pthread_t thread,
                                SighterBionicPthreadAttr* attr);
int sighter_pthread_attr_getstack(const SighterBionicPthreadAttr* attr,
                                   void** stack_base, size_t* stack_size);

extern void* sighter_gameactivity_on_start_native;
extern void* sighter_gameactivity_on_resume_native;
extern void* sighter_gameactivity_on_surface_created_native;
extern void* sighter_gameactivity_on_surface_changed_native;
extern void* sighter_gameactivity_on_surface_redraw_needed_native;

}  // extern "C"

#endif  // SIGHTER_COMPAT_BIONIC_ABI_EXPORTS_H_
