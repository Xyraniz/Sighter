#ifndef SIGHTER_COMPAT_BIONIC_STDIO_RUNTIME_H_
#define SIGHTER_COMPAT_BIONIC_STDIO_RUNTIME_H_

#include <sys/types.h>

#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cwchar>

namespace sighter::compat {

// Android's public LP64 FILE ABI is opaque but has a fixed 152-byte stride.
// Old NDK clients derive stdin/stdout/stderr by indexing the exported __sF
// array, so its size and alignment are part of the binary interface even when
// all actual I/O is delegated to host stdio.
constexpr size_t kBionicFileSize = 152;
constexpr size_t kBionicStandardStreamCount = 3;

}  // namespace sighter::compat

extern "C" {

alignas(sizeof(void*)) extern unsigned char
    __sF[sighter::compat::kBionicStandardStreamCount]
        [sighter::compat::kBionicFileSize];

}  // extern "C"

namespace sighter::compat {

inline FILE* TranslateBionicFile(FILE* stream) noexcept {
  const uintptr_t address = reinterpret_cast<uintptr_t>(stream);
  if (__builtin_expect(address == reinterpret_cast<uintptr_t>(&__sF[0]), 0)) {
    return stdin;
  }
  if (__builtin_expect(address == reinterpret_cast<uintptr_t>(&__sF[1]), 0)) {
    return stdout;
  }
  if (__builtin_expect(address == reinterpret_cast<uintptr_t>(&__sF[2]), 0)) {
    return stderr;
  }
  return stream;
}

void* BionicFileArraySymbolAddress() noexcept;
void* BionicStdinSymbolAddress() noexcept;
void* BionicStdoutSymbolAddress() noexcept;
void* BionicStderrSymbolAddress() noexcept;

}  // namespace sighter::compat

// FILE values returned by host fopen/fdopen pass through unchanged. Pointers
// into Bionic's ABI-sized __sF array are translated to the corresponding host
// standard stream at this single boundary.
extern "C" {

size_t sighter_fwrite(const void* buffer, size_t size, size_t count,
                       FILE* stream);
size_t sighter_fread(void* buffer, size_t size, size_t count, FILE* stream);
int sighter_fflush(FILE* stream);
int sighter_fclose(FILE* stream);
int sighter_feof(FILE* stream);
int sighter_ferror(FILE* stream);
void sighter_clearerr(FILE* stream);
int sighter_fileno(FILE* stream);
int sighter_fseek(FILE* stream, long offset, int whence);
long sighter_ftell(FILE* stream);
int sighter_fseeko(FILE* stream, off_t offset, int whence);
off_t sighter_ftello(FILE* stream);
char* sighter_fgets(char* string, int count, FILE* stream);
int sighter_fputc(int character, FILE* stream);
int sighter_fputs(const char* string, FILE* stream);
int sighter_getc(FILE* stream);
wint_t sighter_fputwc(wchar_t character, FILE* stream);
int sighter_setvbuf(FILE* stream, char* buffer, int mode, size_t size);
int sighter_ungetc(int character, FILE* stream);
int sighter_vfprintf(FILE* stream, const char* format, va_list arguments);
int sighter_fprintf(FILE* stream, const char* format, ...);
int sighter_vfscanf(FILE* stream, const char* format, va_list arguments);
int sighter_fscanf(FILE* stream, const char* format, ...);
size_t sighter___fread_chk(void* buffer, size_t buffer_size, size_t size,
                            size_t count, FILE* stream);
size_t sighter___fwrite_chk(const void* buffer, size_t buffer_size,
                             size_t size, size_t count, FILE* stream);

}  // extern "C"

#endif  // SIGHTER_COMPAT_BIONIC_STDIO_RUNTIME_H_
