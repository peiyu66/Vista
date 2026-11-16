#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SAP SAP;
/* Match the existing 24-fragment App rolling/manifest window. This is NOT
   maxUnackedSegments (1..12); the App still grants only one engine credit. */
enum { SAP_STARTUP_SEGMENT_MAX = 24 };
/* Anonymous schema-7 diagnostics; scalars only, separate from the frozen playback ABI.
   observedMask: 1 tracks,2 videoCodec,4 audioCodec,8 dimensions,16 VP9 profile,
   32 VP9 colour,64 AAC rate,128 AAC channels,256 Cues. Absent is UNKNOWN.
   Added observedMask: 512 Colour master inspected,1024 matrix,2048 transfer,
   4096 primaries,8192 range,16384 bits,32768 chroma inspected,65536 HDR inspected,
   131072 VP9 range,262144 VP9 key dimensions,524288 AAC object type.
   Timing observedMask:1048576 plan kind,2097152 timing config,4194304 selected origin,
   8388608 source AAC anchor,16777216 packet clock,33554432 signed origin clock,
   67108864 leading empty edit. These bits clear at each plan start.
   Capacity observedMask:134217728 mux packet count/payload bytes,
   268435456 current packet bytes/track,536870912 closed output bytes,
   1073741824 staging bytes. These also clear at each plan start.
   Counts/bytes are observed before capacity guards, not accepted allocations.
   muxPayloadBytes is the whole fragment payload, not retained application RAM.
   muxFragmentBytes is the closed init size when reasonCode is 296.
   planKind:1 tail inspection,2 initial requested plan,3 subsequent GOP.
   Residuals are signed exact numerators (nanoseconds * sample rate), not ns.
   audioPreviousSourceIndex=-1 means no prior packet in this plan scan.
   Raw container fields use their own presence bit; chroma presence is separate.
   containerChromaPresence bits 0..5: subH,subV,cbH,cbV,sitingH,sitingV.
   containerHdrMask: 1 mastering,2 maxCLL,4 maxFALL. Zero after inspection means none.
   Codec enum: 0 unobserved,1 VP9/AAC respectively,2 other (no source strings).
   Video-only diagnostic codes: 3 AVC,4 HEVC,5 AV1; these remain unsupported.
   Stages: 0 prepared,1 source,2 headers,3 tracks,4 video metadata,5 audio metadata,
   6 Cues,7 selected key,8 audio timing,9 planner,10 mux,11 publication,
   12 backpressure,13 complete. First failure freezes stage/reason/traits. */
