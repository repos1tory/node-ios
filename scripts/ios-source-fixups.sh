#!/bin/sh
# iOS cross-compile source fixups for the Node.js tree.
# Applied after clone, before configure. Accumulates targeted deltas for iOS-SDK
# mismatches in Node's bundled deps (cheaper + more version-robust than .patch files).
set -eux
SRC="${1:?usage: ios-source-fixups.sh <node-src-dir>}"
cd "$SRC"

# --- gyp make generator: drop GNU --start-group/--end-group ---
# For flavor=="ios" the make generator uses the Linux link template, which wraps the
# static libs in `-Wl,--start-group ... -Wl,--end-group`. Apple's ld64 (used for BOTH the
# macOS host tools and the iOS target on the runner) rejects those flags AND doesn't need
# them — it resolves archives with a global view, so circular deps are fine without a
# group. Strip them from every link template. This is far less invasive than remapping the
# flavor (which shifts obj.host lib paths and breaks the js2c host link).
python3 - "tools/gyp/pylib/gyp/generator/make.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
orig = s
s = s.replace(" -Wl,--start-group", "").replace(" -Wl,--end-group", "")
if s == orig:
    if "-Wl,--start-group" in s or "-Wl,--end-group" in s:
        raise SystemExit("make.py --start-group strip matched nothing — Node layout changed?")
    print("fixup: gyp make link templates already have no GNU group flags")
else:
    open(p, "w").write(s)
    print("fixup: stripped -Wl,--start-group/--end-group from gyp make link templates")
PY

# --- Node crypto: macOS-only keychain CA reader ---
# src/crypto/crypto_context.cc guards its macOS system-keychain cert reader with
# `#ifdef __APPLE__`, but it uses SecTrustSettings* — a macOS-only Security API absent on
# iOS (where __APPLE__ is still defined). Narrow the guard to TARGET_OS_OSX so it's
# excluded on iOS. We don't need it: Node's bundled Mozilla roots handle TLS.
python3 - "src/crypto/crypto_context.cc" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
orig = s
if "TargetConditionals.h" not in s:
    s = "#if defined(__APPLE__)\n#include <TargetConditionals.h>\n#endif\n" + s
s = s.replace("#ifdef __APPLE__", "#if defined(__APPLE__) && TARGET_OS_OSX")
if s == orig:
    if "TARGET_OS_OSX" not in s:
        raise SystemExit("crypto_context.cc fixup matched nothing — Node layout changed?")
    print("fixup: crypto_context.cc macOS guards already use TARGET_OS_OSX")
else:
    open(f, "w").write(s)
    print("fixup: crypto_context.cc macOS keychain code guarded with TARGET_OS_OSX")
PY

# --- link Darwin frameworks on iOS ---
# Frameworks are normally declared via xcode_settings.OTHER_LDFLAGS, which the gyp *make*
# generator only applies for flavor=="mac" — so flavor=="ios" links nothing. Abseil's tz
# lookup (via V8) needs CoreFoundation (_CFRelease/_CFTimeZone* etc.), and other deps want
# CoreServices/Security. Inject them as plain link_settings.libraries in target_defaults
# (honored by any flavor, applied to every linked target). All exist on the iOS SDK.
python3 - "common.gypi" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
anchor = "['OS==\"mac\"', {\n        'defines': ['_DARWIN_USE_64_BIT_INODE=1'],"
inject = ("['OS==\"ios\"', {\n"
          "        'link_settings': { 'libraries': [\n"
          "          '-framework CoreFoundation',\n"
          "          '-framework CoreServices',\n"
          "          '-framework Security',\n"
          "        ] },\n"
          "      }],\n"
          "      ") + anchor
if anchor not in s and "repos1tory-node-ios-frameworks" not in s:
    raise SystemExit("common.gypi anchor not found — Node layout changed?")
if "repos1tory-node-ios-frameworks" not in s:
    inject = inject.replace("['OS==\"ios\"', {", "['OS==\"ios\"', { # repos1tory-node-ios-frameworks", 1)
    s = s.replace(anchor, inject, 1)
open(f, "w").write(s)
print("fixup: common.gypi links CoreFoundation/CoreServices/Security on iOS")
PY

