#ifndef SIGHTER_COMPAT_BIONIC_PTHREAD_KEY_RUNTIME_H_
#define SIGHTER_COMPAT_BIONIC_PTHREAD_KEY_RUNTIME_H_

#include <pthread.h>

#include <cstddef>
#include <cstdint>

namespace sighter::compat {

// Android Bionic exposes pthread keys as 0x80000000 | index. Its current
// public key pool includes two libc-reserved slots and PTHREAD_KEYS_MAX
// application slots. The implementation mirrors that externally
// visible ABI without replacing the host process TLS/FS layout.
constexpr size_t kBionicPthreadKeyCount = 130;
constexpr uint32_t kBionicPthreadKeyValidFlag = uint32_t{1} << 31;

using BionicPthreadKeyDestructor = void (*)(void*);

// Implements Bionic's pthread_key_* ABI for keys registered through the
// synthetic libc.so. Host code continues to use glibc pthread keys.
class BionicPthreadKeyRuntime {
 public:
  static BionicPthreadKeyRuntime& Instance() noexcept;

  int Create(pthread_key_t* key, BionicPthreadKeyDestructor destructor) noexcept;
  int Delete(pthread_key_t key) noexcept;
  void* Get(pthread_key_t key) noexcept;
  int Set(pthread_key_t key, const void* value) noexcept;

 private:
  BionicPthreadKeyRuntime() = default;
};

bool IsBionicPthreadKey(pthread_key_t key) noexcept;

}  // namespace sighter::compat

extern "C" {

int sighter_bionic_pthread_key_create(
    pthread_key_t* key, void (*destructor)(void*));
int sighter_bionic_pthread_key_delete(pthread_key_t key);
void* sighter_bionic_pthread_getspecific(pthread_key_t key);
int sighter_bionic_pthread_setspecific(pthread_key_t key,
                                        const void* value);

}  // extern "C"

#endif  // SIGHTER_COMPAT_BIONIC_PTHREAD_KEY_RUNTIME_H_