typedef struct SAPDiagnostics {
 uint32_t schema,stage,reasonCode;
 int32_t nativeCode;
 uint64_t observedMask;
 uint32_t trackCount,videoCodec,audioCodec,width,height,vp9Profile,vp9ColourSpace;
 uint32_t audioSampleRate,audioChannels,cueCount,publishedSegments;
 uint32_t containerColourPresent;
 int64_t containerMatrix,containerTransfer,containerPrimaries,containerRange,containerBitsPerChannel;
 int64_t containerChromaSubsamplingHorz,containerChromaSubsamplingVert;
 int64_t containerCbSubsamplingHorz,containerCbSubsamplingVert;
 int64_t containerChromaSitingHorz,containerChromaSitingVert;
 uint32_t containerChromaPresence,containerHdrMask,vp9FullRange,vp9KeyWidth,vp9KeyHeight,audioObjectType;
 uint32_t planKind;
 int64_t containerTimestampTickNS,audioCodecDelaySamples,audioSeekPrerollSamples;
 int64_t selectedVideoOriginNS,sourceAudioAnchorNS;
 int64_t audioPacketPTSNS,audioPacketSourceIndex,audioPacketResidual,audioPreviousSourceIndex;
 int64_t audioOriginDeltaNS,audioCutSample,audioOriginResidual,audioLeadingEmptyEditNS;
 uint64_t muxPacketCount,muxPayloadBytes,muxPacketBytes,muxFragmentBytes,muxStagingBytes;
 uint32_t muxPacketTrack;
 /* Cumulative completed operation timings, nanoseconds; nested scopes overlap.
    observedMask bit31: engine cost; bit32: startup contract. No identity/path. */
 uint64_t sourceReadCalls,sourceReadBytes,sourceReadNS,sourceValidateCalls,sourceValidateNS;
 uint64_t gpacWriteNS,gpacCloseNS,outputInspectNS,planNS;
 uint32_t startupTargetSeconds,startupRequiredSegments;
 /* observedMask bit33: current plan scan, observed before guards. Cleared per plan.
    Empty counts completed empty clusters; attempted clusters/blocks include rejection. */
 uint32_t metadataClusters,metadataEmptyClusters,metadataBlocks;
 /* observedMask bit34: cumulative bounded retiming policy observations.
    Count is unique successfully published AAC beyond the old +/-container tick.
    Max is absolute (rawPTS-anchor)*rate-slot*1024*1e9, including a rejected packet.
    LimitExceeded is 0/1. These do not reset between plans; first failure freezes.
    Policy min(10ms,511samples) is total relative to the original source anchor. */
 uint64_t audioRetimedPacketCount,audioRetimingMaxAbsResidual;
 uint32_t audioRetimingLimitExceeded;
} SAPDiagnostics;
int sap_diagnostics(SAP*,SAPDiagnostics*);
/* Copies a bounded immutable source-owned reason only, never exception text. */
int sap_reason_message(uint32_t code,char* output,uint32_t capacity);
typedef struct SAPSnapshot {
 uint64_t generation;
 int64_t requestedGlobalNS, verifiedKeyGlobalNS, itemOriginGlobalNS, requestedItemNS;
 int64_t publishedGlobalEndNS;
 uint32_t publishedSegments;
 int32_t state, sourceHasAudio, actualSourceEOF, windowComplete;
 uint32_t audioSampleRate, audioChannels;
 int32_t sourceEOFValidatedDuringPlan,terminalSegmentPublished;
 uint32_t stagingRetiredSegments;
 uint32_t width,height,targetDurationSeconds,totalSegments,startupSegments;
 int64_t wholePresentationEndNS,wholeVideoEndNS,wholeAudioEndNS;
 int64_t audioAnchorRawNS, codecDelaySamples, firstAudioSourceIndex, audioEditMediaTime;
 int64_t audioEditDurationNS, audioFirstDecodedGlobalNS, terminalDiscardSamples;
} SAPSnapshot;
/* Isolated local-source continuous candidate. Exactly one VP9 + one supported AAC-LC.
   maxUnackedSegments 1..12 controls staging backpressure; <=8192 video cues. No implicit audio drop. Single owner: cancel/join/destroy
   old before create new. Snapshot copies scalars, no borrowed strings.
   State 0 prepared, 1 running, 2 complete, 3 failed, 4 backpressured, 5 cancelled.
   All paths copied. Existing empty output dir; new receipt. Safe names unchanged. */
/* All callbacks run only on the single producer owner, never MainActor.
   Context must remain alive until sap_join returns. Exact read returns 0 only
   for requested count bytes, -1 error/true EOF, -2 invalidated/cancelled.
   knownSize is validated by source owner; it is not retained-memory size.
   validate/verify_eof return 1 for success, 0 for rejected/changed/cancelled. */
typedef int (*SAPReadExact)(void* context,uint64_t offset,uint32_t count,uint8_t* output);
typedef int (*SAPSourceCheck)(void* context);
typedef struct SAPSourceCallbacks {
 void* context; uint64_t knownSize;
 SAPReadExact readExact; SAPSourceCheck validate; SAPSourceCheck verifyEOF;
 /* Research capability, zero preserves generic callback behavior. Set to 1 only
    when readExact rejects unless admission and source revision are checked
    before AND after the exact read within the same coordinated operation.
    All consumers must rebuild for this isolated struct extension. */
 uint32_t readExactChecksRevision;
} SAPSourceCallbacks;
SAP* sap_create(SAPSourceCallbacks source,const char* output,const char* receipt,
 uint64_t generation,int64_t requestedGlobalNS,unsigned maxUnackedSegments);
int sap_start(SAP*);
void sap_cancel(SAP*);
void sap_join(SAP*);
void sap_destroy(SAP*);
int sap_status(SAP*);
int sap_snapshot(SAP*,SAPSnapshot*);
typedef struct SAPSegmentInfo { uint32_t index;int64_t durationNS,globalStartNS,globalEndNS; } SAPSegmentInfo;
int sap_segment_info(SAP*,uint32_t index,SAPSegmentInfo*);
int sap_error(SAP*,char* output,uint32_t capacity);
int sap_ack_imported(SAP*,uint32_t index);
#ifdef __cplusplus
}
#endif
