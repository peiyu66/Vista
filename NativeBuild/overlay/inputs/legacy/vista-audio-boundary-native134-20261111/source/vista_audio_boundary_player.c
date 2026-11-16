#ifdef HAVE_CONFIG_H
#include "config.h"
#endif
#include <vlc_common.h>
#include <vlc_aout.h>
#include <vlc/libvlc.h>
#include <vlc/libvlc_media_player.h>
#include "libvlc_internal.h"
#include "media_player_internal.h"
#include "vista_audio_boundary_internal.h"
#include <string.h>
int64_t vab_now(void) { return vlc_tick_now(); }
int vista_audio_boundary_mark_command(libvlc_media_player_t *player,
    uint64_t session,uint64_t command,double rate,vista_audio_boundary_mark *out) {
    if(!out)return VAB_INVALID;
    memset(out,0,sizeof(*out));out->abi_version=VISTA_AUDIO_BOUNDARY_ABI;
    if(!player)return out->status=VAB_INVALID;
    /* Same official reference acquisition used by libvlc audio getters.
     * This control-side call is never invoked from the render callback. */
    audio_output_t *aout=vlc_player_aout_Hold(player->player);
    if(!aout)return out->status=VAB_UNAVAILABLE;
    int status=vab_mark(aout,session,command,rate,vlc_tick_now(),out);
    aout_Release(aout);return status;
}
