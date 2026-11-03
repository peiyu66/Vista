// Vista MIT. Single-threaded parser experiment only. Tracks C++ new/new[], not C malloc or OS memory.
#include "AllocationBudget.hpp"
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <new>
namespace {
struct alignas(std::max_align_t) Header { std::size_t size; bool counted; };
bool enabled = false;
std::size_t live = 0, peak = 0, attempts = 0, rejected = 0;
std::size_t liveLimit = 0, singleLimit = 0;
void* allocate(std::size_t size) {
    if (!size) size = 1;
    if (size > std::numeric_limits<std::size_t>::max() - sizeof(Header)) throw std::bad_alloc();
    const auto charged = size + sizeof(Header);
    if (enabled && (++attempts > 100000 || charged > singleLimit || charged > liveLimit - live)) {
        ++rejected; throw std::bad_alloc();
    }
    auto* header = static_cast<Header*>(std::malloc(charged));
    if (!header) throw std::bad_alloc();
    header->size = charged; header->counted = enabled;
    if (enabled) { live += charged; if (live > peak) peak = live; }
    return header + 1;
}
void release(void* pointer) noexcept {
    if (!pointer) return;
    auto* header = static_cast<Header*>(pointer) - 1;
    if (header->counted) live -= header->size;
    std::free(header);
}
}
void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void* operator new(std::size_t size, const std::nothrow_t&) noexcept { try { return allocate(size); } catch (...) { return nullptr; } }
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept { try { return allocate(size); } catch (...) { return nullptr; } }
void operator delete(void* p) noexcept { release(p); }
void operator delete[](void* p) noexcept { release(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { release(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { release(p); }
namespace allocation_budget {
void start(std::size_t maxLive, std::size_t maxSingle) { liveLimit = maxLive; singleLimit = maxSingle; enabled = true; }
void tighten() { liveLimit = live + 64; singleLimit = 64; }
void report() {
    enabled = false;
    std::fprintf(stderr, "ALLOCATION_STATS live=%zu peak=%zu rejected=%zu attempts=%zu\n", live, peak, rejected, attempts);
}
}
