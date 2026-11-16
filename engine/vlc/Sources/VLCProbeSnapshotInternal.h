#ifndef VISTA_VLC_PROBE_SNAPSHOT_INTERNAL_H
#define VISTA_VLC_PROBE_SNAPSHOT_INTERNAL_H
/* C-only seam shared by actual engine and bounded synthetic ownership test. */
typedef struct vista_cvpx_bridge vista_cvpx_bridge;
VLCProbeSnapshot *VLCProbeTakeBridgeSnapshot(vista_cvpx_bridge *);
#endif