# --- V8: don't use MAP_JIT on iOS ---
# platform-posix.cc requests MAP_JIT pages for all Darwin. On the A9 MAP_JIT returns EINVAL
# (it's an A11+/APRR feature), so we exclude iOS and let V8 fall back to plain anonymous
# pages that our mprotect W^X mechanism (below) can flip. iOS-only.
python3 - "deps/v8/src/base/platform/platform-posix.cc" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
orig = s
s = s.replace(
    "#if V8_OS_DARWIN\n  // MAP_JIT is required to obtain writable and executable pages when the",
    "#if V8_OS_DARWIN && !defined(V8_OS_IOS)\n  // MAP_JIT is required to obtain writable and executable pages when the",
)
if s == orig:
    if "#if V8_OS_DARWIN && !defined(V8_OS_IOS)" not in s:
        raise SystemExit("V8 MAP_JIT fixup matched nothing — V8 layout changed?")
    print("fixup: V8 iOS MAP_JIT exclusion already applied")
else:
    open(f, "w").write(s)
    print("fixup: V8 no longer uses MAP_JIT on iOS (falls back to plain pages + mprotect W^X)")
PY

# --- V8: Node 26 full JIT on pre-APRR iOS via mprotect W^X ---
# BrowserEngineCore JIT is unavailable at iOS 15; use V8 write scopes with
# the port's mprotect backend over the shared JS/Wasm code cage.
python3 - <<'PY'
def replace_once(path, old, new, label):
    source = open(path).read()
    if old not in source:
        if new in source:
            return
        raise SystemExit(f"{label}: expected Node 26 anchor missing")
    open(path, "w").write(source.replace(old, new, 1))

replace_once("deps/v8/src/base/build_config.h",
'''// pthread_jit_write_protect is only available on arm64 Mac.
#if defined(V8_HOST_ARCH_ARM64) && defined(V8_OS_MACOS)
#define V8_HAS_PTHREAD_JIT_WRITE_PROTECT 1''',
'''// The iOS port supplies an mprotect-backed implementation.
#if defined(V8_HOST_ARCH_ARM64) && (defined(V8_OS_MACOS) || defined(V8_OS_IOS))
#define V8_HAS_PTHREAD_JIT_WRITE_PROTECT 1''', "V8 JIT feature gate")

replace_once("deps/v8/src/base/platform/platform.h",
'''#if V8_HAS_PTHREAD_JIT_WRITE_PROTECT
V8_BASE_EXPORT void SetJitWriteProtected(int enable);
#endif''',
'''#if V8_HAS_PTHREAD_JIT_WRITE_PROTECT
V8_BASE_EXPORT void SetJitWriteProtected(int enable);
#if defined(V8_OS_IOS)
V8_BASE_EXPORT void RegisterJitRange(void* base, size_t size);
#endif
#endif''', "V8 JIT declarations")

# Keep APRR on macOS; use mprotect over registered ranges on iOS.
path = "deps/v8/src/base/platform/platform-darwin.cc"
source = open(path).read()
if "V8_BASE_EXPORT void RegisterJitRange(void* base, size_t size)" not in source:
    old = '''V8_BASE_EXPORT void SetJitWriteProtected(int enable) {
  pthread_jit_write_protect_np(enable);
}

#pragma clang diagnostic pop
#endif'''
    new = '''V8_BASE_EXPORT void SetJitWriteProtected(int enable) {
  pthread_jit_write_protect_np(enable);
}

#pragma clang diagnostic pop
#endif

#if V8_HAS_PTHREAD_JIT_WRITE_PROTECT && defined(V8_OS_IOS)
namespace {
struct JitRange { void* base; size_t size; };
constexpr int kMaxJitRanges = 256;
JitRange g_jit_ranges[kMaxJitRanges];
int g_jit_range_count = 0;
}
V8_BASE_EXPORT void RegisterJitRange(void* base, size_t size) {
  if (!base || !size) return;
  for (int i = 0; i < g_jit_range_count; ++i) {
    if (g_jit_ranges[i].base == base) {
      g_jit_ranges[i].size = size;
      return;
    }
  }
  if (g_jit_range_count < kMaxJitRanges)
    g_jit_ranges[g_jit_range_count++] = {base, size};
}
V8_BASE_EXPORT void SetJitWriteProtected(int enable) {
  const int prot = enable ? (PROT_READ | PROT_EXEC) : (PROT_READ | PROT_WRITE);
  for (int i = 0; i < g_jit_range_count; ++i) {
    if (mprotect(g_jit_ranges[i].base, g_jit_ranges[i].size, prot) != 0) {
      g_jit_ranges[i] = g_jit_ranges[--g_jit_range_count];
      --i;
    }
  }
}
#endif'''
    if old not in source:
        raise SystemExit("V8 Darwin write-protect anchor missing")
    open(path, "w").write(source.replace(old, new, 1))

