// Vista MIT. Executable-only allocation interposition; never link into the App.
#pragma once
#include <cstddef>
namespace allocation_budget {
void start(std::size_t maxLive = 2 * 1024 * 1024, std::size_t maxSingle = 256 * 1024);
void tighten();
void report();
struct Scope { Scope() { start(); } ~Scope() { report(); } };
}
