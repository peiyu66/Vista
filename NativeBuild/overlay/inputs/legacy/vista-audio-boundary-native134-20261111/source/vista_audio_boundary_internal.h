#ifndef VISTA_AUDIO_BOUNDARY_INTERNAL_H
#define VISTA_AUDIO_BOUNDARY_INTERNAL_H
#include "vista_audio_boundary.h"
#include <stddef.h>
uint64_t vab_register(const void *aout, int64_t now);
void vab_retire(uint64_t id);
void vab_reset(uint64_t id, int64_t now);
void vab_change(uint64_t id, int64_t now, double rate);
void vab_block(uint64_t id, int64_t now, double rate, int64_t system, int64_t audio, const void *block);
void vab_enqueue(const void *aout, const void *block, int64_t now, int64_t date, int64_t fifo, int64_t length);
void vab_report(const void *aout, int64_t now, int64_t system, int64_t audio);
void vab_notify(uint64_t id, int64_t now, double rate, int64_t boundary,
                int64_t system, int64_t audio, int64_t corrected, int accepted);
int vab_mark(const void *aout, uint64_t session, uint64_t command, double rate,
             int64_t now, vista_audio_boundary_mark *out);
int64_t vab_now(void);
#endif
