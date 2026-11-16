/*****************************************************************************
 * dec.c : audio output API towards decoders
 *****************************************************************************
 * Copyright (C) 2002-2019 VLC authors, VideoLAN and Videolabs SAS
 *
 * Authors: Christophe Massiot <massiot@via.ecp.fr>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

/*****************************************************************************
 * Preamble
 *****************************************************************************/
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <assert.h>
#include "vista_audio_boundary_internal.h"
#include "vista_resume_observer_internal.h"
#include "vista_audio_rate_map.h"
#include "flow/vista_flow_trace.h"
#include "vista_audio_flow144.h"

#include <math.h>

#include <vlc_common.h>
#include <vlc_aout.h>
#include <vlc_tracer.h>

#include "src/clock/clock.h"
#include "aout_internal.h"
#include "clock/clock.h"
#include "../libvlc.h"

#define BLOCK_FLAG_CORE_PRIVATE_FILTERED (1 << BLOCK_FLAG_CORE_PRIVATE_SHIFT)

struct vlc_aout_stream
{
    aout_instance_t *instance;
    uint64_t vista_boundary_id; /* anonymous diagnostic identity */
    uint64_t vista_resume_id;
    VAM vista_rate_map; /* existing timing.lock; actual output sample domain */
    uint64_t vista_rate_command;
    float vista_filter_rate; /* rate actually passed to the last FiltersPlay */
    uint64_t vista_rate_serial,vista_filter_serial,vista_filter_command;
    uint64_t vista_summary_serial;
    vlc_tick_t vista_summary_boundary;
    bool vista_summary_open;
    aout_volume_t *volume;
    aout_filters_t *filters;
    aout_filters_cfg_t filters_cfg;

    atomic_bool drained;
    _Atomic vlc_tick_t drain_deadline;

    struct
    {
        bool draining;
        block_t **fifo_last;
        block_t *fifo_first;
    } discontinuity;

    struct
    {
        struct vlc_clock_t *clock;
        uint32_t clock_id;
        float rate; /**< Play-out speed rate */
        vlc_tick_t resamp_start_drift; /**< Resampler drift absolute value */
        int resamp_type; /**< Resampler mode (FIXME: redundant / resampling) */
        bool played;
        vlc_tick_t request_delay;
        vlc_tick_t delay;
    } sync;

    struct
    {
        vlc_mutex_t lock; /* Guard first_pts, last_drift, rate_system_ts,
                             rate_audio_ts, system_ts, audio_ts */

        vlc_tick_t last_drift;

        vlc_tick_t first_pts;
        int64_t played_samples; /* Used for stream_GetDelay() emulation */

        vlc_tick_t rate_system_ts;
        vlc_tick_t rate_audio_ts;

        vlc_tick_t system_ts;
        vlc_tick_t audio_ts;

        vlc_tick_t pause_date;
        float rate;
    } timing;

    const char *str_id;

    /* Original input format and profile, won't change for the lifetime of a
     * stream (between vlc_aout_stream_New() and vlc_aout_stream_Delete()). */
    int                   input_profile;
    audio_sample_format_t input_format;

    /* Format used to configure the conversion filters. It is based on the
     * input_format but its fourcc can be different when the module is handling
     * codec passthrough. Indeed, in case of DTSHD->DTS or EAC3->AC3 fallback,
     * the filter need to know which codec is handled by the output. */
    audio_sample_format_t filter_format;

    /* Output format used and modified by the module. */
    audio_sample_format_t mixer_format;

    atomic_uchar restart;

    atomic_uint buffers_lost;
    atomic_uint buffers_played;
};

static inline aout_owner_t *aout_stream_owner(vlc_aout_stream *stream)
{
    return &stream->instance->owner;
}

static inline audio_output_t *aout_stream_aout(vlc_aout_stream *stream)
{
    return &stream->instance->output;
}

static inline struct vlc_tracer *aout_stream_tracer(vlc_aout_stream *stream)
{
    return stream->str_id == NULL ? NULL :
        vlc_object_get_tracer(VLC_OBJECT(aout_stream_aout(stream)));
}

static int stream_GetDelay(vlc_aout_stream *stream, vlc_tick_t *delay)
{
    vlc_mutex_assert(&stream->timing.lock);
    vlc_tick_t system_ts = stream->timing.system_ts;
    vlc_tick_t audio_ts = stream->timing.audio_ts;
    if (system_ts == VLC_TICK_INVALID)
        return -1;

    /* Interpolate the last updated point. */
    vlc_tick_t system_now = vlc_tick_now();

    /* Use all samples sent to the aout via the play function (normal
     * blocks, silence blocks, resampled correction) */
    vlc_tick_t played_length =
        vlc_tick_from_samples(stream->timing.played_samples,
                              stream->mixer_format.i_rate);
    vlc_tick_t last_pts = stream->timing.first_pts + played_length;

    /* Equivalent to vlc_clock_ConvertToSystem(), but assume the
     * coefficient is 1.0 (audio at the same speed than the monotonic
     * clock) since the calculation is done on a very small interval
     * (generally less than 2 seconds). */
    vlc_tick_t play_date = last_pts - audio_ts + system_ts;
    *delay = play_date - system_now;
    return 0;
}

static bool stream_IsDrained(vlc_aout_stream *stream)
{
    audio_output_t *aout = aout_stream_aout(stream);

    if (aout->drain == NULL)
    {
        vlc_tick_t drain_deadline =
            atomic_load_explicit(&stream->drain_deadline, memory_order_relaxed);
        return drain_deadline != VLC_TICK_INVALID
            && vlc_tick_now() >= drain_deadline;
    }
    else
        return atomic_load_explicit(&stream->drained, memory_order_relaxed);
}

