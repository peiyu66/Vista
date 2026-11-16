#ifdef HAVE_CONFIG_H
#include "config.h"
#endif
#include <vlc_common.h>
#include <vlc_aout.h>
#include <vlc/libvlc.h>
#include <vlc/libvlc_media_player.h>
#include "libvlc_internal.h"
#include "media_player_internal.h"
#include "vista_resume_observer_internal.h"
#include <string.h>
int64_t vrr_now(void){return vlc_tick_now();}
int vista_resume_observer_arm(libvlc_media_player_t*player,uint64_t session,uint64_t command,uint64_t revision,uint64_t seek,vista_resume_mark*out){
 if(!out)return VRR_INVALID;memset(out,0,sizeof(*out));out->abi_version=VISTA_RESUME_OBSERVER_ABI;
 if(!player)return out->status=VRR_INVALID;
 audio_output_t*aout=vlc_player_aout_Hold(player->player);if(!aout)return out->status=VRR_UNAVAILABLE;
 int status=vrr_arm(aout,session,command,revision,seek,vlc_tick_now(),out);aout_Release(aout);return status;
}
