#!/bin/bash
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
F="$D"
P=${1:?macos or xros}
export PATH="${VISTA_BUILD_TOOLS:+$VISTA_BUILD_TOOLS:}/opt/homebrew/opt/m4/bin:/opt/homebrew/opt/libtool/libexec/gnubin:/opt/homebrew/bin:$PATH"
export M4="${M4:-$(command -v m4)}" ACLOCAL_PATH="${ACLOCAL_PATH:-/opt/homebrew/share/aclocal}"
HOSTSDK=$(xcrun --sdk macosx --show-sdk-path)
case "$P" in
macos) SDKNAME=macosx; TARGET=arm64-apple-macos14.0; CONTRIB="$F/contrib-prefix"; PLATFORM=(--with-macosx-version-min=14.0); OUTPUT=libauhal_plugin.la;;
xros) SDKNAME=xros; TARGET=arm64-apple-xros2.0; CONTRIB="$F/contrib-prefix-xros"; PLATFORM=(--host=aarch64-apple-darwin --build=aarch64-apple-darwin27.2.0); OUTPUT=libaudiounit_ios_plugin.la;;
*) exit 2;; esac
SDK=$(xcrun --sdk "$SDKNAME" --show-sdk-path)
export CC="$(xcrun --sdk "$SDKNAME" -f clang) -target $TARGET"
export CXX="$(xcrun --sdk "$SDKNAME" -f clang++) -target $TARGET"
export OBJC="$CC" OBJCXX="$CXX"
export BUILDCC="$(xcrun --sdk macosx -f clang) -target arm64-apple-macos14.0 -isysroot $HOSTSDK"
export SDKROOT="$SDK"
unset MACOSX_DEPLOYMENT_TARGET
export CFLAGS="-isysroot $SDK" CXXFLAGS="-isysroot $SDK" OBJCFLAGS="-isysroot $SDK" OBJCXXFLAGS="-isysroot $SDK" LDFLAGS="-isysroot $SDK"
export lt_cv_sys_max_cmd_len=16384
export PKG_CONFIG_LIBDIR="$D/prefix-$P/lib/pkgconfig:$CONTRIB/lib/pkgconfig:$CONTRIB/share/pkgconfig" PKG_CONFIG_PATH="$D/prefix-$P/lib/pkgconfig:$CONTRIB/lib/pkgconfig:$CONTRIB/share/pkgconfig"
options=()
while IFS= read -r option; do
    if [[ "$option" == --disable-avcodec ]]; then option=--enable-avcodec; fi
    options+=( "$option" )
done < "$F/configure-options.txt"
B="$D/vlc-build-$P"; mkdir -p "$B"; cd "$B"
"$D/source/vlc/configure" --prefix="$D/vlc-prefix-$P" --with-contrib="$CONTRIB" --with-macosx-sdk="$SDK" --with-binary-version=vista-aac-research-20261110 "${PLATFORM[@]}" "${options[@]}" > "$D/logs/vlc-$P-configure.log" 2>&1
for part in compat src lib; do make -C "$B/$part" -j2 all > "$D/logs/vlc-$P-$part-build.log" 2>&1; done
targets=( libimem_plugin.la libmkv_plugin.la libpacketizer_h264_plugin.la libpacketizer_hevc_plugin.la libpacketizer_copy_plugin.la libvideotoolbox_plugin.la libwdummy_plugin.la libvistacvpx_plugin.la libavcodec_plugin.la libamem_plugin.la libfloat_mixer_plugin.la libugly_resampler_plugin.la "$OUTPUT" )
printf '%s\n' "${targets[@]}" > "$D/evidence/vlc-$P-module-targets.txt"
make -C "$B/modules" -j2 "${targets[@]}" > "$D/logs/vlc-$P-modules-build.log" 2>&1
