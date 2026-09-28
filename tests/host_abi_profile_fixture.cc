#include <cstddef>
#include <cstdlib>

extern "C" {

__attribute__((visibility("default"), noinline, used)) void*
SighterFixtureSmallAllocate(std::size_t size) {
  return std::malloc(size);
}

__attribute__((visibility("default"), noinline, used)) void*
SighterFixtureAllocate(std::size_t size) {
  return std::malloc(size);
}

__attribute__((visibility("default"), noinline, used)) void*
SighterFixtureReallocate(void* pointer, std::size_t size) {
  return std::realloc(pointer, size);
}

__attribute__((visibility("default"), noinline, used)) void*
SighterFixtureAlignedAllocate(std::size_t alignment, std::size_t size) {
  void* pointer = nullptr;
  return posix_memalign(&pointer, alignment, size) == 0 ? pointer : nullptr;
}

__attribute__((visibility("default"), noinline, used)) void SighterFixtureFree(
    void* pointer) {
  std::free(pointer);
}

__attribute__((visibility("default"), noinline, used)) std::size_t
SighterFixtureUsableSize(void*) {
  return 1;
}

__attribute__((visibility("default"), noinline, used)) void
SighterFixtureArenaInitialize() {}

__attribute__((visibility("default"), noinline, used)) void
SighterFixtureThreadInitialize() {}

__attribute__((visibility("default"), noinline, used)) void
SighterFixtureRegistryInitialize() {}

__attribute__((visibility("default"), constructor(101), used)) void
SighterFixtureConstructorTwo() {}

__attribute__((visibility("default"), constructor(102), used)) void
SighterFixtureConstructorThree() {}

__attribute__((visibility("default"), constructor(103), used)) void
SighterFixtureConstructorFour() {}

__attribute__((visibility("default"), constructor(104), used)) void
SighterFixtureConstructorFive() {}

__attribute__((visibility("default"),
               used)) void* sighter_fixture_allocator_slot = nullptr;
__attribute__((visibility("default"),
               used)) void* sighter_fixture_empty_string_slot = nullptr;
__attribute__((visibility("default"), used)) void* sighter_fixture_jni_slot =
    nullptr;
__attribute__((visibility("default"),
               used)) void* sighter_fixture_arena_guard_slot = nullptr;
__attribute__((visibility("default"),
               used)) void* sighter_fixture_arena_table_slot = nullptr;
__attribute__((visibility("default"),
               used)) void* sighter_fixture_registry_slot = nullptr;

}  // extern "C"

namespace {

struct FixtureConstructor {
  FixtureConstructor() { sighter_fixture_arena_guard_slot = nullptr; }
};

FixtureConstructor g_fixture_constructor;

}  // namespace
