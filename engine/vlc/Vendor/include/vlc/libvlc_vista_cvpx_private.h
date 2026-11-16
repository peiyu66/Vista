/* Research-only setter for a newly-created, stopped player with no media.
 * Owner keeps bridge alive until stop, player release, and all leases drain.
 * Do not combine with other video-output setters. This is not upstream ABI. */
#ifndef LIBVLC_VISTA_CVPX_PRIVATE_H
#define LIBVLC_VISTA_CVPX_PRIVATE_H
#include <vlc/vlc.h>
typedef struct vista_cvpx_bridge vista_cvpx_bridge;
LIBVLC_API int libvlc_vista_set_cvpx_bridge(libvlc_media_player_t *, vista_cvpx_bridge *);
#endif