static int stream_StartDiscontinuity(vlc_aout_stream *stream, block_t *block)
{
    audio_output_t *aout = aout_stream_aout(stream);
    struct vlc_tracer *tracer = aout_stream_tracer(stream);
    assert(!stream->discontinuity.draining);

    /* Changing timings of the stream module while playing is an intricate
     * task, therefore modules don't handle any PTS discontinuity.
     *
     * The PTS discontinuity is handled in the core:
     *
     *  - Drain the current stream in case of discontinuity
     *  - Check from future Play() calls if the stream is drained
     *  - Keep blocks in a list while waiting for the drain
     *  - Flush when the stream is finally drained
     *  - Play back all blocks that were saved
     */

    if (tracer != NULL)
        vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id,
                              "discontinuity_start");

    msg_Dbg(aout, "discontinuity: at %"PRId64" us, draining output",
            block->i_pts);
    vlc_aout_stream_Drain(stream);
    stream->discontinuity.draining = true;

    stream->discontinuity.fifo_first = NULL;
    stream->discontinuity.fifo_last = &stream->discontinuity.fifo_first;

    block->i_flags &= ~ BLOCK_FLAG_DISCONTINUITY;
    block_ChainLastAppend(&stream->discontinuity.fifo_last, block);

    return AOUT_DEC_SUCCESS;
}

static void stream_ResetDiscontinuity(vlc_aout_stream *stream)
{
    block_ChainRelease(stream->discontinuity.fifo_first);
    stream->discontinuity.draining = false;
}

static int stream_HandleDiscontinuity(vlc_aout_stream *stream, block_t *block)
{
    audio_output_t *aout = aout_stream_aout(stream);
    struct vlc_tracer *tracer = aout_stream_tracer(stream);

    block_ChainLastAppend(&stream->discontinuity.fifo_last, block);

    /* Will play back all blocks once the draining is finished */
    if (!stream_IsDrained(stream))
        return AOUT_DEC_SUCCESS;

    /* Keep block list and stats before flushing */
    int count;
    vlc_tick_t length;
    block_ChainProperties(stream->discontinuity.fifo_first, &count, NULL,
                          &length);
    block = stream->discontinuity.fifo_first;

    if (tracer != NULL)
        vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id,
                              "discontinuity_flush");

    msg_Dbg(aout, "discontinuity: flushing output");

    /* Reset the discontinuity state, and flush */
    stream->discontinuity.draining = false;
    vlc_aout_stream_Flush(stream);

    msg_Dbg(aout, "discontinuity: playing back %d blocks for a total length of "
            "%"PRId64" us", count, length);

    if (tracer != NULL)
        vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id,
                              "discontinuity_play");

    /* Play back all blocks past the discontinuity */
    for (block_t *next; block != NULL; block = next)
    {
        next = block->p_next;
        block->p_next = NULL;

        vlc_aout_stream_Play(stream, block);
    }

    if (tracer != NULL)
        vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id,
                              "discontinuity_end");

    return AOUT_DEC_SUCCESS;
}

static void VistaRateMapReset(vlc_aout_stream *stream);

static void stream_ResetTimings(vlc_aout_stream *stream)
{
    vab_reset(stream->vista_boundary_id, vlc_tick_now());
    stream->sync.played = false;

    vlc_mutex_lock(&stream->timing.lock);
    stream->vista_summary_open=false;stream->vista_summary_serial=0;
    stream->vista_summary_boundary=VLC_TICK_INVALID;
    stream->timing.first_pts = VLC_TICK_INVALID;
    stream->timing.last_drift = VLC_TICK_INVALID;
    stream->timing.system_ts = VLC_TICK_INVALID;
    stream->timing.audio_ts = VLC_TICK_INVALID;
    vlc_mutex_unlock(&stream->timing.lock);

    stream->timing.pause_date = VLC_TICK_INVALID;
    stream->timing.played_samples = 0;
}

static void stream_Reset(vlc_aout_stream *stream)
{
    aout_owner_t *owner = aout_stream_owner(stream);

    if (stream->mixer_format.i_format)
    {
        vlc_audio_meter_Flush(&owner->meter);

        if (stream->filters)
        {
            aout_FiltersFlush (stream->filters);
            aout_FiltersAdjustResampling (stream->filters, 0);
        }
        stream->sync.resamp_type = AOUT_RESAMPLING_NONE;

        vlc_clock_Lock(stream->sync.clock);
        vlc_clock_Reset(stream->sync.clock);
        vlc_clock_Unlock(stream->sync.clock);
        if (stream->filters)
            aout_FiltersResetClock(stream->filters);

        if (stream->sync.delay > 0)
        {
            /* Also reset the delay in case of a positive delay. This will
             * trigger a silence playback before the next play. Consequently,
             * the first play date won't be (delay + dejitter) but only
             * dejitter. This will allow the aout to update the master clock
             * sooner.
             */
            vlc_clock_Lock(stream->sync.clock);
            vlc_clock_SetDelay(stream->sync.clock, 0);
            vlc_clock_Unlock(stream->sync.clock);
            if (stream->filters)
                aout_FiltersSetClockDelay(stream->filters, 0);
            stream->sync.request_delay = stream->sync.delay;
            stream->sync.delay = 0;
        }

        if (stream->discontinuity.draining)
            stream_ResetDiscontinuity(stream);
    }

    stream->timing.rate_audio_ts = VLC_TICK_INVALID;
    stream->timing.rate = 1.0;

    atomic_store_explicit(&stream->drained, false, memory_order_relaxed);
    atomic_store_explicit(&stream->drain_deadline, VLC_TICK_INVALID,
                          memory_order_relaxed);

    stream_ResetTimings(stream);
}

/**
 * Creates an audio output
 */
