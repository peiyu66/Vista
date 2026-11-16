#include <stddef.h>
#include <vlc_plugin.h>
VLC_ENTRY_FUNC(vlc_entry__access_imem_access);
VLC_ENTRY_FUNC(vlc_entry__demux_mkv_libmkv);
VLC_ENTRY_FUNC(vlc_entry__packetizer_h264);
VLC_ENTRY_FUNC(vlc_entry__packetizer_hevc);
VLC_ENTRY_FUNC(vlc_entry__packetizer_copy);
VLC_ENTRY_FUNC(vlc_entry__codec_videotoolbox_libvideotoolbox);
VLC_ENTRY_FUNC(vlc_entry__video_output_wdummy);
VLC_ENTRY_FUNC(vlc_entry__video_output_apple_libvistacvpx);
VLC_ENTRY_FUNC(vlc_entry__codec_avcodec_libavcodec);
VLC_ENTRY_FUNC(vlc_entry__audio_output_amem);
VLC_ENTRY_FUNC(vlc_entry__audio_mixer_libfloat_mixer);
VLC_ENTRY_FUNC(vlc_entry__audio_filter_resampler_ugly);
VLC_ENTRY_FUNC(vlc_entry__audio_output_apple_audiounit_ios);
VLC_ENTRY_FUNC(vlc_entry__stream_filter_cache_read);
VLC_ENTRY_FUNC(vlc_entry__audio_filter_scaletempo);
const vlc_plugin_cb vlc_static_modules[] = {
    vlc_entry__access_imem_access,
    vlc_entry__demux_mkv_libmkv,
    vlc_entry__packetizer_h264,
    vlc_entry__packetizer_hevc,
    vlc_entry__packetizer_copy,
    vlc_entry__codec_videotoolbox_libvideotoolbox,
    vlc_entry__video_output_wdummy,
    vlc_entry__video_output_apple_libvistacvpx,
    vlc_entry__codec_avcodec_libavcodec,
    vlc_entry__audio_output_amem,
    vlc_entry__audio_mixer_libfloat_mixer,
    vlc_entry__audio_filter_resampler_ugly,
    vlc_entry__audio_output_apple_audiounit_ios,
    vlc_entry__stream_filter_cache_read,
    vlc_entry__audio_filter_scaletempo,
    NULL
};
