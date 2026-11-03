#include "ParserBudget.hpp"
#include <cassert>
#include <thread>
#include <vector>
#include <cstdio>
int main() {
    using namespace vista_parser;
    assert(new (allocationTag, std::nothrow) char[1] == nullptr);
    Budget one(128, 64), other(128, 64);
    {
        Scope scope(one); assert(scope.valid());
        Scope reentry(other); assert(!reentry.valid());
        auto* bytes = new (allocationTag, std::nothrow) char[64]; assert(bytes); delete[] bytes;
        bytes = new (allocationTag, std::nothrow) char[64]; assert(bytes); delete[] bytes;
        assert(new (allocationTag, std::nothrow) char[1] == nullptr);
        std::vector<char> unrelated(300000); assert(unrelated.size() == 300000);
        std::thread competitor([&] { Scope same(one); assert(!same.valid()); Scope independent(other); assert(independent.valid());
            auto* p = new (allocationTag, std::nothrow) char[32]; assert(p); delete[] p; });
        competitor.join();
    }
    { Scope restored(other); assert(restored.valid()); other.cancelled = true;
      assert(new (allocationTag, std::nothrow) char[1] == nullptr); }
    assert(one.charged == 128 && other.charged == 32);
    std::puts("PARSER_BUDGET_VERIFIED: isolated, cumulative, missing-context, reentry, concurrency, cancellation");
}
