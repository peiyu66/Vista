#include "ParserBudget.hpp"
namespace vista_parser {
static thread_local Budget* current = nullptr;
Scope::Scope(Budget& candidate) noexcept {
    if (current || candidate.owned.test_and_set(std::memory_order_acquire)) return;
    budget = current = &candidate;
}
Scope::~Scope() {
    if (budget) { current = nullptr; budget->owned.clear(std::memory_order_release); }
}
void* allocate(std::size_t size, bool array) noexcept {
    auto* budget = current;
    if (!budget) return nullptr; // No silent unbounded allocation when a context is missing.
    if (size == 0) size = 1;
    const auto prior = budget->charged.load();
    if (budget->cancelled.load() || (budget->cancelCheck && budget->cancelCheck(budget->cancelContext)) || budget->attempts.fetch_add(1) >= 100000 ||
        size > budget->singleLimit || prior > budget->totalLimit || size > budget->totalLimit - prior) {
        budget->rejected.fetch_add(1); return nullptr;
    }
    budget->charged.fetch_add(size); // Cumulative, including subsequently freed or failed allocations.
    return array ? ::operator new[](size, std::nothrow) : ::operator new(size, std::nothrow);
}
}
void* operator new(std::size_t size, vista_parser::AllocationTag, const std::nothrow_t&) noexcept { return vista_parser::allocate(size, false); }
void* operator new[](std::size_t size, vista_parser::AllocationTag, const std::nothrow_t&) noexcept { return vista_parser::allocate(size, true); }
void operator delete(void* p, vista_parser::AllocationTag, const std::nothrow_t&) noexcept { ::operator delete(p); }
void operator delete[](void* p, vista_parser::AllocationTag, const std::nothrow_t&) noexcept { ::operator delete[](p); }
