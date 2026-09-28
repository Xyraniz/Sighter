#pragma once
#ifndef __APPLE__
#include "../../bionic/libc/include/sys/cdefs.h"
#endif
#if defined(__has_include_next)
#if __has_include_next(<sys/cdefs.h>)
#include_next <sys/cdefs.h>
#endif
#else
#include_next <sys/cdefs.h>
#endif
#ifdef __BIONIC__
#undef __BIONIC__
#endif
