/// GLIBC uses __unused in mutex struct in archlinux recently
/// RE https://github.com/minecraft-linux/mcpelauncher-linker/issues/3#issuecomment-3901699076
/// this shims the internal header to temporary disable the macro

/* deal with possible sys/cdefs.h conflict with fcntl.h */
#ifdef __unused
#define __unused_defined __unused
#undef __unused
#endif

#include_next <bits/struct_mutex.h>

/* restore definitions from above */
#ifdef __unused_defined
#define __unused __attribute__((__unused__))
#endif