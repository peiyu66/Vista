// Vista 152. Pure, bounded Matroska whole-track BPS interpretation.
#ifndef VISTA_MKV_BITRATE_HPP
#define VISTA_MKV_BITRATE_HPP
#include <cstdint>
#include <string>
#include <limits>
#include <algorithm>

inline uint32_t VistaMkvParseBps(const std::string &text)
{
    // Matroska Number Tags: ASCII decimal only, no unit/exponent/sign/grouping.
    // VLC's public ES bitrate is uint32_t. Unknown rather than wrap/saturate.
    if (text.empty() || text.size() > 128) return 0;
    uint64_t integer = 0;
    bool dot = false, before = false, after = false, fractional_nonzero = false;
    for (unsigned char c : text)
    {
        if (c == '.' && !dot && before) { dot = true; continue; }
        if (c < '0' || c > '9') return 0;
        if (!dot)
        {
            before = true;
            integer = integer * 10 + (c - '0');
            if (integer > std::numeric_limits<uint32_t>::max()) return 0;
        }
        else { after = true; fractional_nonzero |= c != '0'; }
    }
    if (!before || (dot && !after) || integer == 0 ||
        (integer == std::numeric_limits<uint32_t>::max() && fractional_nonzero)) return 0;
    return static_cast<uint32_t>(integer); // sub-bit fraction truncated, never rounded up.
}

template<class Tags> uint32_t VistaMkvVideoBitrate(const Tags &tags, uint64_t track_uid)
{
    if (!track_uid || tags.size() > 4096) return 0;
    uint32_t result = 0;
    for (const auto &tag : tags)
    {
        if (!tag.vista_whole_track_scope || tag.vista_targets_count != 1 || tag.i_target_type != 50 ||
            std::find(tag.vista_track_uids.begin(), tag.vista_track_uids.end(), track_uid) == tag.vista_track_uids.end()) continue;
        if (tag.simple_tags.size() > 4096) return 0;
        // Nested SimpleTags qualify their parent (e.g. ORIGINAL/BPS); they are
        // not the current track's BPS. Only direct SimpleTag BPS is applicable.
        for (const auto &simple : tag.simple_tags)
        {
            if (simple.tag_name != "BPS" && !simple.vista_bps_named) continue;
            if (!simple.vista_scalar_valid || simple.vista_name_count != 1 || simple.vista_string_count != 1) return 0;
            const uint32_t value = VistaMkvParseBps(simple.value);
            if (!value || (result && value != result)) return 0;
            result = value;
        }
    }
    return result;
}
#endif