vlc_aout_stream * vlc_aout_stream_New(audio_output_t *p_aout,
                                      const struct vlc_aout_stream_cfg *cfg)
{
    assert(p_aout);
    assert(cfg->fmt);
    assert(cfg->clock);
    const audio_sample_format_t *p_format = cfg->fmt;

    if( p_format->i_bitspersample > 0 )
    {
        /* Sanitize audio format, input need to have a valid physical channels
         * layout or a valid number of channels. */
        int i_map_channels = aout_FormatNbChannels( p_format );
        if( ( i_map_channels == 0 && p_format->i_channels == 0 )
           || i_map_channels > AOUT_CHAN_MAX || p_format->i_channels > INPUT_CHAN_MAX )
        {
            msg_Err( p_aout, "invalid audio channels count" );
            return NULL;
        }
    }

    if( p_format->i_rate > 768000 )
    {
        msg_Err( p_aout, "excessive audio sample frequency (%u)",
                 p_format->i_rate );
        return NULL;
    }
    if( p_format->i_rate < 4000 )
    {
        msg_Err( p_aout, "too low audio sample frequency (%u)",
                 p_format->i_rate );
        return NULL;
    }

    aout_owner_t *owner = aout_owner(p_aout);

    vlc_aout_stream *stream = malloc(sizeof(*stream));
    if (stream == NULL)
        return NULL;
    stream->instance = aout_instance(p_aout);
    stream->vista_boundary_id = 0;
    stream->vista_resume_id = 0;
    memset(&stream->vista_rate_map,0,sizeof(stream->vista_rate_map));
    stream->vista_rate_command=0;
    stream->vista_filter_rate=1.f;
    stream->vista_rate_serial=stream->vista_filter_serial=stream->vista_filter_command=0;
    stream->vista_summary_serial=0;stream->vista_summary_boundary=VLC_TICK_INVALID;
    stream->vista_summary_open=false;

    stream->volume = NULL;
    if (!owner->bitexact)
        stream->volume = aout_volume_New (p_aout, cfg->replay_gain);

    atomic_init(&stream->restart, 0);
    stream->input_profile = cfg->profile;
    stream->filter_format = stream->mixer_format = stream->input_format = *p_format;

    stream->sync.clock = cfg->clock;
    stream->sync.clock_id = 0;
    stream->str_id = cfg->str_id;

    stream->timing.rate_audio_ts = VLC_TICK_INVALID;
    stream->timing.rate = 1.f;

    vlc_mutex_init(&stream->timing.lock);

    stream->sync.rate = 1.f;
    stream->sync.resamp_type = AOUT_RESAMPLING_NONE;
    stream->sync.delay = stream->sync.request_delay = 0;

    stream->discontinuity.draining = false;
    stream_ResetTimings(stream);

    atomic_init (&stream->buffers_lost, 0);
    atomic_init (&stream->buffers_played, 0);
    atomic_store_explicit(&owner->vp.update, true, memory_order_relaxed);

    atomic_init(&stream->drained, false);
    atomic_init(&stream->drain_deadline, VLC_TICK_INVALID);

    stream->filters = NULL;
    stream->filters_cfg = AOUT_FILTERS_CFG_INIT;
    if (aout_OutputNew(p_aout, stream, &stream->mixer_format, stream->input_profile,
                       &stream->filter_format, &stream->filters_cfg))
        goto error;

    vlc_audio_meter_Reset(&owner->meter, &stream->mixer_format);

    if (!owner->bitexact)
    {
        if (stream->volume != NULL)
            aout_volume_SetFormat(stream->volume, stream->mixer_format.i_format);

        /* Create the audio filtering "input" pipeline */
        stream->filters = aout_FiltersNewWithClock(VLC_OBJECT(p_aout), cfg->clock,
                                                   &stream->filter_format,
                                                   &stream->mixer_format,
                                                   &stream->filters_cfg);
        if (stream->filters == NULL)
        {
            aout_OutputDelete (p_aout);
            vlc_audio_meter_Reset(&owner->meter, NULL);

error:
            if (stream->volume != NULL)
                aout_volume_Delete(stream->volume);
            free(stream);
            return NULL;
        }
    }

    stream->vista_boundary_id = vab_register(p_aout, vlc_tick_now());
    stream->vista_resume_id = vrr_register(p_aout,vlc_clock_VistaMainKey(stream->sync.clock));
    return stream;
}

/**
 * Stops all plugins involved in the audio output.
 */
void vlc_aout_stream_Delete (vlc_aout_stream *stream)
{
    audio_output_t *aout = aout_stream_aout(stream);
    aout_owner_t *owner = aout_stream_owner(stream);

    if (stream->mixer_format.i_format)
    {
        vlc_audio_meter_Reset(&owner->meter, NULL);
        if (stream->filters)
            aout_FiltersDelete (aout, stream->filters);
        aout_OutputDelete (aout);

        vlc_clock_Lock(stream->sync.clock);
        vlc_clock_Reset(stream->sync.clock);
        vlc_clock_Unlock(stream->sync.clock);
    }
    if (stream->volume != NULL)
        aout_volume_Delete(stream->volume);

    if (stream->discontinuity.draining)
        stream_ResetDiscontinuity(stream);

    vab_retire(stream->vista_boundary_id);
    vrr_retire(stream->vista_resume_id);
    free(stream);
}

static int stream_CheckReady (vlc_aout_stream *stream)
{
    aout_owner_t *owner = aout_stream_owner(stream);
    audio_output_t *aout = aout_stream_aout(stream);
    int status = AOUT_DEC_SUCCESS;

    int restart = atomic_exchange_explicit(&stream->restart, 0,
                                           memory_order_acquire);
    if (unlikely(restart != 0))
    {
        if (stream->filters)
        {
            aout_FiltersDelete (aout, stream->filters);
            stream->filters = NULL;
        }

        struct vlc_tracer *tracer = aout_stream_tracer(stream);

        if (restart & AOUT_RESTART_OUTPUT)
        {   /* Reinitializes the output */
            if (tracer != NULL)
                vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "restart");

            msg_Dbg (aout, "restarting output...");
            if (stream->mixer_format.i_format)
                aout_OutputDelete (aout);
            stream->filter_format = stream->mixer_format = stream->input_format;
            stream->filters_cfg = AOUT_FILTERS_CFG_INIT;

            VistaRateMapReset(stream); /* OutputDelete completed: raw samples restart. */
            stream_Reset(stream);

            if (aout_OutputNew(aout, stream, &stream->mixer_format, stream->input_profile,
                               &stream->filter_format, &stream->filters_cfg))
                stream->mixer_format.i_format = 0;
            if (stream->volume != NULL)
                aout_volume_SetFormat(stream->volume,
                                      stream->mixer_format.i_format);

            /* Notify the decoder that the aout changed in order to try a new
             * suitable codec (like an HDMI audio format). However, keep the
             * same codec if the aout was restarted because of a stereo-mode
             * change from the user. */
            if ((restart & AOUT_RESTART_OUTPUT_DEC) == AOUT_RESTART_OUTPUT_DEC)
                status = AOUT_DEC_CHANGED;
        }
        else if (tracer != NULL)
            vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "filters_restart");

        msg_Dbg (aout, "restarting filters...");
        stream->sync.resamp_type = AOUT_RESAMPLING_NONE;

        if (stream->mixer_format.i_format && !owner->bitexact)
        {
            stream->filters = aout_FiltersNewWithClock(VLC_OBJECT(aout),
                                                       stream->sync.clock,
                                                       &stream->filter_format,
                                                       &stream->mixer_format,
                                                       &stream->filters_cfg);
            if (stream->filters == NULL)
            {
                aout_OutputDelete (aout);
                stream->mixer_format.i_format = 0;
            }
            aout_FiltersSetClockDelay(stream->filters, stream->sync.delay);
        }

        vlc_audio_meter_Reset(&owner->meter,
                              stream->mixer_format.i_format ? &stream->mixer_format : NULL);

        /* TODO: This would be a good time to call clean up any video output
         * left over by an audio visualization:
        input_resource_TerminatVout(MAGIC HERE); */
    }
    return (stream->mixer_format.i_format) ? status : AOUT_DEC_FAILED;
}

