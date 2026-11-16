#!/bin/zsh
set -eu
cd "${0:A:h}"
PLATFORM=${1:-xros}
case $PLATFORM in
 xros) SDK=xros; TARGET=arm64-apple-xros2.0;;
 xrsimulator) SDK=xrsimulator; TARGET=arm64-apple-xros2.0-simulator;;
 macos) SDK=macosx; TARGET=arm64-apple-macosx14.0;;
 *) exit 2;;
esac
ROOT=${PWD}
SDKROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Wno-deprecated-declarations -target "$TARGET" -isysroot "$SDKROOT" -DGPAC_HAVE_CONFIG_H -Iconfig/$PLATFORM -Ivendor/gpac-26.07.0/include -Ivendor/libwebm -Isource/producer -c source/producer/MKVProducer.cpp -o libs/$PLATFORM/MKVProducer.o
if [[ $PLATFORM == macos ]]; then
 xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -import-objc-header source/producer/MKVProducer.h \
 ../app/Sources/VistaCore/MediaInspection.swift ../app/Sources/VistaCore/MediaReadPlan.swift \
 source/source-adapter/AdapterContracts.swift source/source-adapter/LocalOperationSource.swift source/source-adapter/SourceAdapterSession.swift tests/LocalDirectoryProviderCandidate.swift tests/EngineOffline.swift \
 libs/macos/{MKVProducer.o,parser.o,budget.o,libgpac_static.a} -lc++ -lz -Xlinker -dead_strip -o bin/EngineOffline
fi
