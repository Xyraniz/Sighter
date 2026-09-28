#ifndef SIGHTER_PLATFORM_ANDROID_LOG_OBSERVER_H_
#define SIGHTER_PLATFORM_ANDROID_LOG_OBSERVER_H_

// Observes the fully formatted payload written through Sighter's liblog
// adapter. The callback must not retain tag or message; both are borrowed for
// the duration of the call. Passing nullptr removes the current observer.
using SighterAndroidLogObserver = void (*)(int priority, const char* tag,
                                            const char* message);

extern "C" void sighter_android_log_set_observer(
    SighterAndroidLogObserver observer);

#endif  // SIGHTER_PLATFORM_ANDROID_LOG_OBSERVER_H_
