#ifndef SIGHTER_COMPAT_HOST_ALLOCATOR_BRIDGE_H_
#define SIGHTER_COMPAT_HOST_ALLOCATOR_BRIDGE_H_

#include <cstddef>

namespace sighter::compat {

// Explicit smoke-only ownership boundary for allocations returned to the
// guest. Unknown/native pointers are never inspected or freed.
void* HostAllocate(size_t size) noexcept;
void* HostAlignedAllocate(size_t size, size_t alignment) noexcept;
void* HostReallocate(void* pointer, size_t size) noexcept;
void HostFree(void* pointer) noexcept;
size_t HostUsableSize(void* pointer) noexcept;
void* HostAllocatorObjectAllocate(void* object, size_t size,
                                  size_t alignment) noexcept;

}  // namespace sighter::compat

#endif  // SIGHTER_COMPAT_HOST_ALLOCATOR_BRIDGE_H_
