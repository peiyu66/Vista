#ifdef HAVE_CONFIG_H
#include "config.h"
#endif
#include <vlc_common.h>
#include <vlc/libvlc.h>
#include <vlc/libvlc_media_player.h>
#include "libvlc_internal.h"
#include "media_player_internal.h"
#include "src/player/player.h"
#include "src/input/input_internal.h"
#include "vista_hold187_internal.h"
VHRRequest *vista_hold187_request(void *opaque,VHRInput x){
 libvlc_media_player_t *p=opaque;if(!p)return NULL;
 VHRRequest *r=vhr_new(x);if(!r)return NULL;
 vlc_player_Lock(p->player);struct vlc_player_input *in=vlc_player_get_input_locked(p->player);
 if(!in||!in->thread||in->state!=VLC_PLAYER_STATE_PLAYING){vlc_player_Unlock(p->player);vhr_release(r);return NULL;}
 vhr_retain(r);input_control_param_t param={.val.p_address=r};
 /* Push owns the queued reference even on rejection through ControlRelease. */
 int status=input_ControlPush(in->thread,VHR_INPUT_BEGIN,&param);
 vlc_player_Unlock(p->player);
 if(status!=VLC_SUCCESS){vhr_release(r);return NULL;}
 return r;
}
VHRResult vista_hold187_poll(VHRRequest*r){return vhr_read(r);}
void vista_hold187_cancel(VHRRequest*r){if(r)atomic_store(&r->cancel,true);}
void vista_hold187_cancel_paused(VHRRequest*r){if(r){atomic_store(&r->preserve_pause,true);atomic_store(&r->cancel,true);}}
void vista_hold187_release(VHRRequest*r){vhr_release(r);}
