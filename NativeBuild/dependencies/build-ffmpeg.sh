#!/bin/bash
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
P=${1:?macos or xros}
case "$P" in
macos) SDKNAME=macosx; TARGET=arm64-apple-macos14.0; CROSS=--disable-cross-compile;;
xros) SDKNAME=xros; TARGET=arm64-apple-xros2.0; CROSS=--enable-cross-compile;;
*) exit 2;; esac
SDK=$(xcrun --sdk "$SDKNAME" --show-sdk-path)
CC=$(xcrun --sdk "$SDKNAME" -f clang)
export PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$D/prefix-$P/lib/pkgconfig"
opts=( --prefix="$D/prefix-$P" --disable-everything --disable-autodetect --disable-gpl --disable-nonfree --disable-version3 --disable-programs --disable-doc --disable-network --disable-avdevice --disable-avfilter --disable-avformat --disable-swscale --disable-swresample --disable-audiotoolbox --disable-videotoolbox --enable-avcodec --enable-avutil --enable-decoder=aac --enable-static --disable-shared --enable-pic --disable-debug --arch=aarch64 --target-os=darwin --cc="$CC" --host-cc="$(xcrun --sdk macosx -f clang)" --host-cflags="-target arm64-apple-macos14.0 -isysroot $(xcrun --sdk macosx --show-sdk-path)" --host-ldflags="-target arm64-apple-macos14.0 -isysroot $(xcrun --sdk macosx --show-sdk-path)" --cxx="$(xcrun --sdk "$SDKNAME" -f clang++)" --extra-cflags="-target $TARGET -isysroot $SDK" --extra-ldflags="-target $TARGET -isysroot $SDK" --ar="$(xcrun -f ar)" --ranlib="$(xcrun -f ranlib)" --nm="$(xcrun -f nm)" )
printf '%s\n' "${opts[@]}" "$CROSS" > "$D/evidence/ffmpeg-$P-options.txt"
cd "$D/build-$P"
"$D/source/ffmpeg-9.0/configure" "${opts[@]}" "$CROSS" > "$D/logs/ffmpeg-$P-configure.log" 2>&1
make -j2 > "$D/logs/ffmpeg-$P-build.log" 2>&1
make install-libs install-headers > "$D/logs/ffmpeg-$P-install.log" 2>&1
