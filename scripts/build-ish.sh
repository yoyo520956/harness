#!/bin/bash
# 构建 iSH 引擎（libish/libish_emu/libfakefs + libarchive，全部 arm64 iOS）
# CI 与本地共用。SRCROOT 由 xcodebuild script phase 提供。
set -e
cd "$SRCROOT"
OUT="$PWD/vendor/out"
BUILD="$PWD/build"
mkdir -p "$OUT" "$BUILD"

ISH_SHA="c5ebcabec14f1d8709e91e1905ce0edd7cb9c13c"

# 0) vendor/ish 源码（CI 无本地副本时克隆 pinned commit）
if [ ! -f "$SRCROOT/vendor/ish/meson.build" ]; then
  echo "[iSH] cloning ish-app/ish @ $ISH_SHA"
  git clone --depth 1 https://github.com/ish-app/ish "$SRCROOT/vendor/ish"
  cd "$SRCROOT/vendor/ish" && git fetch --depth 1 origin "$ISH_SHA" && git checkout -q FETCH_HEAD
  git submodule update --init --depth 1 deps/libapps deps/libarchive || true
  cd "$SRCROOT"
fi
if [ ! -f "$SRCROOT/vendor/ish/deps/libarchive/libarchive/archive.h" ]; then
  echo "[iSH] fetching libarchive submodule"
  rm -rf "$SRCROOT/vendor/ish/deps/libarchive"
  mkdir -p "$SRCROOT/vendor/ish/deps/libarchive"
  cd "$SRCROOT/vendor/ish/deps/libarchive" && git init -q && git remote add origin https://github.com/libarchive/libarchive \
    && git fetch --depth 1 origin fc6563f5130d8a7ee1fc27c0e55baef35119f26c && git checkout -q FETCH_HEAD
  cd "$SRCROOT"
fi

SDK_PATH=$(xcrun -sdk iphoneos --show-sdk-path)
CLANG=$(xcrun -f --sdk iphoneos clang)
AR=$(xcrun -f --sdk iphoneos ar)

# 1) libarchive 静态库（fakefs_import 依赖）
if [ ! -f "$OUT/libarchive.a" ]; then
  echo "[iSH] building libarchive (ios arm64)"
  cmake -S "$SRCROOT/vendor/ish/deps/libarchive" -B "$BUILD/libarchive" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_TEST=OFF -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF \
    -DENABLE_OPENSSL=OFF -DENABLE_XML2=OFF -DENABLE_EXPAT=OFF -DENABLE_ICONV=OFF \
    -DENABLE_ACL=OFF -DENABLE_ATTR=OFF -DENABLE_AUDIT=OFF -DENABLE_NETTLE=OFF \
    -DENABLE_LIBB2=OFF -DENABLE_LZ4=OFF -DENABLE_ZSTD=OFF -DENABLE_LZMA=OFF \
    -DENABLE_BZip2=OFF -DENABLE_MBEDTLS=OFF > /dev/null
  cmake --build "$BUILD/libarchive" --target archive_static -- -j3
  cp "$BUILD/libarchive/libarchive/libarchive.a" "$OUT/libarchive.a"
fi

# 2) iSH 内核三静态库（meson + asbestos 线索码解释器，无 JIT 需求）
if [ ! -f "$OUT/libish.a" ] || [ ! -f "$OUT/libish_emu.a" ] || [ ! -f "$OUT/libfakefs.a" ]; then
  echo "[iSH] building ish libs (meson)"
  mkdir -p "$BUILD/ish-meson"
  cd "$BUILD/ish-meson"
  if [ ! -f build.ninja ]; then
    cat > cross.txt <<EOF
[binaries]
c = '$CLANG'
ar = '$AR'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SDK_PATH', '-O2', '-Wno-implicit-function-declaration']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK_PATH']

[properties]
needs_exe_wrapper = true
EOF
    meson setup "$SRCROOT/vendor/ish" --cross-file cross.txt -Dkernel=ish -Dengine=asbestos -Dbuildtype=debugoptimized
  fi
  ninja -j3 libish.a libish_emu.a libfakefs.a
  cp -f libish.a libish_emu.a libfakefs.a "$OUT/"
fi

ls -la "$OUT"
echo "[iSH] engine libs ready"
