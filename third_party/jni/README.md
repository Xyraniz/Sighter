# Standalone JNI ABI headers

Sighter vendors only the platform-neutral JNI C/C++ ABI headers needed to
compile its pseudo-JVM. No Java VM, bytecode runtime, standard library, or JDK
tool is included.

- Upstream: OpenJDK 17u
- Release: `jdk-17.0.20+8`
- Files: `src/java.base/share/native/include/jni.h` and
  `src/java.base/unix/native/include/jni_md.h`
- `jni.h` SHA-256:
  `1266aea5b9f5d5db1cb6f8e5c6c43cfa7f80bc4f72d7fe42c6131bb939dc70f4`
- `jni_md.h` SHA-256:
  `88cb5c33e306900dd35a78d5a439087123b8e91b0986bb5acb42cc9bd2fcc42e`
- License: GPL-2.0-only WITH Classpath-exception-2.0; see `LICENSE` and
  `ASSEMBLY_EXCEPTION`.

These headers are build inputs. CMake does not install them, and Flatpak's
cleanup removes all dependency headers from the application payload.
