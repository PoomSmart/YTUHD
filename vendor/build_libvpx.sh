#!/bin/bash
# Build libvpx as a static library for arm64 iOS / iOS Simulator
# Output: vendor/libvpx_ios/libvpx.a  (arm64 device)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBVPX_SRC="$SCRIPT_DIR/libvpx"
BUILD_DIR="$SCRIPT_DIR/libvpx_ios"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
CXX="$(xcrun --sdk iphoneos --find clang++)"
AR="$(xcrun --sdk iphoneos --find ar)"
STRIP="$(xcrun --sdk iphoneos --find strip)"
NM="$(xcrun --sdk iphoneos --find nm)"

# Minimum iOS version — keep in sync with Makefile TARGET
MIN_IOS=15.0

EXTRA_CFLAGS="-miphoneos-version-min=$MIN_IOS -isysroot $SDK"

echo "==> Building libvpx for arm64-darwin-gcc"
echo "    SDK   : $SDK"
echo "    CC    : $CC"
echo "    Output: $BUILD_DIR/libvpx.a"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

CC="$CC" CXX="$CXX" AR="$AR" STRIP="$STRIP" NM="$NM" \
"$LIBVPX_SRC/configure" \
    --target=arm64-darwin-gcc \
    --disable-examples \
    --disable-tools \
    --disable-docs \
    --disable-unit-tests \
    --disable-vp8 \
    --disable-vp9-encoder \
    --enable-vp9-decoder \
    --extra-cflags="$EXTRA_CFLAGS"

make -j"$(sysctl -n hw.ncpu)" libvpx.a

echo "==> Done: $BUILD_DIR/libvpx.a"
