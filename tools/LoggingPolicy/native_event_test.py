#!/usr/bin/env python3
"""Run actual producer event function in a minimal host harness, not media playback."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
source=(root/'engine/source/producer/MKVProducer.cpp').read_text()
function=source[source.index('void event(const std::string&s){'):source.index('\n',source.index('void event(const std::string&s){'))]
with tempfile.TemporaryDirectory(prefix='vista-native-log-') as td:
 p=Path(td)
 harness=r'''
#include <fstream>
#include <string>
#include <stdexcept>
#include <filesystem>
#include <ctime>
#include <cassert>
constexpr unsigned long long NS=1000000000;
struct Session {std::string receipt;std::ofstream events;size_t eventCount=0,eventBytes=0;unsigned long long generation=1;};
Session *session;
void need(bool v,const char*m){if(!v)throw std::runtime_error(m);}
'''+function+r'''
int main(int argc,char**argv){
 Session disabled;session=&disabled;
 event("{\"kind\":\"error\",\"message\":\"synthetic\"}");
 assert(disabled.eventCount==0 && disabled.eventBytes==0 && !disabled.events.is_open());
 assert(std::filesystem::is_empty(argv[1]));
 Session enabled;session=&enabled;enabled.receipt=std::string(argv[1])+"/diagnostic.jsonl";enabled.events.open(enabled.receipt);
 event("{\"kind\":\"error\",\"message\":\"synthetic\"}");
 assert(enabled.eventCount==1 && enabled.eventBytes>0);
 event("{\"kind\":\"packet\"}");assert(enabled.eventCount==1);
 enabled.events.close();assert(std::filesystem::file_size(enabled.receipt)>0);
}
'''
 (p/'test.cpp').write_text(harness);(p/'files').mkdir()
 subprocess.run(['xcrun','clang++','-std=c++17','-fsanitize=address,undefined',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'files')],check=True)
 print('PASS actual producer event: disabled writes nothing; enabled writes bounded JSONL; ASan/UBSan')
