#!/usr/bin/env python3
"""Reproduce the derived libwebm unit from untouched vendor, or verify it."""
from pathlib import Path
import hashlib,sys
root=Path(__file__).resolve().parent
vendor=root/'vendor/libwebm/mkvparser/mkvparser.cc'
source=vendor.read_text()
assert hashlib.sha256(vendor.read_bytes()).hexdigest()=='806646c6d4b15099bf5cc40de185690c6b7388592ade5e47f9edfce93fc9d0dc'
assert source.count('new (std::nothrow)')==44
result='#include "ParserBudget.hpp"\n'+source.replace('new (std::nothrow)','new (vista_parser::allocationTag, std::nothrow)')
assert result.count('    m_entries_size = 1024;')==1
result=result.replace('    m_entries_size = 1024;','    // Small Clusters must not reserve 1024 pointers each. Existing doubling\n    // below preserves entry indices, ownership and dense-Cluster growth.\n    m_entries_size = 16;')
target=root/'source/producer/budgeted-mkvparser.cc'
if '--check' in sys.argv:assert target.read_text()==result
else:target.write_text(result)
print(hashlib.sha256(result.encode()).hexdigest())