/**
 * Marks the audio output for restart, to update any parameter of the output
 * plug-in (e.g. output device or channel mapping).
 */
void vlc_aout_stream_RequestRestart(vlc_aout_stream *stream, unsigned mode)
{
    audio_output_t *aout = aout_stream_aout(stream);
    atomic_fetch_or_explicit(&stream->restart, mode, memory_order_release);
    msg_Dbg (aout, "restart requested (%u)", mode);
}

/*
 * Buffer management
 */

static void stream_StopResampling(vlc_aout_stream *stream)
{
    assert(stream->filters);

    stream->sync.resamp_type = AOUT_RESAMPLING_NONE;
    aout_FiltersAdjustResampling (stream->filters, 0);
}

static bool VistaRateMapSupported(vlc_aout_stream *stream)
{
    return AOUT_FMT_LINEAR(&stream->mixer_format) &&
           stream->mixer_format.i_frame_length==1 &&
           stream->mixer_format.i_bytes_per_frame>0 && stream->mixer_format.i_rate>0;
}

/* Existing timing.lock held. This identity is independent of trace retention. */
static void VistaAudioBoundaryBlock(vlc_aout_stream *stream,uint64_t serial,
                                    double rate,vlc_tick_t date,vlc_tick_t pts,const void *block)
{
    if(!stream->vista_summary_open || serial!=stream->vista_rate_serial ||
       (serial==stream->vista_summary_serial && stream->vista_summary_boundary!=VLC_TICK_INVALID))return;
    stream->vista_summary_serial=serial;stream->vista_summary_boundary=date;
    vab_block(stream->vista_boundary_id,vlc_tick_now(),rate,date,pts,block);
}

static void VistaRateMapReset(vlc_aout_stream *stream)
{
    vlc_mutex_lock(&stream->timing.lock);
    vam_reset(&stream->vista_rate_map);
    VFNew(VF_AUDIO_MAP_RESET,VF_POINT,stream->vista_rate_command,
          stream->vista_boundary_id,stream->vista_rate_map.generation,0);
    vlc_mutex_unlock(&stream->timing.lock);
}

#include "vista_audio_boundary162.h"

static void stream_Play(vlc_aout_stream *stream, block_t *block,
                        vlc_tick_t date,double output_rate,uint64_t output_serial,
                        uint64_t output_command,bool silence)
{
    audio_output_t *aout=aout_stream_aout(stream);
    /* Output modules don't handle empty blocks */
    assert(block->i_buffer > 0);
    bool vista_output_valid=VistaRateMapSupported(stream);
    if(vista_output_valid) {
        VF_VOID(VAF_TIMING_LOCK,vlc_mutex_lock(&stream->timing.lock));
        const unsigned stride=stream->mixer_format.i_bytes_per_frame;
        VAMSegment segment;int64_t continuity=0;
        int status=VAM_INVALID;
        if(block->i_buffer%stride==0)
            status=VF_CALL(VAF_MAP_ENQUEUE,vam_enqueue(&stream->vista_rate_map,block->i_pts,block->i_buffer/stride,
                stream->mixer_format.i_rate,output_rate,silence,date,output_serial,
                output_serial==stream->vista_summary_serial?stream->vista_summary_boundary:VLC_TICK_INVALID,
                &segment,&continuity));
        else stream->vista_rate_map.poisoned=true;
        if(status==VAM_OK) {
            uint64_t id=VFNew(VF_AUDIO_SEGMENT,VF_POINT,output_command,
                segment.raw,segment.media,(int64_t)(segment.rate*1000000));
            vam_identify_last(&stream->vista_rate_map,id,output_command);
            VFEmit(id,VF_AUDIO_SEGMENT_META,VF_POINT,0,segment.scheduled,continuity,
                (stream->vista_rate_map.overflow?2:0)|(silence?1:0)|(segment.reason==2?4:0)|(segment.reason==3?8:0));
            VFEmit(id,VAF_IDENTITY,VF_POINT,0,segment.serial,segment.command_boundary,stream->vista_rate_map.generation);
            VFEmit(id,VAF_MAP_ANCHOR,VF_POINT,0,segment.anchor_raw,segment.media,segment.reason);
        } else if(status==VAM_INVALID)
            VFNew(VF_AUDIO_MAP_FAILURE,VF_POINT,stream->vista_rate_command,status,
                  block->i_pts,stream->vista_rate_map.generation);
        vista_output_valid=status!=VAM_INVALID && !stream->vista_rate_map.poisoned && !stream->vista_rate_map.overflow;
        vlc_mutex_unlock(&stream->timing.lock);
    }
    VF_SCOPE(vista_audio_play,VF_AUDIO_PLAY,output_command,block->i_pts,date,block->i_nb_samples);
    vista_audio_play162(aout,block,date,output_serial,output_command,silence,vista_output_valid);
}

