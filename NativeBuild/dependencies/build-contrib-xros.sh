#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
SDK=$(xcrun --sdk xros --show-sdk-path)
export PATH="/opt/homebrew/opt/m4/bin:/opt/homebrew/opt/libtool/libexec/gnubin:/opt/homebrew/bin:$PATH"
unset MACOSX_DEPLOYMENT_TARGET
export XROS_DEPLOYMENT_TARGET=2.0
mkdir -p "$ROOT/contrib-build-xros" "$ROOT/contrib-prefix-xros"
common=( -G 'Unix Makefiles' -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$ROOT/contrib-prefix-xros" -DCMAKE_PREFIX_PATH="$ROOT/contrib-prefix-xros" -DEBML_DIR="$ROOT/contrib-prefix-xros/lib/cmake/ebml" -Dutf8cpp_DIR="$ROOT/contrib-prefix-xros/lib/cmake/utf8cpp" -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0 -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_C_COMPILER_TARGET=arm64-apple-xros2.0 -DCMAKE_CXX_COMPILER_TARGET=arm64-apple-xros2.0 -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF -DFETCHCONTENT_FULLY_DISCONNECTED=ON )
for pkg in utfcpp-3.2.5 libebml-1.4.6 libmatroska-1.7.2; do
    extra=()
    case "$pkg" in
        utfcpp*) extra+=( -DUTF8_TESTS=OFF -DUTF8_SAMPLES=OFF -DUTF8_INSTALL=ON );;
        libebml*) extra+=( -DFETCHCONTENT_SOURCE_DIR_UTF8CPP="$ROOT/contrib-src/utfcpp-3.2.5" ); test -f "$ROOT/contrib-prefix-xros/lib/cmake/utf8cpp/utf8cppConfig.cmake";;
        libmatroska*) extra+=( -DBUILD_EXAMPLES=OFF );;
    esac
    cmake -S "$ROOT/contrib-src/$pkg" -B "$ROOT/contrib-build-xros/$pkg" "${common[@]}" "${extra[@]}" > "$ROOT/logs/xros-$pkg-configure.log" 2>&1
    cmake --build "$ROOT/contrib-build-xros/$pkg" --parallel 2 > "$ROOT/logs/xros-$pkg-build.log" 2>&1
    cmake --install "$ROOT/contrib-build-xros/$pkg" > "$ROOT/logs/xros-$pkg-install.log" 2>&1
    printf '%s built and installed locally\n' "$pkg"
done
