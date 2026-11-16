// Vista MIT. Opt-in parser allocation overloads; does not replace standard new/delete.
#pragma once
#include <atomic>
#include <cstddef>
#include <new>
namespace vista_parser {
struct AllocationTag {};
static const AllocationTag allocationTag{};
struct Budget {
    const std::size_t totalLimit, singleLimit;
    std::atomic<std::size_t> charged{0}, attempts{0}, rejected{0};
    std::atomic<bool> cancelled{false};
    bool (*cancelCheck)(void*) = nullptr;
    void* cancelContext = nullptr;
    std::atomic_flag owned = ATOMIC_FLAG_INIT;
    explicit Budget(std::size_t total = 2 * 1024 * 1024, std::size_t single = 256 * 1024)
        : totalLimit(total), singleLimit(single) {}
};
class Scope {
    Budget* budget = nullptr;
public:
    explicit Scope(Budget&) noexcept;
    ~Scope();
    bool valid() const noexcept { return budget != nullptr; }
    Scope(const Scope&) = delete;
    Scope& operator=(const Scope&) = delete;
};
void* allocate(std::size_t, bool array) noexcept;
}
void* operator new(std::size_t, vista_parser::AllocationTag, const std::nothrow_t&) noexcept;
void* operator new[](std::size_t, vista_parser::AllocationTag, const std::nothrow_t&) noexcept;
void operator delete(void*, vista_parser::AllocationTag, const std::nothrow_t&) noexcept;
void operator delete[](void*, vista_parser::AllocationTag, const std::nothrow_t&) noexcept;