static void stream_Silence (vlc_aout_stream *stream, vlc_tick_t length, vlc_tick_t pts)
{
    assert(length > 0);
    audio_output_t *aout = aout_stream_aout(stream);
    const audio_sample_format_t *fmt = &stream->mixer_format;
    size_t frames = samples_from_vlc_tick(length, fmt->i_rate);
    size_t size = frames * fmt->i_bytes_per_frame / fmt->i_frame_length;

    block_t *block = block_Alloc (size);
    if (unlikely(block == NULL))
        return; /* uho! */

    msg_Dbg (aout, "inserting %zu zeroes / %"PRId64"ms", frames, MS_FROM_VLC_TICK(length));
    memset (block->p_buffer, 0, block->i_buffer);
    block->i_nb_samples = frames;
    block->i_pts = pts;
    block->i_dts = pts;
    block->i_length = length;

    const vlc_tick_t system_now = vlc_tick_now();
    vlc_clock_Lock(stream->sync.clock);
    const vlc_tick_t system_pts =
       vlc_clock_ConvertToSystem(stream->sync.clock, system_now, pts,
                                 stream->sync.rate, NULL);
    vlc_clock_Unlock(stream->sync.clock);
    stream->timing.played_samples += block->i_nb_samples;
    stream_Play(stream, block, system_pts,stream->sync.rate,stream->vista_rate_serial,stream->vista_rate_command,true);
}

static void stream_HandleDrift(vlc_aout_stream *stream, vlc_tick_t drift,
                               vlc_tick_t audio_ts)
{
    aout_owner_t *owner = aout_stream_owner(stream);
    audio_output_t *aout = aout_stream_aout(stream);
    assert(stream->sync.played);

    float rate = stream->sync.rate;

    if (owner->bitexact)
        return;

    struct vlc_tracer *tracer = aout_stream_tracer(stream);
    if (tracer != NULL)
        vlc_tracer_Trace(tracer, VLC_TRACE("type", "RENDER"),
                                 VLC_TRACE("id", stream->str_id),
                                 VLC_TRACE_TICK_NS("drift", drift),
                                 VLC_TRACE_END);

    /* Following calculations expect an opposite drift. Indeed,
     * vlc_clock_Update() returns a positive relative time, corresponding to
     * the time when audio_ts is expected to be played (in the future when not
     * late). */
    drift = -drift;

    /* Late audio output.
     * This can happen due to insufficient caching, scheduling jitter
     * or bug in the decoder. Ideally, the output would seek backward. But that
     * is not portable, not supported by some hardware and often unsafe/buggy
     * where supported. The other alternative is to flush the buffers
     * completely. */
    if (drift > lroundf(+3 * AOUT_MAX_PTS_DELAY / rate))
    {
        if (tracer != NULL)
            vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "late_flush");

        msg_Warn (aout, "playback way too late (%"PRId64"): "
                    "flushing buffers", drift);

        vlc_aout_stream_Flush(stream);
        stream_StopResampling(stream);

        return; /* nothing can be done if timing is unknown */
    }

    /* Early audio output.
     * This is rare except at startup when the buffers are still empty. */
    if (drift < lroundf(-3 * AOUT_MAX_PTS_ADVANCE / rate))
    {
        if (tracer != NULL)
            vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "early_silence");

        msg_Warn (aout, "playback way too early (%"PRId64"): "
                 "playing silence", drift);
        stream_Silence(stream, -drift, audio_ts);

        stream_StopResampling(stream);
        drift = 0;
    }

    if (!aout_FiltersCanResample(stream->filters))
        return;

    /* Resampling */
    if (drift > +AOUT_MAX_PTS_DELAY
     && stream->sync.resamp_type != AOUT_RESAMPLING_UP)
    {
        if (tracer != NULL)
            vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "late_upsampling");
        msg_Warn (aout, "playback too late (%"PRId64"): up-sampling",
                  drift);
        stream->sync.resamp_type = AOUT_RESAMPLING_UP;
        stream->sync.resamp_start_drift = +drift;
    }
    if (drift < -AOUT_MAX_PTS_ADVANCE
     && stream->sync.resamp_type != AOUT_RESAMPLING_DOWN)
    {
        if (tracer != NULL)
            vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "early_downsampling");
        msg_Warn (aout, "playback too early (%"PRId64"): down-sampling",
                  drift);
        stream->sync.resamp_type = AOUT_RESAMPLING_DOWN;
        stream->sync.resamp_start_drift = -drift;
    }

    if (stream->sync.resamp_type == AOUT_RESAMPLING_NONE)
        return; /* Everything is fine. Nothing to do. */

    if (llabs (drift) > 2 * stream->sync.resamp_start_drift)
    {   /* If the drift is ever increasing, then something is seriously wrong.
         * Cease resampling and hope for the best. */
        if (tracer != NULL)
            vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "timing_screwed");

        msg_Warn (aout, "timing screwed (drift: %"PRId64" us): "
                  "stopping resampling", drift);
        stream_StopResampling(stream);
        return;
    }

    /* Resampling has been triggered earlier. This checks if it needs to be
     * increased or decreased. Resampling rate changes must be kept slow for
     * the comfort of listeners. */
    int adj = (stream->sync.resamp_type == AOUT_RESAMPLING_UP) ? +2 : -2;

    if (2 * llabs (drift) <= stream->sync.resamp_start_drift)
        /* If the drift has been reduced from more than half its initial
         * value, then it is time to switch back the resampling direction. */
        adj *= -1;

    if (!aout_FiltersAdjustResampling (stream->filters, adj))
    {   /* Everything is back to normal: stop resampling. */
        stream->sync.resamp_type = AOUT_RESAMPLING_NONE;

        if (tracer != NULL)
            vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "stop_resampling");
        msg_Dbg (aout, "resampling stopped (drift: %"PRId64" us)", drift);
    }
}

