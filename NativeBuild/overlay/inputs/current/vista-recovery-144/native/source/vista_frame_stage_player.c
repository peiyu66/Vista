#ifdef HAVE_CONFIG_H
#include "config.h"
#endif
#include <vlc_common.h>
#include <vlc_aout.h>
#include <vlc/libvlc.h>
#include <vlc/libvlc_media_player.h>
#include "libvlc_internal.h"
#include "media_player_internal.h"
#include "vista_frame_stage_internal.h"
#include <string.h>
int vista_frame_stage_arm(libvlc_media_player_t*p,uint64_t session,uint64_t command,uint64_t revision,uint64_t seek,vista_frame_stage_mark*out){
 if(!out)return VFS_INVALID;memset(out,0,sizeof(*out));out->abi_version=VISTA_FRAME_STAGE_ABI;
 if(!p)return out->status=VFS_INVALID;audio_output_t*a=vlc_player_aout_Hold(p->player);if(!a)return out->status=VFS_UNAVAILABLE;
 const void*main=vrr_frame_main_key(a);int result=vfs_arm_key(main,session,command,revision,seek,vlc_tick_now(),out);aout_Release(a);return result;
}

int vista_queue_pressure_snapshot(libvlc_media_player_t*p,vista_queue_pressure_snapshot_data*out){
 if(!out)return VFS_INVALID;memset(out,0,sizeof(*out));out->abi_version=VISTA_QUEUE_PRESSURE_ABI;
 if(!p)return out->status=VFS_INVALID;
 audio_output_t*a=vlc_player_aout_Hold(p->player);if(!a)return out->status=VFS_UNAVAILABLE;
 const void*main=vrr_frame_main_key(a);int result=vfs_pressure_snapshot_key(main,vlc_tick_now(),out);
 aout_Release(a);return result;
}
