// Vista MIT. C boundary for the bounded parser experiment; no decoder and no App entry point.
#include "mkvparser/mkvparser.h"
#include "ParserBudget.hpp"
#include <cstdint>
#include <cstring>
#include <memory>
extern "C" int32_t vista_experiment_read(void*, int64_t, int32_t, uint8_t*);
extern "C" int32_t vista_experiment_cancelled(void*);
namespace {
struct Reader final : mkvparser::IMkvReader {
    void* context; int64_t size; int calls = 0; int64_t bytes = 0;
    Reader(void* context, int64_t size) : context(context), size(size) {}
    int Length(long long* total, long long* available) override { *total = *available = size; return 0; }
    int Read(long long pos, long len, unsigned char* out) override {
        if (pos < 0 || len < 0 || len > 65536 || pos > size || len > size - pos || ++calls > 50000 || len > 1048576 - bytes) return -1;
        bytes += len;
        return vista_experiment_read(context, pos, int32_t(len), out);
    }
};
}
extern "C" int32_t vista_experiment_parse(void* context, int64_t size) {
    if (!context || size <= 0 || size > 1048576) return -1;
    vista_parser::Budget budget;
    budget.cancelContext = context;
    budget.cancelCheck = [](void* value) { return vista_experiment_cancelled(value) != 0; };
    vista_parser::Scope scope(budget);
    if (!scope.valid()) return -1;
    try {
        Reader reader(context, size); mkvparser::EBMLHeader header; long long pos = 0;
        if (header.Parse(&reader, pos) != 0 || !header.m_docType || std::strcmp(header.m_docType, "matroska")) return -1;
        mkvparser::Segment* raw = nullptr;
        if (mkvparser::Segment::CreateInstance(&reader, pos, raw) != 0 || !raw) return -1;
        std::unique_ptr<mkvparser::Segment> segment(raw);
        if (segment->ParseHeaders() < 0) return -1;
        auto* tracks = segment->GetTracks(); if (!tracks || tracks->GetTracksCount() != 1) return -1;
        auto* track = tracks->GetTrackByIndex(0);
        if (!track || track->GetType() != mkvparser::Track::kVideo || track->GetContentEncodingCount()) return -1;
        const auto* id = track->GetCodecId();
        if (!id || (std::strcmp(id, "V_MPEG4/ISO/AVC") && std::strcmp(id, "V_MPEGH/ISO/HEVC"))) return -1;
        int clusters = 0;
        for (;;) { auto status = segment->LoadCluster(); if (status < 0) return -1; if (status > 0) break; if (++clusters > 8) return -1; }
        int samples = 0; unsigned char data[65536];
        for (auto* cluster = segment->GetFirst(); cluster && !cluster->EOS(); cluster = segment->GetNext(cluster)) {
            const mkvparser::BlockEntry* entry = nullptr;
            if (cluster->GetFirst(entry) < 0) return -1;
            while (entry && !entry->EOS()) {
                const auto* block = entry->GetBlock();
                if (!block || block->GetTrackNumber() != track->GetNumber() || block->GetFrameCount() != 1 || block->GetLacing() != mkvparser::Block::kLacingNone || ++samples > 128) return -1;
                const auto frame = block->GetFrame(0);
                if (frame.len <= 0 || frame.len > 65536 || frame.Read(&reader, data) != 0) return -1;
                if (cluster->GetNext(entry, entry) < 0) return -1;
            }
        }
        return samples == 24 && !vista_experiment_cancelled(context) ? 24 : -1;
    } catch (...) { return -1; }
}