static void stream_Synchronize(vlc_aout_stream *stream, vlc_tick_t system_now,
                               vlc_tick_t play_date, vlc_tick_t dec_pts, const void *vista_block,
                               double output_rate,uint64_t output_serial)
{
    /**
     * Depending on the drift between the actual and intended playback times,
     * the audio core may ignore the drift, trigger upsampling or downsampling,
     * insert silence or even discard samples.
     * Future VLC versions may instead adjust the input rate.
     *
     * The audio output plugin is responsible for estimating its actual
     * playback time, or rather the estimated time when the next sample will
     * be played. (The actual playback time is always the current time, that is
     * to say vlc_tick_now(). It is not an useful statistic.)
     *
     * Most audio output plugins can estimate the delay until playback of
     * the next sample to be written to the buffer, or equally the time until
     * all samples in the buffer will have been played. Then:
     *    pts = vlc_tick_now() + delay
     */
    vlc_tick_t delay;
    vlc_tick_t drift;
    assert(system_now != VLC_TICK_INVALID);

    VF_VOID(VAF_TIMING_LOCK,vlc_mutex_lock(&stream->timing.lock));
    if (stream->sync.rate != stream->timing.rate)
    {
        /* Save the first timing point seeing a rate change */
        stream->timing.rate_system_ts = play_date;
        stream->timing.rate_audio_ts = dec_pts;
        stream->timing.rate = stream->sync.rate;
    }
    VistaAudioBoundaryBlock(stream,output_serial,output_rate,play_date,dec_pts,vista_block);

    if (stream->timing.first_pts == VLC_TICK_INVALID)
        stream->timing.first_pts = dec_pts;

    bool is_drifting = stream->timing.last_drift != VLC_TICK_INVALID;

    if (!is_drifting)
    {
        /* stream is master: nothing to do */
        vlc_mutex_unlock(&stream->timing.lock);
        return;
    }
    int ret = stream_GetDelay(stream, &delay);
    vlc_mutex_unlock(&stream->timing.lock);

    if (ret != 0)
        return; /* nothing can be done if timing is unknown */

    drift = play_date - system_now - delay;

    stream_HandleDrift(stream, drift, dec_pts);
}

void vlc_aout_stream_NotifyTiming(vlc_aout_stream *stream, vlc_tick_t system_ts,
                                  vlc_tick_t audio_ts)
{
    vlc_mutex_lock(&stream->timing.lock);

    vlc_tick_t rate_audio_ts = stream->timing.rate_audio_ts;
    vlc_tick_t rate_system_ts = stream->timing.rate_system_ts;

    /* audio_ts is the output position: at rate != 1, it advances with the
     * output samples, like played_samples, not with the stream timestamps
     * of the clock. */
    vlc_tick_t clock_audio_ts = audio_ts;
    double report_rate=stream->timing.rate;
    vlc_tick_t report_boundary=rate_system_ts,report_anchor=rate_audio_ts;
    vlc_tick_t summary_boundary=rate_system_ts;
    bool summary_identity=true;
    if(VistaRateMapSupported(stream))
    {
        VAMSegment selected={0};
        int status=vam_report(&stream->vista_rate_map,audio_ts,&selected,&clock_audio_ts);
        uint64_t id=VFNew(VF_AUDIO_MAP_REPORT,VF_POINT,selected.id,
                          audio_ts,status==VAM_OK?clock_audio_ts:0,status);
        VFEmit(id,VF_AUDIO_MAP_SYSTEM,VF_POINT,0,system_ts,selected.scheduled,
               (int64_t)(selected.rate*1000000));
        if(status!=VAM_OK) {
            vlc_mutex_unlock(&stream->timing.lock);
            return;
        }
        report_rate=selected.rate;
        report_boundary=selected.scheduled;report_anchor=selected.media;
        summary_boundary=selected.command_boundary;
        summary_identity=stream->vista_summary_open && selected.serial!=0 && selected.serial==stream->vista_rate_serial &&
            selected.serial==stream->vista_summary_serial && summary_boundary!=VLC_TICK_INVALID;
        VFEmit(id,VAF_IDENTITY,VF_POINT,0,selected.serial,summary_boundary,summary_identity?1:0);
    }
    else if (rate_audio_ts != VLC_TICK_INVALID)
    {
        /* Drop timing updates that comes before the rate change */
        if (system_ts < rate_system_ts)
        {
            vista_resume_event vr={.tick_us=vlc_tick_now(),.present=27|VRR_HAS_RATE|VRR_HAS_REASON,
             .reason=1,.value={system_ts,audio_ts,0,rate_audio_ts!=VLC_TICK_INVALID?rate_system_ts:0,rate_audio_ts},.rate=stream->timing.rate};
            if(rate_system_ts==VLC_TICK_INVALID)vr.present&=~(UINT64_C(1)<<3);
            if(rate_audio_ts==VLC_TICK_INVALID){vr.present&=~((UINT64_C(1)<<3)|(UINT64_C(1)<<4));vr.value[3]=vr.value[4]=0;}
            vrr_emit_id(stream->vista_resume_id,VRR_REJECT,&vr);
            vab_notify(stream->vista_boundary_id, vlc_tick_now(), stream->timing.rate,
                       rate_system_ts, system_ts, audio_ts, 0, 0);
            vlc_mutex_unlock(&stream->timing.lock);
            return;
        }

        /* Fix the audio timestamp with the rate */
        clock_audio_ts = rate_audio_ts + (system_ts - rate_system_ts)
                         * stream->timing.rate;
    }

    vista_resume_event vr={.tick_us=vlc_tick_now(),.present=31|VRR_HAS_RATE|VRR_HAS_REASON,
     .reason=0,.value={system_ts,audio_ts,clock_audio_ts,report_anchor!=VLC_TICK_INVALID?report_boundary:0,report_anchor},.rate=report_rate};
    if(report_boundary==VLC_TICK_INVALID)vr.present&=~(UINT64_C(1)<<3);
    if(report_anchor==VLC_TICK_INVALID){vr.present&=~((UINT64_C(1)<<3)|(UINT64_C(1)<<4));vr.value[3]=vr.value[4]=0;}
    vrr_emit_id(stream->vista_resume_id,VRR_ACCEPT,&vr);
    if(summary_identity)
        vab_notify(stream->vista_boundary_id, vlc_tick_now(), report_rate,
                   summary_boundary, system_ts, audio_ts, clock_audio_ts, 1);
    stream->timing.system_ts = system_ts;
    stream->timing.audio_ts = audio_ts;
    vlc_clock_Lock(stream->sync.clock);
    stream->timing.last_drift =
        vlc_clock_Update(stream->sync.clock, system_ts,
                         clock_audio_ts, report_rate);
    vlc_clock_Unlock(stream->sync.clock);
    vlc_mutex_unlock(&stream->timing.lock);
}

