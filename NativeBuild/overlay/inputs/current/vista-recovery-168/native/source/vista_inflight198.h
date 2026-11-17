#ifndef VISTA_INFLIGHT198_H
#define VISTA_INFLIGHT198_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <assert.h>
/* Locked credit ledger for at most three pending one-frame callbacks.
 * Callback entry transfers frame_info ownership to the original callback/DPB.
 * Successful API return does not touch that memory or reserve a second credit.
 * A direct error has no callback per VT's contract, and releases its credit.
 * This ledger is NOT a callback-body lifetime fence: retain VTWaitForAsync. */
#define VI198_CAP 3
typedef struct {uint64_t id,epoch,provenance;void *info;} vi198_ticket;
typedef struct {vi198_ticket tickets[VI198_CAP];uint64_t next,epoch;unsigned outstanding,peak;} vi198_state;
static inline void vi198_init(vi198_state*s){memset(s,0,sizeof(*s));s->epoch=1;}
static inline vi198_ticket*vi198_find(vi198_state*s,uint64_t id){for(unsigned i=0;i<VI198_CAP;++i)if(id&&s->tickets[i].id==id)return &s->tickets[i];return NULL;}
static inline uint64_t vi198_reserve(vi198_state*s,void*info,uint64_t provenance){
 if(s->outstanding>=VI198_CAP)return 0;
 for(unsigned i=0;i<VI198_CAP;++i)if(!s->tickets[i].id){
  s->next=(s->next+1)&(UINT64_MAX>>1);if(!s->next)++s->next;
  s->tickets[i]=(vi198_ticket){s->next,s->epoch,provenance,info};++s->outstanding;
  if(s->peak<s->outstanding)s->peak=s->outstanding;return s->next;
 }
 assert(!"credit ledger mismatch");return 0;
}
static inline void*vi198_callback(vi198_state*s,uint64_t id,uint64_t*provenance){
 vi198_ticket*t=vi198_find(s,id);if(!t)return NULL;
 void*p=t->info;*provenance=t->provenance;memset(t,0,sizeof(*t));assert(s->outstanding);--s->outstanding;return p;
}
static inline void*vi198_return(vi198_state*s,uint64_t id,bool error){if(!error)return NULL;uint64_t provenance;return vi198_callback(s,id,&provenance);}
static inline bool vi198_quiet(vi198_state*s){return !s->outstanding;}
/* Call only AFTER VT's completion fence, not merely when credits reach zero. */
static inline bool vi198_epoch(vi198_state*s){if(!vi198_quiet(s))return false;++s->epoch;return true;}
#endif
