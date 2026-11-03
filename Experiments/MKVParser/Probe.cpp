// Vista MIT. Trusted synthetic-fixture experiment only; not an untrusted-media parser boundary.
#include "mkvparser/mkvparser.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

static void require(bool ok) { if (!ok) throw std::runtime_error("prototype rejected input or limit"); }
class Reader final : public mkvparser::IMkvReader {
    int fd;
    long long size;
    long long insertion = -1;
    static constexpr long long gapPayload = 1LL << 32;
    static constexpr long long gapSize = gapPayload + 9;
public:
    size_t calls = 0, bytes = 0, largest = 0;
    size_t budget = 1024 * 1024;
    bool cancelled = false;
    size_t cancelAfter = 50000;
    explicit Reader(const char* path) : fd(open(path, O_RDONLY)), size(0) {
        struct stat st{};
        require(fd >= 0 && fstat(fd, &st) == 0 && S_ISREG(st.st_mode));
        size = st.st_size;
        require(size > 0 && size <= 1024 * 1024);
    }
    void insertVirtualVoid(long long at) { insertion = at; }
    ~Reader() override { if (fd >= 0) close(fd); }
    int Length(long long* total, long long* available) override {
        if (cancelled) return -1;
        *total = *available = size + (insertion >= 0 ? gapSize : 0); return 0;
    }
    int Read(long long pos, long len, unsigned char* out) override {
        if (calls >= cancelAfter) cancelled = true;
        const long long logicalSize = size + (insertion >= 0 ? gapSize : 0);
        if (cancelled || pos < 0 || len < 0 || len > 65536 || pos > logicalSize || len > logicalSize - pos ||
            calls >= 50000 || size_t(len) > budget - bytes) return -1;
        ++calls; bytes += size_t(len); largest = std::max(largest, size_t(len));
        if (insertion >= 0 && pos >= insertion && pos < insertion + gapSize) {
            // EBML Void with an eight-byte length and a virtual 4 GiB payload.
            // Reject reads into the payload: the parser must skip it by position.
            const unsigned char header[9] = {0xec, 0x01, 0, 0, 0x01, 0, 0, 0, 0};
            const auto offset = pos - insertion;
            if (offset > 9 || len > 9 - offset) return -1;
            std::memcpy(out, header + offset, size_t(len)); return 0;
        }
        if (insertion >= 0 && pos < insertion && len > insertion - pos) return -1;
        const auto physical = insertion >= 0 && pos >= insertion + gapSize ? pos - gapSize : pos;
        return pread(fd, out, size_t(len), physical) == len ? 0 : -1;
    }
};
static std::string hex(const unsigned char* data, size_t size) {
    const char* digits = "0123456789abcdef"; std::string result;
    for (size_t i = 0; i < size; ++i) { result += digits[data[i] >> 4]; result += digits[data[i] & 15]; }
    return result;
}
int main(int argc, char** argv) {
    try {
        require(argc == 2 || argc == 3);
        Reader reader(argv[1]);
        if (argc == 3) {
            if (std::strcmp(argv[2], "cancel") == 0) reader.cancelled = true;
            else if (std::strcmp(argv[2], "cancel-midway") == 0) reader.cancelAfter = 100;
            else if (std::strcmp(argv[2], "bounds") == 0) {
                unsigned char byte = 0;
                require(reader.Read(-1, 1, &byte) < 0);
                require(reader.Read(0, 65537, &byte) < 0);
                require(reader.Read(INT64_MAX, 1, &byte) < 0);
                require(reader.Read(0, 1, &byte) == 0);
                std::cout << "READER_BOUNDS_VERIFIED\n"; return 0;
            }
            else if (std::strcmp(argv[2], "budget") == 0) reader.budget = 16;
            else if (std::strcmp(argv[2], "gap") != 0) require(false);
        }
        mkvparser::EBMLHeader header; long long pos = 0;
        require(header.Parse(&reader, pos) == 0 && header.m_docType && std::strcmp(header.m_docType, "matroska") == 0);
        if (argc == 3 && std::strcmp(argv[2], "gap") == 0) reader.insertVirtualVoid(pos);
        mkvparser::Segment* raw = nullptr;
        require(mkvparser::Segment::CreateInstance(&reader, pos, raw) == 0 && raw);
        std::unique_ptr<mkvparser::Segment> segment(raw);
        require(segment->ParseHeaders() >= 0);
        const auto* tracks = segment->GetTracks();
        require(tracks && tracks->GetTracksCount() == 1);
        const auto* track = tracks->GetTrackByIndex(0);
        require(track && track->GetType() == mkvparser::Track::kVideo && track->GetContentEncodingCount() == 0);
        const std::string codec(track->GetCodecId() ? track->GetCodecId() : "");
        require(codec == "V_MPEG4/ISO/AVC" || codec == "V_MPEGH/ISO/HEVC");
        const auto* video = static_cast<const mkvparser::VideoTrack*>(track);
        require(video->GetWidth() == 64 && video->GetHeight() == 64);
        size_t privateSize = 0; const auto* privateData = track->GetCodecPrivate(privateSize);
        require(privateData && privateSize > 0 && privateSize <= 4096 && privateData[0] == 1);
        unsigned clusters = 0;
        while (true) {
            long status = segment->LoadCluster();
            require(status >= 0);
            if (status > 0) break;
            require(++clusters <= 8);
        }
        struct Sample { long long time; std::string data; bool key; };
        std::vector<Sample> samples;
        for (auto* cluster = segment->GetFirst(); cluster && !cluster->EOS(); cluster = segment->GetNext(cluster)) {
            const mkvparser::BlockEntry* entry = nullptr;
            require(cluster->GetFirst(entry) >= 0);
            while (entry && !entry->EOS()) {
                const auto* block = entry->GetBlock();
                require(block && block->GetTrackNumber() == track->GetNumber() && block->GetFrameCount() == 1 &&
                        block->GetLacing() == mkvparser::Block::kLacingNone && samples.size() < 128);
                auto frame = block->GetFrame(0);
                require(frame.len > 0 && frame.len <= 65536);
                std::vector<unsigned char> payload(size_t(frame.len));
                require(frame.Read(&reader, payload.data()) == 0);
                // Exercise repeatable random access independently of sequential parsing.
                std::vector<unsigned char> again(size_t(frame.len));
                require(reader.Read(frame.pos, frame.len, again.data()) == 0 && payload == again);
                const auto time = block->GetTime(cluster);
                require(time >= 0 && time <= 3000000000LL);
                samples.push_back({time, hex(payload.data(), payload.size()), block->IsKey()});
                require(cluster->GetNext(entry, entry) >= 0);
            }
        }
        require(samples.size() == 24 && samples.front().key);
        std::cout << "{\"codec\":\"" << codec << "\",\"privateHex\":\"" << hex(privateData, privateSize)
                  << "\",\"calls\":" << reader.calls << ",\"bytes\":" << reader.bytes
                  << ",\"largestRead\":" << reader.largest << ",\"samples\":[";
        for (size_t i = 0; i < samples.size(); ++i) {
            if (i) std::cout << ',';
            std::cout << "{\"time\":" << samples[i].time << ",\"hex\":\"" << samples[i].data << "\"}";
        }
        std::cout << "]}\n";
        return 0;
    } catch (...) { std::cerr << "PROTOTYPE_REJECTED\n"; return 1; }
}