# Register the shared code cage; Node 26 allocates JS and Wasm there on iOS.
path = "deps/v8/src/heap/code-range.cc"
source = open(path).read()
if '#include "src/base/platform/platform.h"' not in source:
    old = '#include "src/base/once.h"'
    if old not in source:
        raise SystemExit("V8 CodeRange include anchor missing")
    source = source.replace(old, old + '\n#include "src/base/platform/platform.h"', 1)
reg = '''#if defined(V8_OS_IOS) && V8_HAS_PTHREAD_JIT_WRITE_PROTECT
  ::v8::base::RegisterJitRange(reinterpret_cast<void*>(page_allocator_->begin()),
                               page_allocator_->size());
#endif
  return true;
}'''
if reg not in source:
    old = '#endif  // !defined(V8_OS_WIN)\n\n  return true;\n}'
    if old not in source:
        raise SystemExit("V8 CodeRange registration anchor missing")
    source = source.replace(old, '#endif  // !defined(V8_OS_WIN)\n\n' + reg, 1)
open(path, "w").write(source)

# Node 26 recommits executable JS pages via this helper.
replace_once("deps/v8/src/heap/memory-allocator.cc",
'''    return vm->RecommitPages(start, chunk_size,
                             PageAllocator::kReadWriteExecute);''',
'''#if defined(V8_OS_IOS)
    return vm->RecommitPages(start, chunk_size, PageAllocator::kReadWrite);
#else
    return vm->RecommitPages(start, chunk_size,
                             PageAllocator::kReadWriteExecute);
#endif''', "V8 executable MemoryChunk recommit")

# Node 26's Wasm code lives in the same shared code cage.
replace_once("deps/v8/src/wasm/wasm-code-manager.cc",
'''  bool success = GetPageAllocator()->RecommitPages(
      reinterpret_cast<void*>(region.begin()), region.size(),
      PageAllocator::kReadWriteExecute);''',
'''#if defined(V8_OS_IOS)
  bool success = GetPageAllocator()->RecommitPages(
      reinterpret_cast<void*>(region.begin()), region.size(),
      PageAllocator::kReadWrite);
#else
  bool success = GetPageAllocator()->RecommitPages(
      reinterpret_cast<void*>(region.begin()), region.size(),
      PageAllocator::kReadWriteExecute);
#endif''', "V8 Wasm recommit")

# On Darwin, generic RecommitPages is normally madvise-only because MAP_JIT
# mappings keep fixed permissions. Our iOS mapping is not MAP_JIT, so restore
# the requested RW permission explicitly before V8's later RW->RX scope flip.
path = "deps/v8/src/base/platform/platform-posix.cc"
source = open(path).read()
old = '''bool OS::RecommitPages(void* address, size_t size, MemoryPermission access) {
  DCHECK_EQ(0, reinterpret_cast<uintptr_t>(address) % CommitPageSize());
  DCHECK_EQ(0, size % CommitPageSize());

#if defined(V8_OS_DARWIN)'''
new = '''bool OS::RecommitPages(void* address, size_t size, MemoryPermission access) {
  DCHECK_EQ(0, reinterpret_cast<uintptr_t>(address) % CommitPageSize());
  DCHECK_EQ(0, size % CommitPageSize());

#if defined(V8_OS_IOS)
  return SetPermissions(address, size, access);
#endif

#if defined(V8_OS_DARWIN)'''
if old in source:
    open(path, "w").write(source.replace(old, new, 1))
elif "#if defined(V8_OS_IOS)\n  return SetPermissions(address, size, access);" not in source:
    raise SystemExit("V8 iOS RecommitPages permission anchor changed")

print("fixup: Node 26 V8 iOS mprotect W^X enabled for shared JS/Wasm cage")
PY
# --- c-ares ---
# Node's cares.gyp uses config/darwin for both mac and ios, but the iOS SDK does NOT
# ship <sys/random.h> (it has arc4random_buf instead). Undef the header macro so
# ares_rand.c falls back to arc4random_buf (HAVE_ARC4RANDOM_BUF is already defined).
if grep -q '#define HAVE_SYS_RANDOM_H 1' deps/cares/config/darwin/ares_config.h; then
  python3 - "deps/cares/config/darwin/ares_config.h" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace('#define HAVE_SYS_RANDOM_H 1', '/* undef HAVE_SYS_RANDOM_H (iOS SDK lacks it) */')
open(path, 'w').write(text)
PY
  echo "fixup: c-ares HAVE_SYS_RANDOM_H undef'd"
fi

echo "ios-source-fixups: done"
