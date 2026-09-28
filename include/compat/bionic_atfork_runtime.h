#ifndef SIGHTER_COMPAT_BIONIC_ATFORK_RUNTIME_H_
#define SIGHTER_COMPAT_BIONIC_ATFORK_RUNTIME_H_

namespace sighter::compat {

using BionicAtForkCallback = void (*)(void);

// POSIX cannot unregister by dso_handle, so registered guest callbacks must
// remain mapped for every later fork.
int RegisterBionicAtFork(BionicAtForkCallback prepare,
                         BionicAtForkCallback parent,
                         BionicAtForkCallback child, void* dso_handle) noexcept;

}  // namespace sighter::compat

extern "C" {

int sighter_bionic_register_atfork(
    sighter::compat::BionicAtForkCallback prepare,
    sighter::compat::BionicAtForkCallback parent,
    sighter::compat::BionicAtForkCallback child, void* dso_handle);

}  // extern "C"

#endif  // SIGHTER_COMPAT_BIONIC_ATFORK_RUNTIME_H_
