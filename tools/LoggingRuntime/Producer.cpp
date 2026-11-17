#include "MKVProducer.h"
#include <filesystem>
#include <fstream>
#include <vector>
#include <thread>
#include <chrono>
#include <cassert>
#include <cstring>
#include <iostream>
struct Source {std::vector<uint8_t> bytes;bool failure=false;};
int read(void*p,uint64_t off,uint32_t count,uint8_t*out){auto&s=*(Source*)p;if(s.failure||off>s.bytes.size()||count>s.bytes.size()-off)return -1;memcpy(out,s.bytes.data()+off,count);return 0;}
int check(void*){return 1;}
int main(int argc,char**argv){
 assert(argc==4);std::filesystem::path root=argv[1];bool diagnostic=std::string(argv[2])=="Diagnostic";
 std::ifstream input(argv[3],std::ios::binary);Source source{{std::istreambuf_iterator<char>(input),{}},false};assert(source.bytes.size()>0);
 for(int fail=0;fail<2;fail++){
  source.failure=fail;auto stage=root/(fail?"failure-staging":"playback-staging");std::filesystem::create_directory(stage);
  auto receipt=root/(fail?"failure.jsonl":"producer.jsonl");std::string configured=diagnostic?receipt.string():"";
  SAPSourceCallbacks callbacks{&source,source.bytes.size(),read,check,check,0};
  SAP*s=sap_create(callbacks,stage.c_str(),configured.c_str(),fail+1,0,3);assert(s);assert(sap_start(s)==1);
  unsigned imported=0;auto began=std::chrono::steady_clock::now();
  while(true){
   SAPSnapshot snap{};assert(sap_snapshot(s,&snap));
   while(imported<snap.publishedSegments){assert(sap_ack_imported(s,++imported));}
   if(snap.state==2||snap.state==3||snap.state==5)break;
   assert(std::chrono::steady_clock::now()-began<std::chrono::seconds(30)); // Test harness bound, never a product timeout.
   std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  sap_join(s);int state=sap_status(s);char err[512]{};sap_error(s,err,sizeof(err));std::cout<<"failure="<<fail<<" state="<<state<<" segments="<<imported<<" error="<<err<<"\n";
  assert(state==(fail?3:2));assert(fail||imported>0);assert(std::filesystem::exists(receipt)==diagnostic);
  sap_destroy(s);assert(std::filesystem::exists(receipt)==diagnostic);
 }
}
