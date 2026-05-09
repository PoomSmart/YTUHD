#!/bin/bash
# Build dav1d as a static library for arm64 iOS.
# Output: vendor/dav1d_ios/libdav1d.a
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAV1D_SRC="$SCRIPT_DIR/dav1d"
BUILD_DIR="$SCRIPT_DIR/dav1d_ios"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN_IOS=11.0

# Generate a cross-file that uses the current SDK path rather than the
# hardcoded path in dav1d's bundled arm64-iPhoneOS.meson.
CROSS_FILE="$BUILD_DIR/arm64-iPhoneOS.meson"
mkdir -p "$BUILD_DIR"

cat > "$CROSS_FILE" <<MESON
[binaries]
c      = ['clang', '-arch', 'arm64', '-isysroot', '$SDK']
cpp    = ['clang++', '-arch', 'arm64', '-isysroot', '$SDK']
objc   = ['clang', '-arch', 'arm64', '-isysroot', '$SDK']
objcpp = ['clang++', '-arch', 'arm64', '-isysroot', '$SDK']
ar     = 'ar'
strip  = 'strip'

[built-in options]
c_args        = ['-miphoneos-version-min=$MIN_IOS']
cpp_args      = ['-miphoneos-version-min=$MIN_IOS']
c_link_args   = ['-miphoneos-version-min=$MIN_IOS']
cpp_link_args = ['-miphoneos-version-min=$MIN_IOS']

[properties]
needs_exe_wrapper = true

[host_machine]
system     = 'darwin'
subsystem  = 'ios'
kernel     = 'xnu'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'
MESON

echo "==> Building dav1d for arm64 iOS (min $MIN_IOS)"
echo "    SDK   : $SDK"
echo "    Output: $BUILD_DIR/libdav1d.a"

MESON_BUILD="$BUILD_DIR/meson_build"

meson setup "$MESON_BUILD" "$DAV1D_SRC" \
    --cross-file "$CROSS_FILE" \
    --default-library=static \
    --prefix="$BUILD_DIR/install" \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false \
    -Dlogging=false \
    --wipe 2>/dev/null || \
meson setup "$MESON_BUILD" "$DAV1D_SRC" \
    --cross-file "$CROSS_FILE" \
    --default-library=static \
    --prefix="$BUILD_DIR/install" \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false \
    -Dlogging=false

meson compile -C "$MESON_BUILD" -j"$(sysctl -n hw.ncpu)"
meson install -C "$MESON_BUILD" --no-rebuild

# Copy the static library to the expected location.
cp "$BUILD_DIR/install/lib/libdav1d.a" "$BUILD_DIR/libdav1d.a"

echo "==> Done: $BUILD_DIR/libdav1d.a"