static vlc_tick_t stream_ClockConvert(vlc_aout_stream *stream,
                                      vlc_tick_t system_now, vlc_tick_t pts)
{
    uint32_t clock_id;

    VF_VOID(VAF_CLOCK_LOCK,vlc_clock_Lock(stream->sync.clock));
    vlc_tick_t play_date =
        VF_CALL(VAF_CLOCK_CONVERT,vlc_clock_ConvertToSystem(stream->sync.clock, system_now, pts,
                                  stream->sync.rate, &clock_id));
    vlc_clock_Unlock(stream->sync.clock);

    if (clock_id != stream->sync.clock_id && stream->sync.played)
    {
        stream->sync.clock_id = clock_id;
        return VLC_TICK_INVALID;
    }
    return play_date;
}

/*****************************************************************************
 * vlc_aout_stream_Play : filter & mix the decoded buffer
 *****************************************************************************/
int vlc_aout_stream_Play(vlc_aout_stream *stream, block_t *block)
{
    VF_SCOPE(vista_stream_play,VAF_STREAM_PLAY,VFParent(),block->i_pts,block->i_nb_samples,block->i_flags);
    aout_owner_t *owner = aout_stream_owner(stream);
    audio_output_t *aout = aout_stream_aout(stream);

    assert (block->i_pts != VLC_TICK_INVALID);
    assert (stream->timing.pause_date == VLC_TICK_INVALID);

    block->i_length = vlc_tick_from_samples( block->i_nb_samples,
                                   stream->input_format.i_rate );

    if (stream->discontinuity.draining)
        return stream_HandleDiscontinuity(stream, block);

    if (block->i_flags & BLOCK_FLAG_DISCONTINUITY && stream->sync.played)
        return stream_StartDiscontinuity(stream, block);

    int ret = VF_CALL(VAF_CHECK_READY,stream_CheckReady (stream));
    if (unlikely(ret == AOUT_DEC_FAILED))
        goto drop; /* Pipeline is unrecoverably broken :-( */

    vlc_tick_t play_date = VLC_TICK_INVALID;
    vlc_tick_t system_now;
    float output_rate=stream->filters && (block->i_flags & BLOCK_FLAG_CORE_PRIVATE_FILTERED)
        ? stream->vista_filter_rate:stream->sync.rate;
    bool already_filtered=stream->filters && (block->i_flags & BLOCK_FLAG_CORE_PRIVATE_FILTERED);
    uint64_t output_serial=already_filtered?stream->vista_filter_serial:stream->vista_rate_serial;
    uint64_t output_command=already_filtered?stream->vista_filter_command:stream->vista_rate_command;

    if (stream->sync.request_delay != stream->sync.delay)
    {
        stream->sync.delay = stream->sync.request_delay;
        vlc_clock_Lock(stream->sync.clock);
        vlc_tick_t delta = vlc_clock_SetDelay(stream->sync.clock, stream->sync.delay);
        vlc_clock_Unlock(stream->sync.clock);
        if (stream->filters)
            aout_FiltersSetClockDelay(stream->filters, stream->sync.delay);
        if (delta > 0)
            stream_Silence(stream, delta, block->i_pts);
    }

    if (stream->filters && (block->i_flags & BLOCK_FLAG_CORE_PRIVATE_FILTERED) == 0)
    {
        system_now = vlc_tick_now();
        vlc_tick_t prefilter_pts = block->i_pts;

        play_date = stream_ClockConvert(stream, system_now, block->i_pts);
        if (play_date == VLC_TICK_INVALID)
            return stream_StartDiscontinuity(stream, block);

        if (atomic_load_explicit(&owner->vp.update, memory_order_relaxed))
        {
            vlc_mutex_lock (&owner->vp.lock);
            aout_FiltersChangeViewpoint (stream->filters, &owner->vp.value);
            atomic_store_explicit(&owner->vp.update, false, memory_order_relaxed);
            vlc_mutex_unlock (&owner->vp.lock);
        }

        stream->vista_filter_rate=output_rate;
        stream->vista_filter_serial=output_serial;stream->vista_filter_command=output_command;
        block = VF_CALL(VF_AUDIO_FILTER,aout_FiltersPlay(stream->filters, block, output_rate));
        if (block == NULL)
            return ret;
        assert (block->i_pts != VLC_TICK_INVALID);

        /* Re-trigger a clock convert if the filtered ts is different */
        if (prefilter_pts != block->i_pts)
            play_date = VLC_TICK_INVALID;
    }

    /* Software volume */
    if (stream->volume != NULL)
        aout_volume_Amplify(stream->volume, block);

    /* Convert the pts if not previously done by filters */
    if (play_date == VLC_TICK_INVALID)
    {
        system_now = vlc_tick_now();
        play_date = stream_ClockConvert(stream, system_now, block->i_pts);
        if (play_date == VLC_TICK_INVALID)
        {
            block->i_flags |= BLOCK_FLAG_CORE_PRIVATE_FILTERED;
            return stream_StartDiscontinuity(stream, block);
        }
    }

    /* Drift correction */
    VF_VOID(VF_AUDIO_SYNC,stream_Synchronize(stream, system_now, play_date, block->i_pts, block,output_rate,output_serial));

    VF_VOID(VAF_METER,vlc_audio_meter_Process(&owner->meter, block, play_date));

    /* Output */
    stream->sync.played = true;
    stream->timing.played_samples += block->i_nb_samples;
    if(vrr_active()) {
    vista_resume_event vf={.tick_us=vlc_tick_now(),.present=3|VRR_HAS_RATE,
      .value={block->i_pts,play_date},.rate=stream->sync.rate};
    if(block->i_pts==VLC_TICK_INVALID)vf.present&=~UINT64_C(1);
    if(play_date==VLC_TICK_INVALID)vf.present&=~UINT64_C(2);
    vrr_emit_id(stream->vista_resume_id,VRR_FINAL_PLAY,&vf);
    }
    stream_Play(stream, block, play_date,output_rate,output_serial,output_command,false);

    atomic_fetch_add_explicit(&stream->buffers_played, 1, memory_order_relaxed);
    return ret;
drop:
    stream_ResetTimings(stream);
    block_Release (block);
    atomic_fetch_add_explicit(&stream->buffers_lost, 1, memory_order_relaxed);
    return ret;
}

void vlc_aout_stream_GetResetStats(vlc_aout_stream *stream, unsigned *restrict lost,
                           unsigned *restrict played)
{
    *lost = atomic_exchange_explicit(&stream->buffers_lost, 0,
                                     memory_order_relaxed);
    *played = atomic_exchange_explicit(&stream->buffers_played, 0,
                                       memory_order_relaxed);
}

