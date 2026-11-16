#!/bin/zsh
set -eu
cd "${0:A:h}"
PLATFORM=${1:-xros}
case $PLATFORM in
 xros) SDK=xros; TARGET=arm64-apple-xros2.0;;
 macos) SDK=macosx; TARGET=arm64-apple-macosx14.0;;
 *) echo 'Only the validated macOS/XROS parser targets are supported' >&2; exit 2;;
esac
python3 generate-budgeted-parser.py --check
SDKROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -target "$TARGET" -isysroot "$SDKROOT" \
 -Ivendor/libwebm -Isource/producer -c source/producer/budgeted-mkvparser.cc -o libs/$PLATFORM/parser.o