void vlc_aout_stream_ChangePause(vlc_aout_stream *stream, bool paused, vlc_tick_t date)
{
    audio_output_t *aout = aout_stream_aout(stream);

    if (stream->mixer_format.i_format)
    {
        struct vlc_tracer *tracer = aout_stream_tracer(stream);
        if (tracer != NULL)
            vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id,
                                  paused ? "paused" : "resumed");

        if (paused)
        {
            assert(stream->timing.pause_date == VLC_TICK_INVALID);
            stream->timing.pause_date = date;
        }
        else if (stream->timing.pause_date != VLC_TICK_INVALID)
        {
            /* Delay the last timing with the pause duration. This will be used
             * by stream_GetDelay() until the module updates its next point
             * after being resumed. */
            vlc_mutex_lock(&stream->timing.lock);
            if (stream->timing.system_ts != VLC_TICK_INVALID)
                stream->timing.system_ts += date - stream->timing.pause_date;
            vlc_mutex_unlock(&stream->timing.lock);
            stream->timing.pause_date = VLC_TICK_INVALID;
        }

        if (aout->pause != NULL)
            aout->pause(aout, paused, date);
        else if (paused)
            vlc_aout_stream_Flush(stream);

        /* Update the rate point after the pause */
        if (!paused && stream->timing.rate_audio_ts != VLC_TICK_INVALID)
        {
            vlc_clock_Lock(stream->sync.clock);
            vlc_tick_t play_date =
                vlc_clock_ConvertToSystem(stream->sync.clock, date,
                                          stream->timing.rate_audio_ts,
                                          stream->sync.rate, NULL);
            vlc_clock_Unlock(stream->sync.clock);
            stream->timing.rate_system_ts = play_date;
        }
    }
}

void vlc_aout_stream_ChangeRate(vlc_aout_stream *stream, float rate)
{
    VF_VOID(VAF_TIMING_LOCK,vlc_mutex_lock(&stream->timing.lock));
    const vlc_tick_t change_us=vlc_tick_now();
    stream->vista_rate_serial++;
    stream->vista_summary_open=true;
    stream->vista_rate_command=VFNew(VF_AUDIO_RATE_CHANGE,VF_POINT,VFParent(),
        stream->vista_boundary_id,(int64_t)(rate*1000000),change_us);
    VFEmit(stream->vista_rate_command,VAF_IDENTITY,VF_POINT,0,stream->vista_rate_serial,0,stream->vista_rate_map.generation);
    vab_change(stream->vista_boundary_id, change_us, rate);
    stream->sync.rate = rate;
    const uint64_t serial=stream->vista_rate_serial,command=stream->vista_rate_command;
    vlc_mutex_unlock(&stream->timing.lock);
    /* Render takes aout lock then timing.lock: never reverse that order. */
    vista_audio_command162(aout_stream_aout(stream),serial,command);
}

void vlc_aout_stream_ChangeDelay(vlc_aout_stream *stream, vlc_tick_t delay)
{
    stream->sync.request_delay = delay;
}

void vlc_aout_stream_Flush(vlc_aout_stream *stream)
{
    audio_output_t *aout = aout_stream_aout(stream);

    struct vlc_tracer *tracer = aout_stream_tracer(stream);
    if (tracer != NULL)
        vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "flushed");

    if (stream->mixer_format.i_format)
        aout->flush(aout);
    VistaRateMapReset(stream); /* A real output flush, not ResetTimings alone. */
    stream_Reset(stream);
}

void vlc_aout_stream_NotifyGain(vlc_aout_stream *stream, float gain)
{
    if (stream->volume != NULL)
        aout_volume_SetVolume(stream->volume, gain);
}

void vlc_aout_stream_NotifyDrained(vlc_aout_stream *stream)
{
    atomic_store_explicit(&stream->drained, true, memory_order_relaxed);
}

bool vlc_aout_stream_IsDrained(vlc_aout_stream *stream)
{
    /* The internal draining state should not mess with the public one */
    if (stream->discontinuity.draining)
        return false;

    return stream_IsDrained(stream);
}

void vlc_aout_stream_Drain(vlc_aout_stream *stream)
{
    audio_output_t *aout = aout_stream_aout(stream);

    if (!stream->mixer_format.i_format)
        return;

    if (unlikely(stream->discontinuity.draining))
    {
        if (stream->discontinuity.fifo_first != NULL)
        {
            vlc_tick_t length;
            block_ChainProperties(stream->discontinuity.fifo_first, NULL, NULL,
                                  &length);

            msg_Err(aout, "draining while handling a discontinuity not handled"
                    ", losing %"PRId64 " us of audio", length); /* FIXME */
        }
        stream_ResetDiscontinuity(stream);
        return;
    }

    struct vlc_tracer *tracer = aout_stream_tracer(stream);

    if (tracer != NULL)
        vlc_tracer_TraceEvent(tracer, "RENDER", stream->str_id, "drain");

    if (stream->filters)
    {
        block_t *block = aout_FiltersDrain (stream->filters);
        if (block)
        {
            assert (block->i_pts != VLC_TICK_INVALID);
            stream->timing.played_samples += block->i_nb_samples;
            stream_Play(stream, block, vlc_tick_now(),stream->vista_filter_rate,
                        stream->vista_filter_serial,stream->vista_filter_command,false);
        }
    }

    if (aout->drain)
    {
        assert(!atomic_load_explicit(&stream->drained, memory_order_relaxed));

        aout->drain(aout);
    }
    else
    {
        assert(atomic_load_explicit(&stream->drain_deadline,
                                    memory_order_relaxed) == VLC_TICK_INVALID);

        vlc_tick_t drain_deadline = vlc_tick_now();

        vlc_tick_t delay;
        vlc_mutex_lock(&stream->timing.lock);
        if (stream_GetDelay(stream, &delay) == 0)
            drain_deadline += delay;
        vlc_mutex_unlock(&stream->timing.lock);

        /* else the deadline is now, and vlc_aout_stream_IsDrained() will
         * return true on the first call. */

        atomic_store_explicit(&stream->drain_deadline, drain_deadline,
                              memory_order_relaxed);
    }
}
