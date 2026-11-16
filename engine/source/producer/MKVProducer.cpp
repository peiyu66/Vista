// Isolated research: local seekable MKV -> bounded VP9 + AAC-LC fragmented HLS.
// Own code MIT. Existing libwebm BSD and GPAC LGPL. No product or device integration.
#include "MKVProducer.h"
#include "ParserBudget.hpp"
#include "MetadataScanBudget.hpp"
#include "VP9Colour.hpp"
#include "AACTiming.hpp"
#include "mkvparser/mkvparser.h"
#include <CommonCrypto/CommonDigest.h>
#include <gpac/isomedia.h>
#include <gpac/mpeg4_odf.h>
#include <gpac/constants.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <vector>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <time.h>
namespace fs=std::filesystem;
struct SAP {
 SAPSourceCallbacks source{};std::string out,receipt; uint64_t generation=0;int64_t requested=0;unsigned maxSegments=3;std::atomic<unsigned> imported{0};unsigned cleaned=0;std::array<SAPSegmentInfo,8192> segments{};std::string error;
 std::atomic<bool> cancel{false},resume{false};std::atomic<int> state{0};std::mutex lock;std::condition_variable changed;std::thread owner;
 SAPSnapshot snap{};SAPDiagnostics diagnostic{};std::ofstream events;size_t eventCount=0,eventBytes=0;
};
static std::atomic<bool> ownerBusy{false};
static thread_local SAP* session=nullptr;
namespace {
constexpr int64_t NS=1000000000,MAX_TIME=24*3600*NS;
constexpr size_t READ_MAX=16384,PAYLOAD_READ_MAX=262144,WINDOW=65536,PACKET_COUNT=2048;
constexpr size_t FILE_MAX=32*1024*1024,BOX_RESERVE=256*1024,PAYLOAD_MAX=FILE_MAX-BOX_RESERVE,INIT_MAX=1024*1024;
constexpr size_t PACKET_MAX=PAYLOAD_MAX; // One video packet cannot exceed the whole-GOP payload envelope.
constexpr size_t READ_TOTAL=32*1024*1024,MUX_READ_TOTAL=96*1024*1024,METADATA_TOTAL=1048576;
// A positive parser read costs at least one metadata byte. Zero-length calls
// still consume this finite allowance; bytes, phase deadline and cancel remain.
constexpr size_t READ_CALL_MAX=METADATA_TOTAL;
// Keep the original physical-byte envelope. Shared read-ahead additionally
// reserves every remaining admitted logical byte before spending any surplus;
// it never raises this cap, even for sparse packet/metadata offsets.
static_assert(MUX_READ_TOTAL>=PAYLOAD_MAX+2*READ_MAX*PACKET_COUNT,"mux read envelope");
struct ReasonEntry {uint32_t code;const char*message;};
// Frozen schema-1 IDs: append new entries, never renumber existing entries.
static const ReasonEntry reasons[]={
 {0,"No engine failure"},
 {1,"Unclassified engine exception"},
 {2,"Engine allocation failure"},
 {3,"Producer worker could not start"},
 {100,"event write"},
 {101,"validated source size must fit positive Int64 offset"},
 {102,"generation cancelled"},
 {103,"20-second generation deadline"},
 {104,"source revision invalid or generation cancelled"},
 {105,"reader call/range cap"},
 {106,"parser requested byte cap"},
 {107,"metadata byte cap"},
 {108,"physical read byte cap"},
 {109,"async source exact read failed/invalidated"},
 {110,"packet source bounds"},
 {111,"payload read"},
 {112,"source-owner physical EOF verification"},
 {113,"VP9 header bounds"},
 {114,"empty VP9"},
 {115,"superframe component size"},
 {116,"superframe accounting"},
 {117,"VP9 marker"},
 {118,"unsupported VP9 profile (only 0)"},
 {119,"VP9 show-existing unsupported"},
 {120,"only one visible terminal VP9 component supported"},
 {121,"key/superframe correspondence"},
 {122,"VP9 sync"},
 {123,"only unspecified VP9 colour space currently accepted"},
 {124,"VP9 dimensions cap"},
 {125,"midstream VP9 configuration change unsupported"},
 {126,"VP9 inter marked key"},
 {127,"VP9 key config unavailable"},
 {128,"output file cap"},
 {129,"open output"},
 {130,"output box header"},
 {131,"output box size"},
 {132,"output box structure"},
 {133,"sample conversion bounds"},
 {134,"video origin/window is not on exact audio sample grid"},
 {135,"AAC ASC size 2..16 required"},
 {136,"only AAC-LC AOT 2 (no explicit SBR/PS)"},
 {137,"reserved AAC sample-rate index"},
 {138,"AAC sample rate outside subset"},
 {139,"only AAC mono/stereo channelConfiguration, no PCE"},
 {140,"AAC frameLengthFlag 960 unsupported"},
 {141,"AAC dependsOnCoreCoder unsupported"},
 {142,"AAC GASpecific extensionFlag unsupported"},
 {143,"unknown AAC sync extension"},
 {144,"AAC SBR extension unsupported"},
 {145,"unknown AAC extension after SBR"},
 {146,"AAC PS extension unsupported"},
 {147,"AAC trailing bits unsupported"},
 {148,"nonzero ASC trailing bits"},
 {149,"TrackEntry bounds"},
 {150,"TrackEntry field"},
 {151,"TrackTimestampScale unsupported"},
 {152,"TrackOffset unsupported"},
 {153,"Audio settings bounds"},
 {154,"OutputSamplingFrequency conflicts with AAC-LC rate"},
 {155,"unknown Audio settings element"},
 {156,"unlaced visible blocks required"},
 {157,"unknown block track"},
 {158,"packet size cap"},
 {159,"negative/out-of-range raw timestamp unsupported"},
 {160,"video DiscardPadding/explicit BlockDuration unsupported"},
 {161,"negative AAC DiscardPadding unsupported"},
 {162,"cluster parse"},
 {163,"block entry"},
 {164,"audio raw PTS before anchor"},
 {165,"audio grid index cap"},
 {166,"AAC timestamp not on anchored 1024-sample clock within container quantization"},
 {167,"AAC terminal padding not an integer sample count within 1 ns"},
 {168,"AAC BlockDuration inconsistent with LC valid frames after declared padding"},
 {169,"output must be empty regular directory"},
 {170,"GPAC init"},
 {171,"create init"},
 {172,"timescale"},
 {173,"brand"},
 {174,"A/V tracks"},
 {175,"enable track"},
 {176,"vpcC"},
 {177,"dimensions"},
 {178,"AAC descriptor"},
 {179,"ASC allocation"},
 {180,"AAC description"},
 {181,"AAC info"},
 {182,"finite audio trim edit"},
 {183,"video fragment defaults"},
 {184,"AAC fragment defaults"},
 {185,"finalize init"},
 {186,"unexpected output entry"},
 {187,"output cap"},
 {188,"no-replace atomic publication"},
 {189,"segment count/state"},
 {190,"segment exists"},
 {191,"start segment"},
 {192,"continuous track contract changed"},
 {193,"continuous audio gap/duplicate boundary"},
 {194,"pending packet cap"},
 {195,"nonempty A/V GOP required"},
 {196,"GOP duration cap"},
 {197,"start fragment"},
 {198,"offset mode"},
 {199,"tfdt"},
 {200,"fragment sample"},
 {201,"AAC decoder roll"},
 {202,"close segment"},
 {203,"serialized fragment cap"},
 {204,"all planned A/V samples emitted exactly once"},
 {205,"parser budget"},
 {206,"unsupported/invalid EBML header"},
 {207,"Segment create"},
 {208,"Segment headers"},
 {209,"one VP9 plus one AAC track required"},
 {210,"encrypted/encoded tracks unsupported"},
 {211,"single VP9 required"},
 {212,"single AAC required"},
 {213,"VP9 delay/preroll unsupported"},
 {214,"VP9 CodecPrivate currently unsupported"},
 {215,"non-default display/aspect/stereo/projection unsupported"},
 {216,"HDR metadata unsupported"},
 {217,"explicit colour transform unsupported"},
 {218,"colour bit depth unsupported"},
 {219,"explicit chroma layout unsupported"},
 {220,"colour range unsupported"},
 {221,"video DefaultDuration required for final sample"},
 {222,"ASC/container audio rate/channels/bitdepth conflict"},
 {223,"AAC delay/preroll cap"},
 {224,"CodecDelay not an integer sample count within 1 ns"},
 {225,"AAC DefaultDuration inconsistent with 1024-frame LC"},
 {226,"container timestamp tick too coarse for unique AAC frame grid"},
 {227,"requested time outside known Segment duration"},
 {228,"Cues unavailable without bounded SeekHead"},
 {229,"multiple Cues entries"},
 {230,"SeekHead has no Cues; no sequential remux fallback"},
 {231,"Cues parse"},
 {232,"Cues metadata size cap"},
 {233,"Cues load"},
 {234,"cue count cap"},
 {235,"cue timestamp ordering"},
 {236,"video cue bounds"},
 {237,"video cue index unavailable"},
 {238,"no video cue at or before requested time"},
 {239,"cue position/block cap"},
 {240,"direct cue cluster"},
 {241,"cue exact video key unavailable within bounded cluster"},
 {242,"cue must resolve exact prior video keyframe"},
 {243,"container/VP9 range conflict"},
 {244,"VP9 bitstream/container dimensions differ"},
 {245,"first source cluster metadata"},
 {246,"first source cluster"},
 {247,"first AAC anchor unavailable within first-cluster 64-entry bound"},
 {248,"audio starts after video origin: gap unsupported"},
 {249,"AAC preroll exceeds 8 access units"},
 {250,"initial AAC priming exception only at source first cluster"},
 {251,"negative audio edit unsupported"},
 {252,"previous cue cluster for bounded AAC preroll"},
 {253,"generation metadata cluster cap"},
 {254,"generation metadata block cap"},
 {255,"video timestamps not strictly increasing"},
 {256,"video frame duration cap"},
 {257,"video metadata count cap"},
 {258,"AAC raw timestamps not strictly increasing"},
 {259,"AAC missing/duplicate access unit on global sample grid"},
 {260,"AAC DiscardPadding only supported on source final packet"},
 {261,"AAC metadata count cap"},
 {262,"next cluster parse"},
 {263,"planned A/V window empty"},
 {264,"previous cue cluster does not contain required AAC preroll; no from-zero fallback"},
 {265,"missing finite window boundary"},
 {266,"terminal padding encountered at finite boundary without source EOF"},
 {267,"audio presentation window/end unsupported"},
 {268,"AAC nonterminal padding unsupported"},
 {269,"exact AAC preroll start unavailable"},
 {270,"audio never reaches video origin"},
 {271,"retire imported staging file"},
 {272,"generation cancelled while waiting"},
 {273,"tail cue must resolve real source EOF"},
 {274,"requested time beyond presentation end"},
 {275,"no cue before requested time"},
 {276,"GOP exceeds four-second cap or is unordered"},
 {277,"startup playlist exceeds twelve-fragment staging contract"},
 {278,"exact per-GOP plan"},
 {279,"unexpected continuous EOF"},
 {280,"terminal metadata differs from tail plan"},
 {281,"receipt exists"},
 {282,"receipt open"},
 {283,"output read"},
 {284,"unsupported SDR CICP metadata"},
 {285,"unsupported VP9 colour space for profile 0"},
 {286,"container/VP9 matrix conflict"},
 {287,"container/VP9 primaries conflict"},
 {288,"container/VP9 transfer conflict"},
 {289,"colr"},
 {290,"leading AAC gap requires source first cluster and less than four seconds"},
 {291,"finite leading audio gap edit"},
 {292,"leading AAC gap must leave audio in first GOP"},
 {293,"fragment sample count cap"},
 {294,"fragment payload byte cap"},
 {295,"serialized fragment byte cap"},
 {296,"serialized init byte cap"},
 {297,"staging aggregate byte cap"},
 {298,"generation empty metadata cluster cap"},
 {299,"metadata cluster offset must advance"},
 {300,"first AAC anchor unavailable within bounded source-start metadata scan"},
 {301,"startup playlist exceeds bounded App window segment contract"},
 {302,"AAC source timestamp exceeds bounded retiming policy"},
 {303,"continuous AAC source boundary identity mismatch"},
};
uint32_t reasonCode(const std::string&s){for(const auto&r:reasons)if(s==r.message)return r.code;return 1;}
const char*reasonMessage(uint32_t code){for(const auto&r:reasons)if(code==r.code)return r.message;return reasons[1].message;}
void diagnosticStage(uint32_t stage){if(!session)return;std::lock_guard<std::mutex>g(session->lock);if(!session->diagnostic.reasonCode)session->diagnostic.stage=stage;}
template<class F>void diagnosticObserve(uint64_t mask,F update){if(!session)return;std::lock_guard<std::mutex>g(session->lock);if(!session->diagnostic.reasonCode){update(session->diagnostic);session->diagnostic.observedMask|=mask;}}
void diagnosticPlan(uint32_t kind){diagnosticObserve(1048576,[&](SAPDiagnostics&d){d.observedMask&=~uint64_t(2097152|4194304|8388608|16777216|33554432|67108864|134217728|268435456|536870912|1073741824);d.observedMask&=~(uint64_t(1)<<33);d.planKind=kind;});}
constexpr uint64_t PERF_MASK=uint64_t(1)<<31,STARTUP_MASK=uint64_t(1)<<32,SCAN_MASK=uint64_t(1)<<33,RETIMING_MASK=uint64_t(1)<<34;
void diagnosticScan(const vista_mkv::MetadataScanBudget&scan){diagnosticObserve(SCAN_MASK,[&](SAPDiagnostics&d){d.metadataClusters=uint32_t(scan.clusters);d.metadataEmptyClusters=uint32_t(scan.emptyClusters);d.metadataBlocks=uint32_t(scan.blocks);});}
static_assert(vista_mkv::MetadataScanBudget::maxBlocks==PACKET_COUNT,"unchanged planner block envelope");
static_assert(sizeof(SAPDiagnostics)<=1024,"fixed-size diagnostic envelope");
uint64_t monotonicNS(){timespec t{};clock_gettime(CLOCK_MONOTONIC,&t);return uint64_t(t.tv_sec)*NS+uint64_t(t.tv_nsec);}
void addSaturated(uint64_t&out,uint64_t value){out=value>UINT64_MAX-out?UINT64_MAX:out+value;}
struct TimedDiagnostic {
 uint64_t SAPDiagnostics::*field;uint64_t started=monotonicNS();
 ~TimedDiagnostic(){const uint64_t elapsed=monotonicNS()-started;diagnosticObserve(PERF_MASK,[&](SAPDiagnostics&d){addSaturated(d.*field,elapsed);});}
};
void diagnosticFailure(uint32_t code,int32_t native=0){if(!session)return;std::lock_guard<std::mutex>g(session->lock);if(!session->diagnostic.reasonCode){session->diagnostic.reasonCode=code;session->diagnostic.nativeCode=native;}}
void need(bool b,const std::string&s){if(!b){diagnosticFailure(reasonCode(s));throw std::runtime_error(s);}}
void check(GF_Err e,const char*s){if(e){diagnosticFailure(reasonCode(s),int32_t(e));throw std::runtime_error(std::string(s)+": "+gf_error_to_string(e));}}
std::string q(const std::string&s){std::ostringstream o;o<<'"';for(unsigned char c:s){if(c=='"'||c=='\\')o<<'\\'<<c;else if(c<32)o<<"\\u"<<std::hex<<std::setw(4)<<std::setfill('0')<<unsigned(c);else o<<c;}o<<'"';return o.str();}
void event(const std::string&s){if(s.find("\"kind\":\"packet\"")!=std::string::npos||s.find("\"kind\":\"mux_sample\"")!=std::string::npos||s.find("\"kind\":\"source_read\"")!=std::string::npos)return;auto&c=*session;if(c.eventCount>=2048||s.size()+128>1048576-c.eventBytes)return;timespec t{};clock_gettime(CLOCK_MONOTONIC,&t);uint64_t n=uint64_t(t.tv_sec)*NS+t.tv_nsec;c.events<<s.substr(0,s.size()-1)<<",\"generation\":"<<c.generation<<",\"commonClockNS\":"<<n<<"}\n";c.events.flush();need(bool(c.events),"event write");++c.eventCount;c.eventBytes+=s.size()+128;}
struct Reader final:mkvparser::IMkvReader {
 struct Page{std::array<uint8_t,READ_MAX>b{};int64_t start=-1;size_t len=0;};std::array<Page,WINDOW/READ_MAX>pages{};size_t next=0;
 // One common metadata/payload window. The original cache remains the fallback
 // before the key payload is known, or when a metadata-only reserve cannot fit.
 std::array<uint8_t,PAYLOAD_READ_MAX>ahead{};int64_t aheadStart=-1;size_t aheadLen=0;
 bool coalescing=false;size_t demandBase=0,demandLimit=0;
 int64_t size=0;size_t calls=0,requestedBytes=0,physicalBytes=0,physicalReads=0,evictions=0,metadataBytes=0;std::string stage="headers";size_t callBase=0,requestBase=0,physicalBase=0,metadataBase=0;
 size_t phaseReadLimit=READ_TOTAL;std::chrono::steady_clock::time_point started=std::chrono::steady_clock::now();
 Reader(){diagnosticStage(1);need(session->source.knownSize>0&&session->source.knownSize<=uint64_t(INT64_MAX),"validated source size must fit positive Int64 offset");size=session->source.knownSize;stable();}
 void beginPhase(bool mux=false){callBase=calls;requestBase=requestedBytes;physicalBase=physicalBytes;metadataBase=metadataBytes;phaseReadLimit=mux?MUX_READ_TOTAL:READ_TOTAL;started=std::chrono::steady_clock::now();coalescing=mux;demandBase=requestedBytes;demandLimit=mux?PAYLOAD_MAX:0;}
 // planAt calls this only after its sole keyframe payload has been consumed.
 // Reserve every remaining metadata byte, including repeated logical reads.
 // If it does not fit, retain the old cache policy for this entire phase.
 void metadataOnly(){
  const size_t remaining=METADATA_TOTAL-(metadataBytes-metadataBase);
  if(remaining<=phaseReadLimit-(physicalBytes-physicalBase)){coalescing=true;demandBase=requestedBytes;demandLimit=remaining;}
 }
 void live(){need(!session->cancel.load(),"generation cancelled");need(std::chrono::steady_clock::now()-started<std::chrono::seconds(20),"20-second generation deadline");}
 void stable(){live();const auto start=monotonicNS();const int result=session->source.validate(session->source.context);const auto elapsed=monotonicNS()-start;diagnosticObserve(PERF_MASK,[&](SAPDiagnostics&d){addSaturated(d.sourceValidateCalls,1);addSaturated(d.sourceValidateNS,elapsed);});need(result==1,"source revision invalid or generation cancelled");}
 // Shared callback measurement; each caller retains its own range/budget and
 // revision guard. Local checked reads coalesce redundant preflight coordination.
 void beforePhysicalRead(){
  // Generic callbacks retain the original stable() requirement. The opt-in
  // local callback owns coordinated pre/read/post checks and rejects stale data.
  if(session->source.readExactChecksRevision == 1) live(); else stable();
 }
 void sourceFetch(int64_t off,size_t count,uint8_t*out){
  const auto readStart=monotonicNS();const int result=session->source.readExact(session->source.context,off,uint32_t(count),out);const auto elapsed=monotonicNS()-readStart;
  diagnosticObserve(PERF_MASK,[&](SAPDiagnostics&d){addSaturated(d.sourceReadCalls,1);addSaturated(d.sourceReadBytes,count);addSaturated(d.sourceReadNS,elapsed);});
  need(result==0,"async source exact read failed/invalidated");
 }
 int Length(long long*t,long long*a)override{live();*t=*a=size;return 0;} // available means random-readable local file, NOT retained RAM
 int Read(long long off,long len,unsigned char*out)override{
  live();need(off>=0&&len>=0&&size_t(len)<=READ_MAX&&++calls-callBase<=READ_CALL_MAX,"reader call/range cap");if(off>size||len>size-off)return -1; // known real EOF is never temporary underflow
  need(size_t(len)<=phaseReadLimit-(requestedBytes-requestBase),"parser requested byte cap");requestedBytes+=len;
  if(stage!="payload"){need(size_t(len)<=METADATA_TOTAL-(metadataBytes-metadataBase),"metadata byte cap");metadataBytes+=len;}
  readBytes(off,size_t(len),out,false);return 0;
 }
 // requestedBytes already includes this complete logical call. A speculative
 // fill may spend only physical bytes left after reserving all future demand.
 // Thus sparse misses can fall back to exact reads without exhausting a phase
 // that could have fit its admitted metadata/GOP demand. No budget is increased.
 void readBytes(int64_t off,size_t len,uint8_t*out,bool large){
  size_t copied=0;while(copied<len){
   live();const int64_t at=off+int64_t(copied);
   Page*p=nullptr;for(auto&x:pages)if(x.start<=at&&x.start>=0&&at-x.start<int64_t(x.len)){p=&x;break;}
   if(p){const size_t k=std::min(len-copied,p->len-size_t(at-p->start));memcpy(out+copied,p->b.data()+size_t(at-p->start),k);copied+=k;continue;}
   if(aheadStart>=0&&at>=aheadStart&&uint64_t(at-aheadStart)<aheadLen){
    // Preserve the original four-page locality for sparse/backward parser
    // access even after a different read-ahead window replaces this one.
    // Large exact keyframe reads must not evict the fallback metadata slots.
    const int64_t pageStart=(at/READ_MAX)*READ_MAX;
    const size_t pageLen=std::min<int64_t>(READ_MAX,size-pageStart);
    if(!large&&pageStart>=aheadStart&&uint64_t(pageStart-aheadStart)+pageLen<=aheadLen){
     p=&pages[next++%pages.size()];if(p->start>=0)++evictions;p->start=pageStart;p->len=pageLen;
     memcpy(p->b.data(),ahead.data()+size_t(pageStart-aheadStart),pageLen);
    }
    const size_t k=std::min(len-copied,aheadLen-size_t(at-aheadStart));memcpy(out+copied,ahead.data()+size_t(at-aheadStart),k);copied+=k;continue;
   }
   if(coalescing||large){
    int64_t fetchAt=at;size_t want=std::min(PAYLOAD_READ_MAX,len-copied);
    const size_t remainingPhysical=phaseReadLimit-(physicalBytes-physicalBase);
    if(coalescing){
     need(requestedBytes-demandBase<=demandLimit,"parser requested byte cap");
     const size_t prefix=size_t(at%READ_MAX);
     const size_t alignedDemand=std::min(PAYLOAD_READ_MAX-prefix,len-copied);
     const size_t alignedFuture=demandLimit-(requestedBytes-demandBase)+(len-copied-alignedDemand);
     size_t future=demandLimit-(requestedBytes-demandBase)+(len-copied-want);
     if(alignedFuture<=remainingPhysical&&prefix+alignedDemand<=remainingPhysical-alignedFuture){fetchAt=at-int64_t(prefix);future=alignedFuture;want=prefix+alignedDemand;}
     need(future<=remainingPhysical&&want<=remainingPhysical-future,"physical read byte cap");
     want=std::min({PAYLOAD_READ_MAX,size_t(size-fetchAt),remainingPhysical-future});
    }else need(want<=remainingPhysical,"physical read byte cap");
    beforePhysicalRead();aheadStart=-1;aheadLen=0;sourceFetch(fetchAt,want,ahead.data());
    physicalBytes+=want;++physicalReads;live();aheadStart=fetchAt;aheadLen=want;
   }else{
    p=&pages[next++%pages.size()];if(p->start>=0)++evictions;beforePhysicalRead();p->start=(at/READ_MAX)*READ_MAX;p->len=0;
    const size_t want=std::min<int64_t>(READ_MAX,size-p->start);need(want<=phaseReadLimit-(physicalBytes-physicalBase),"physical read byte cap");
    sourceFetch(p->start,want,p->b.data());physicalBytes+=want;++physicalReads;live();p->len=want;
   }
  }
 }
 std::vector<uint8_t> payload(int64_t off,size_t n){
  need(n>0&&n<=PACKET_MAX&&off>=0&&off<=size&&n<=uint64_t(size-off),"packet source bounds");
  std::vector<uint8_t>b(n);auto old=stage;stage="payload";
  if(n<=READ_MAX){need(Read(off,n,b.data())==0,"payload read");}
  else for(size_t i=0;i<n;){
   // The common window can also satisfy adjacent metadata and AAC. In early
   // planning these chunks remain exact, with no speculative keyframe overread.
   live();const size_t k=std::min(PAYLOAD_READ_MAX,n-i);
   need(++calls-callBase<=READ_CALL_MAX,"reader call/range cap");
   need(k<=phaseReadLimit-(requestedBytes-requestBase),"parser requested byte cap");
   requestedBytes+=k;readBytes(off+int64_t(i),k,b.data()+i,true);i+=k;
  }
  stage=old;return b;
 }

 void eofCheck(){stable();need(session->source.verifyEOF(session->source.context)==1,"source-owner physical EOF verification");++physicalReads;event("{\"kind\":\"source_eof_verified\",\"offset\":"+std::to_string(size)+",\"length\":0}");}
};
struct Bits{const uint8_t*p;size_t n,at=0;unsigned get(unsigned k){need(at+k<=n*8,"VP9 header bounds");unsigned v=0;while(k--){v=(v<<1)|((p[at/8]>>(7-at%8))&1);++at;}return v;}};
struct Packet{std::vector<uint8_t>b;int64_t global=0,offset=0,padding=0,n=0,dts=0;uint32_t duration=0;bool key=false;size_t index=0;int track=1;};
struct VPConfig{unsigned width=0,height=0;bool full=false;unsigned colourSpace=0;vista_colour::Resolved colour{};};
VPConfig validateVP9(const Packet&p,const VPConfig*expected){
 std::vector<size_t>sizes;size_t end=p.b.size();need(end>0,"empty VP9");uint8_t marker=p.b.back();if((marker&0xe0)==0xc0){size_t count=(marker&7)+1,mag=((marker>>3)&3)+1,n=2+count*mag;if(n<=end&&p.b[end-n]==marker){size_t sum=0;for(size_t i=0;i<count;++i){size_t k=0;for(size_t j=0;j<mag;++j)k|=size_t(p.b[end-n+1+i*mag+j])<<(8*j);need(k>0&&k<=PACKET_MAX,"superframe component size");sizes.push_back(k);sum+=k;}need(sum+n==end,"superframe accounting");end-=n;}}
 if(sizes.empty())sizes.push_back(end);size_t pos=0;VPConfig cfg=expected?*expected:VPConfig{};
 for(size_t i=0;i<sizes.size();++i){Bits b{p.b.data()+pos,sizes[i]};need(b.get(2)==2,"VP9 marker");auto low=b.get(1),high=b.get(1);diagnosticObserve(16,[&](SAPDiagnostics&d){d.vp9Profile=low|(high<<1);});need((low|(high<<1))==0,"unsupported VP9 profile (only 0)");need(!b.get(1),"VP9 show-existing unsupported");bool inter=b.get(1),show=b.get(1);b.get(1);need(show==(i+1==sizes.size()),"only one visible terminal VP9 component supported");
  if(!inter){need(p.key&&i==0&&sizes.size()==1,"key/superframe correspondence");need(b.get(24)==0x498342,"VP9 sync");auto colour=b.get(3);diagnosticObserve(32,[&](SAPDiagnostics&d){d.vp9ColourSpace=colour;});need(colour<=5,"unsupported VP9 colour space for profile 0");bool full=b.get(1);diagnosticObserve(131072,[&](SAPDiagnostics&d){d.vp9FullRange=full?1:0;});unsigned w=b.get(16)+1,h=b.get(16)+1;diagnosticObserve(262144,[&](SAPDiagnostics&d){d.vp9KeyWidth=w;d.vp9KeyHeight=h;});need(vista_colour::GeometrySupported(w,h),"VP9 dimensions cap");if(expected)need(w==cfg.width&&h==cfg.height&&full==cfg.full&&colour==cfg.colourSpace,"midstream VP9 configuration change unsupported");cfg.width=w;cfg.height=h;cfg.full=full;cfg.colourSpace=colour;}else need(!p.key,"VP9 inter marked key");pos+=sizes[i];}
 need(pos==end&&cfg.width&&cfg.height,"VP9 key config unavailable");return cfg;
}
uint32_t be32(const uint8_t*p){return(uint32_t(p[0])<<24)|(uint32_t(p[1])<<16)|(uint32_t(p[2])<<8)|p[3];}
struct ClosedOutput {size_t bytes=0;std::string hash;};
ClosedOutput inspectOutput(Reader&r,const fs::path&p,bool init){
 TimedDiagnostic timer{&SAPDiagnostics::outputInspectNS};
 struct OwnedFD{int value;~OwnedFD(){if(value>=0)close(value);}}fd{open(p.c_str(),O_RDONLY|O_NOFOLLOW)};
 need(fd.value>=0,"open output");struct stat st{};need(!fstat(fd.value,&st)&&S_ISREG(st.st_mode)&&st.st_size>0,"output file cap");
 const uint64_t bytes=uint64_t(st.st_size);
 diagnosticObserve(536870912,[&](SAPDiagnostics&d){d.muxFragmentBytes=bytes;});
 need(bytes<=(init?INIT_MAX:FILE_MAX),init?"serialized init byte cap":"serialized fragment byte cap");
 auto exact=[&](size_t offset,uint8_t*buffer,size_t count){size_t got=0;while(got<count){r.live();auto n=pread(fd.value,buffer+got,count-got,off_t(offset+got));if(n<0&&errno==EINTR)continue;need(n>0,"output read");got+=size_t(n);}};
 // Inspect top-level boxes without copying their payload. The independent hash
 // pass uses one fixed 16 KiB buffer, never a serialized-fragment-sized vector.
 size_t at=0;int ftyp=0,moov=0,moof=0,mdat=0;
 while(at<bytes){need(bytes-at>=8,"output box header");uint8_t header[8];exact(at,header,sizeof(header));uint32_t n=be32(header);need(n>=8&&n<=bytes-at,"output box size");std::string t((char*)header+4,4);ftyp+=t=="ftyp";moov+=t=="moov";moof+=t=="moof";mdat+=t=="mdat";at+=n;}
 need(init?(ftyp==1&&moov==1&&!moof):(moof==1&&mdat==1&&!moov),"output box structure");
 CC_SHA256_CTX context{};CC_SHA256_Init(&context);std::array<uint8_t,READ_MAX>buffer{};
 for(size_t offset=0;offset<bytes;){size_t n=std::min<size_t>(buffer.size(),bytes-offset);exact(offset,buffer.data(),n);CC_SHA256_Update(&context,buffer.data(),CC_LONG(n));offset+=n;}
 uint8_t digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);std::ostringstream hash;for(auto x:digest)hash<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(x);
 struct stat after{};need(!fstat(fd.value,&after)&&after.st_dev==st.st_dev&&after.st_ino==st.st_ino&&after.st_size==st.st_size,"output file cap");return {size_t(bytes),hash.str()};
}
std::string name(unsigned n){std::ostringstream o;o<<"segment-"<<std::setw(3)<<std::setfill('0')<<n<<".m4s";return o.str();}
// Integer conversion: metadata nanoseconds may be rounded by <1 ns. Grid
// conversions used for edit origins must be exact; packet PTS tolerance is separate.
int64_t roundedSamples(int64_t ns,unsigned rate){need(ns>=0&&ns<=MAX_TIME,"sample conversion bounds");return int64_t((__int128(ns)*rate+NS/2)/NS);}
int64_t roundedNS(int64_t samples,unsigned rate){return vista_aac::RoundedNS(samples,rate);}
int64_t exactSamples(int64_t ns,unsigned rate){need(ns>=0&&ns<=MAX_TIME&&(__int128(ns)*rate)%NS==0,"video origin/window is not on exact audio sample grid");return int64_t(__int128(ns)*rate/NS);}
struct AAC {unsigned rate=0,channels=0;std::vector<uint8_t>asc;int64_t delay=0,seekRoll=0,anchor=0,scale=0;};
AAC parseASC(const uint8_t*p,size_t n){need(p&&n>=2&&n<=16,"AAC ASC size 2..16 required");Bits b{p,n};AAC a;a.asc.assign(p,p+n);unsigned objectType=b.get(5);if(objectType==31)objectType=32+b.get(6);diagnosticObserve(524288,[&](SAPDiagnostics&d){d.audioObjectType=objectType;});need(objectType==2,"only AAC-LC AOT 2 (no explicit SBR/PS)");unsigned ri=b.get(4);const unsigned rates[]={96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};need(ri<13||ri==15,"reserved AAC sample-rate index");a.rate=ri==15?b.get(24):rates[ri];diagnosticObserve(64,[&](SAPDiagnostics&d){d.audioSampleRate=a.rate;});need(a.rate>=8000&&a.rate<=96000,"AAC sample rate outside subset");a.channels=b.get(4);diagnosticObserve(128,[&](SAPDiagnostics&d){d.audioChannels=a.channels;});need(a.channels==1||a.channels==2,"only AAC mono/stereo channelConfiguration, no PCE");need(!b.get(1),"AAC frameLengthFlag 960 unsupported");need(!b.get(1),"AAC dependsOnCoreCoder unsupported");need(!b.get(1),"AAC GASpecific extensionFlag unsupported");
 if(n*8-b.at>7){need(b.get(11)==0x2b7&&b.get(5)==5,"unknown AAC sync extension");need(!b.get(1),"AAC SBR extension unsupported");if(n*8-b.at>7){need(b.get(11)==0x548,"unknown AAC extension after SBR");need(!b.get(1),"AAC PS extension unsupported");}}
 need(n*8-b.at<=7,"AAC trailing bits unsupported");while(b.at<n*8)need(b.get(1)==0,"nonzero ASC trailing bits");return a;
}
void inspectTrackTiming(Reader&r,const mkvparser::Track*t,bool audio,unsigned rate){
 long long p=t->m_element_start,stop=p+t->m_element_size,id=0,n=0;need(mkvparser::ParseElementHeader(&r,p,stop,id,n)==0&&id==0xAE&&p+n==stop,"TrackEntry bounds");
 while(p<stop){need(mkvparser::ParseElementHeader(&r,p,stop,id,n)==0,"TrackEntry field");if(id==0x23314F){double x=0;need(mkvparser::UnserializeFloat(&r,p,n,x)==0&&x==1,"TrackTimestampScale unsupported");}if(id==0x537F){long long x=0;need(mkvparser::UnserializeInt(&r,p,n,x)==0&&x==0,"TrackOffset unsupported");}if(audio&&id==0xE1){long long ap=p,ae=p+n;while(ap<ae){long long ai=0,an=0;need(mkvparser::ParseElementHeader(&r,ap,ae,ai,an)==0,"Audio settings bounds");if(ai==0x78B5){double x=0;need(mkvparser::UnserializeFloat(&r,ap,an,x)==0&&x==rate,"OutputSamplingFrequency conflicts with AAC-LC rate");}need(ai==0xB5||ai==0x78B5||ai==0x9F||ai==0x6264||ai==0xEC||ai==0xBF,"unknown Audio settings element");ap+=an;}}p+=n;}
}
struct Meta {int track=0;int64_t pts=0,off=0,len=0,pad=0,blockDuration=-1,n=0;bool key=false;uint32_t duration=0;};
Meta metadata(const mkvparser::BlockEntry*e,const mkvparser::Cluster*c,long video,long audio){auto*b=e->GetBlock();need(b&&b->GetFrameCount()==1&&b->GetLacing()==mkvparser::Block::kLacingNone&&!b->IsInvisible(),"unlaced visible blocks required");Meta m;m.track=b->GetTrackNumber()==video?1:b->GetTrackNumber()==audio?2:0;need(m.track,"unknown block track");auto f=b->GetFrame(0);m.pts=b->GetTime(c);m.off=f.pos;m.len=f.len;m.pad=b->GetDiscardPadding();m.key=b->IsKey();if(e->GetKind()==mkvparser::BlockEntry::kBlockGroup)m.blockDuration=static_cast<const mkvparser::BlockGroup*>(e)->GetDurationTimeCode();diagnosticObserve(268435456,[&](SAPDiagnostics&d){d.muxPacketTrack=m.track;d.muxPacketBytes=m.len>0?uint64_t(m.len):0;});need(m.len>0&&m.len<=int64_t(m.track==1?PACKET_MAX:4096),"packet size cap");need(m.pts>=0&&m.pts<=MAX_TIME,"negative/out-of-range raw timestamp unsupported");if(m.track==1)need(!m.pad&&m.blockDuration<0,"video DiscardPadding/explicit BlockDuration unsupported");else need(m.pad>=0,"negative AAC DiscardPadding unsupported");return m;}
const mkvparser::BlockEntry*entryAt(Reader&r,const mkvparser::Cluster*c,long i){for(;;){r.live();const mkvparser::BlockEntry*e=nullptr;auto st=c->GetEntry(i,e);if(st==0)return nullptr;if(st==mkvparser::E_BUFFER_NOT_FULL){long long p=0;long n=0;need(c->Parse(p,n)>=0,"cluster parse");continue;}need(st==1&&e,"block entry");return e;}}
struct CueRecord{int64_t time,m_pos,m_block;};
struct Plan {AAC a;VPConfig vp;int64_t origin=0,videoEnd=0,end=0,audioEnd=0,edit=0,emptyEditNS=0,firstN=0,discard=0;bool eof=false;std::vector<Meta>video,audio;std::vector<int64_t>ends,cueTimes;vista_mkv::MetadataScanBudget scan;};
vista_aac::Packet diagnosticAudioPacket(const AAC&a,int64_t pts,int64_t previous){
 const auto clock=vista_aac::PacketClock(pts,a.anchor,a.rate);
 diagnosticObserve(16777216,[&](SAPDiagnostics&d){d.audioPacketPTSNS=pts;d.audioPacketSourceIndex=clock.index;d.audioPacketResidual=clock.residual;d.audioPreviousSourceIndex=previous;});
 return clock;
}
int64_t audioIndex(const AAC&a,int64_t pts,const vista_aac::Packet&clock){
 need(pts>=a.anchor,"audio raw PTS before anchor");const auto n=clock.index;need(n>=0&&n<MAX_TIME*a.rate/(1024LL*NS),"audio grid index cap");
 const bool allowed=vista_aac::WithinBoundedRetiming(clock.residual,a.rate);
 diagnosticObserve(RETIMING_MASK,[&](SAPDiagnostics&d){const uint64_t magnitude=clock.residual<0?uint64_t(-clock.residual):uint64_t(clock.residual);d.audioRetimingMaxAbsResidual=std::max(d.audioRetimingMaxAbsResidual,magnitude);if(!allowed)d.audioRetimingLimitExceeded=1;});
 need(allowed,"AAC source timestamp exceeds bounded retiming policy");return n;
}
void audioMeta(AAC&a,Meta&m,const vista_aac::Packet&clock){m.n=audioIndex(a,m.pts,clock);m.duration=1024;if(m.pad){int64_t d=roundedSamples(m.pad,a.rate);need(d>0&&d<1024&&std::llabs(m.pad-roundedNS(d,a.rate))<=1,"AAC terminal padding not an integer sample count within 1 ns");m.duration-=d;}if(m.blockDuration>=0){auto ns=__int128(m.blockDuration)*a.scale;need(ns<=MAX_TIME&&std::llabs(int64_t(ns)-roundedNS(m.duration,a.rate))<=a.scale,"AAC BlockDuration inconsistent with LC valid frames after declared padding");}}

// A time slot is not packet identity. Bounded preroll includes the last emitted
// AAC (at least one preceding AU); require its exact source metadata witness.
// No payload is cached or hashed here. The existing source revision contract stays.
bool audioBoundaryMatches(const Meta&last,const std::vector<Meta>&window){
 auto witness=std::find_if(window.begin(),window.end(),[&](const Meta&m){return m.n==last.n;});
 return witness!=window.end()&&witness->track==last.track&&witness->off==last.off&&witness->len==last.len&&witness->pts==last.pts&&witness->pad==last.pad&&witness->blockDuration==last.blockDuration&&witness->duration==last.duration;
}

struct Mux {
 Reader&r;Plan base;int64_t nextAudio=0;bool haveAudioBoundary=false;Meta audioBoundary{};fs::path out;GF_ISOFile*movie=nullptr;bool sys=false,open=false;u32 vd=0,ad=0;size_t segments=0,outputPeak=0,peak=0,packetPeak=0,packetBufferPeak=0,totalPackets=0,vc=0,ac=0;std::vector<double>durations;
 Mux(Reader&rr,const Plan&pp):r(rr),base(pp),out(session->out){diagnosticStage(10);const Plan&p=base;nextAudio=p.firstN;
  need(fs::is_directory(fs::symlink_status(out))&&!fs::is_symlink(fs::symlink_status(out))&&fs::is_empty(out),"output must be empty regular directory");check(gf_sys_init(GF_MemTrackerNone,"n"),"GPAC init");sys=true;movie=gf_isom_open((out/"init.mp4.tmp").c_str(),GF_ISOM_OPEN_WRITE,nullptr);need(movie,"create init");check(gf_isom_set_timescale(movie,NS),"timescale");check(gf_isom_set_brand_info(movie,GF_4CC('i','s','o','6'),0),"brand");need(gf_isom_new_track(movie,1,GF_ISOM_MEDIA_VISUAL,NS)==1&&gf_isom_new_track(movie,2,GF_ISOM_MEDIA_AUDIO,p.a.rate)==2,"A/V tracks");for(u32 t=1;t<=2;++t)check(gf_isom_set_track_enabled(movie,t,GF_TRUE),"enable track");
  // Level 0 means Undefined in the VP9 MP4 binding, not a negotiated capability.
  GF_VPConfig vp{};vp.profile=0;vp.level=0;vp.bit_depth=8;vp.chroma_subsampling=p.vp.colour.chroma;vp.video_fullRange_flag=p.vp.full?GF_TRUE:GF_FALSE;vp.colour_primaries=p.vp.colour.primaries;vp.transfer_characteristics=p.vp.colour.transfer;vp.matrix_coefficients=p.vp.colour.matrix;check(gf_isom_vp_config_new(movie,1,&vp,nullptr,nullptr,&vd,GF_4CC('v','p','0','9')),"vpcC");check(gf_isom_set_visual_info(movie,1,vd,p.vp.width,p.vp.height),"dimensions");
  check(gf_isom_set_visual_color_info(movie,1,vd,GF_4CC('n','c','l','x'),vp.colour_primaries,vp.transfer_characteristics,vp.matrix_coefficients,vp.video_fullRange_flag,nullptr,0),"colr");
  GF_ESD*esd=gf_odf_desc_esd_new(2);need(esd&&esd->decoderConfig&&esd->decoderConfig->decoderSpecificInfo,"AAC descriptor");esd->ESID=2;esd->decoderConfig->streamType=GF_STREAM_AUDIO;esd->decoderConfig->objectTypeIndication=GF_CODECID_AAC_MPEG4;auto*dsi=esd->decoderConfig->decoderSpecificInfo;dsi->data=(u8*)gf_malloc(p.a.asc.size());need(dsi->data,"ASC allocation");memcpy(dsi->data,p.a.asc.data(),p.a.asc.size());dsi->dataLength=p.a.asc.size();auto rc=gf_isom_new_mpeg4_description(movie,2,esd,nullptr,nullptr,&ad);gf_odf_desc_del((GF_Descriptor*)esd);check(rc,"AAC description");check(gf_isom_set_audio_info(movie,2,ad,p.a.rate,p.a.channels,16,GF_IMPORT_AUDIO_SAMPLE_ENTRY_NOT_SET),"AAC info");
  if(p.emptyEditNS)check(gf_isom_set_edit(movie,2,0,p.emptyEditNS,0,GF_ISOM_EDIT_EMPTY),"finite leading audio gap edit");
  check(gf_isom_set_edit(movie,2,p.emptyEditNS,p.audioEnd-p.origin-p.emptyEditNS,p.edit,GF_ISOM_EDIT_NORMAL),"finite audio trim edit");check(gf_isom_setup_track_fragment(movie,1,1,0,0,0,0,0,GF_FALSE),"video fragment defaults");check(gf_isom_setup_track_fragment(movie,2,1,1024,0,0,0,0,GF_FALSE),"AAC fragment defaults");check(gf_isom_finalize_for_fragment(movie,1,GF_TRUE),"finalize init");begin();auto b=inspectOutput(r,out/"init.mp4.tmp",true);publish("init.mp4.tmp","init.mp4");event("{\"kind\":\"init_closed\",\"bytes\":"+std::to_string(b.bytes)+",\"width\":"+std::to_string(p.vp.width)+",\"height\":"+std::to_string(p.vp.height)+",\"audioSampleRate\":"+std::to_string(p.a.rate)+",\"audioChannels\":"+std::to_string(p.a.channels)+",\"audioLeadingEmptyEditNS\":"+std::to_string(p.emptyEditNS)+",\"audioEditMediaTime\":"+std::to_string(p.edit)+",\"audioEditDurationNS\":"+std::to_string(p.audioEnd-p.origin)+",\"audioPresentInOutput\":true}");
 }
 ~Mux(){if(movie)gf_isom_delete(movie);if(sys)gf_sys_close();}
 void bound(){
  uint64_t all=0;const uint64_t limit=uint64_t(session->maxSegments)*FILE_MAX+INIT_MAX;
  for(auto&e:fs::directory_iterator(out)){need(e.is_regular_file()&&!e.is_symlink(),"unexpected output entry");all+=e.file_size();}
  diagnosticObserve(1073741824,[&](SAPDiagnostics&d){d.muxStagingBytes=all;});need(all<=limit,"staging aggregate byte cap");
  outputPeak=std::max(outputPeak,size_t(all));
 }
 void publish(const std::string&a,const std::string&b){diagnosticStage(11);r.stable();bound();need(renamex_np((out/a).c_str(),(out/b).c_str(),RENAME_EXCL)==0,"no-replace atomic publication");}
 void begin(){need(!open&&segments<session->snap.totalSegments,"segment count/state");auto f=out/(name(segments+1)+".tmp");need(!fs::exists(f),"segment exists");check(gf_isom_start_segment(movie,f.c_str(),GF_FALSE),"start segment");open=true;}
 void produceOne(Plan p,bool final){diagnosticStage(10);
  diagnosticObserve(0,[](SAPDiagnostics&d){d.observedMask&=~uint64_t(536870912|1073741824);});
  const int64_t gopStart=p.origin;
  need(p.ends.size()==1&&p.vp.width==base.vp.width&&p.vp.height==base.vp.height&&p.vp.full==base.vp.full&&p.vp.colourSpace==base.vp.colourSpace&&p.vp.colour==base.vp.colour&&p.a.asc==base.a.asc&&p.a.rate==base.a.rate&&p.a.anchor==base.a.anchor&&p.a.delay==base.a.delay,"continuous track contract changed");
  if(haveAudioBoundary)need(audioBoundaryMatches(audioBoundary,p.audio),"continuous AAC source boundary identity mismatch");
  p.audio.erase(std::remove_if(p.audio.begin(),p.audio.end(),[&](const Meta&m){return m.n<nextAudio;}),p.audio.end());
  need(!p.audio.empty()&&p.audio.front().n==nextAudio,"continuous audio gap/duplicate boundary");
  p.origin=base.origin;p.firstN=base.firstN;
  const int64_t end=p.ends.front();
  size_t bytes=0,counts[3]={0,0,0};uint64_t retimedPackets=0;
  // The parser already bounded both metadata vectors. Preflight the complete
  // fragment before reading any payload, so rejection has exact whole-GOP
  // sample/byte observations and cannot leave a partially written fragment.
  for(const auto*track:{&p.video,&p.audio})for(const auto&m:*track){bytes+=size_t(m.len);++counts[m.track];}
  const size_t packets=counts[1]+counts[2];
  diagnosticObserve(134217728,[&](SAPDiagnostics&d){d.muxPacketCount=packets;d.muxPayloadBytes=bytes;});
  need(packets<=PACKET_COUNT,"fragment sample count cap");
  need(bytes<=PAYLOAD_MAX,"fragment payload byte cap");
  need(counts[1]>0&&counts[2]>0&&p.video.front().key&&p.video.front().pts==gopStart,"nonempty A/V GOP required");
  need(end>gopStart&&end-gopStart<=4*NS,"GOP duration cap");
  for(const auto&m:p.video)need(m.pts<end,"all planned A/V samples emitted exactly once");
  for(const auto&m:p.audio)need(__int128(m.n*1024-p.a.delay)*NS<__int128(end-p.a.anchor)*p.a.rate,"all planned A/V samples emitted exactly once");
  peak=std::max(peak,bytes);packetPeak=std::max(packetPeak,packets);
  event("{\"kind\":\"mux_capacity\",\"segment\":"+std::to_string(segments+1)+",\"packetCount\":"+std::to_string(packets)+",\"payloadBytes\":"+std::to_string(bytes)+",\"payloadCap\":"+std::to_string(PAYLOAD_MAX)+",\"serializedCap\":"+std::to_string(FILE_MAX)+",\"sampleCountCap\":"+std::to_string(PACKET_COUNT)+"}");
  if(!open)begin();check(gf_isom_start_fragment(movie,GF_ISOM_FRAG_MOOF_FIRST),"start fragment");
  for(int t=1;t<=2;++t){bool first=true;u32 local=0;const auto&track=t==1?p.video:p.audio;
   for(const auto&m:track){
    r.live();diagnosticObserve(268435456,[&](SAPDiagnostics&d){d.muxPacketTrack=m.track;d.muxPacketBytes=uint64_t(m.len);});
    Packet z;z.track=m.track;z.index=t==1?vc++:ac++;z.global=m.pts;z.offset=m.off;z.padding=m.pad;z.n=m.n;z.key=m.key;z.duration=m.duration;z.dts=t==1?m.pts-p.origin:(m.n-p.firstN)*1024;
    if(t==2&&!vista_aac::WithinTick(vista_aac::PacketClock(m.pts,p.a.anchor,p.a.rate).residual,p.a.scale,p.a.rate))++retimedPackets;
    z.b=r.payload(m.off,m.len);packetBufferPeak=std::max(packetBufferPeak,z.b.size());if(t==1)validateVP9(z,&p.vp);++totalPackets;
    if(first){check(gf_isom_set_fragment_option(movie,t,GF_ISOM_TFHD_FORCE_MOOF_BASE_OFFSET,1),"offset mode");check(gf_isom_set_traf_base_media_decode_time(movie,t,z.dts),"tfdt");first=false;}
    GF_ISOSample sm{};sm.data=z.b.data();sm.dataLength=z.b.size();sm.DTS=z.dts;sm.IsRAP=z.key?RAP:RAP_NO;
    // With no on_block_out callback/ref and no DataCache, the pinned GPAC writes
    // these bytes synchronously to its file bitstream. z is destroyed at the end
    // of this iteration. GPAC still allocates mdat at MOOF_FIRST close: not RSS.
    {TimedDiagnostic timer{&SAPDiagnostics::gpacWriteNS};check(gf_isom_fragment_add_sample(movie,t,&sm,t==1?vd:ad,z.duration,0,0,GF_FALSE),"fragment sample");}
    if(t==2)check(gf_isom_fragment_set_sample_roll_group(movie,2,++local,GF_ISOM_SAMPLE_ROLL,-1),"AAC decoder roll");
   }
  }
  {TimedDiagnostic timer{&SAPDiagnostics::gpacCloseNS};check(gf_isom_close_segment(movie,-1,0,0,0,0,GF_FALSE,GF_FALSE,final?GF_TRUE:GF_FALSE,GF_TRUE,0,nullptr,nullptr,nullptr),"close segment");}open=false;
  auto n=name(segments+1);auto b=inspectOutput(r,out/(n+".tmp"),false);publish(n+".tmp",n);
  // Advance the continuity witness/counters only after the fragment is closed,
  // inspected and atomically published. Failed muxes never advance this state.
  audioBoundary=p.audio.back();haveAudioBoundary=true;nextAudio=audioBoundary.n+1;
  diagnosticObserve(RETIMING_MASK,[&](SAPDiagnostics&d){addSaturated(d.audioRetimedPacketCount,retimedPackets);});
  ++segments;durations.push_back(double(end-gopStart)/NS);
  {std::lock_guard<std::mutex>g(session->lock);session->snap.publishedSegments=segments;session->snap.publishedGlobalEndNS=end;session->snap.actualSourceEOF=1;session->snap.sourceEOFValidatedDuringPlan=1;session->snap.terminalSegmentPublished=final;session->snap.windowComplete=final;session->segments[segments-1]={uint32_t(segments),end-gopStart,gopStart,end};}
  event("{\"kind\":\"segment_closed\",\"segment\":"+std::to_string(segments)+",\"name\":"+q(n)+",\"videoPackets\":"+std::to_string(counts[1])+",\"audioPackets\":"+std::to_string(counts[2])+",\"payloadBytes\":"+std::to_string(bytes)+",\"serializedBytes\":"+std::to_string(b.bytes)+",\"applicationPacketBufferPeakBytes\":"+std::to_string(packetBufferPeak)+",\"globalStartNS\":"+std::to_string(gopStart)+",\"globalEndNS\":"+std::to_string(end)+",\"itemStartNS\":"+std::to_string(gopStart-p.origin)+",\"itemEndNS\":"+std::to_string(end-p.origin)+",\"sha256\":"+q(b.hash)+",\"actualSourceEOF\":"+(p.eof?"true":"false")+",\"windowComplete\":"+(final?"true":"false")+"}");
 }

};
Plan planAt(Reader&reader,int64_t requested,std::vector<CueRecord>&index,uint32_t planKind){
 TimedDiagnostic timer{&SAPDiagnostics::planNS};
 const bool tail=planKind==1;diagnosticPlan(planKind);
 Reader*r=&reader;r->beginPhase();const unsigned maxSegments=1;vista_parser::Budget budget;
budget.cancelContext=r;budget.cancelCheck=[](void*){return session->cancel.load();};vista_parser::Scope scope(budget);need(scope.valid(),"parser budget");diagnosticStage(2);mkvparser::EBMLHeader header;long long pos=0;need(header.Parse(r,pos)==0&&header.m_docType&&!strcmp(header.m_docType,"matroska"),"unsupported/invalid EBML header");mkvparser::Segment*raw=nullptr;need(mkvparser::Segment::CreateInstance(r,pos,raw)==0&&raw,"Segment create");std::unique_ptr<mkvparser::Segment>seg(raw);need(seg->ParseHeaders()==0,"Segment headers");diagnosticStage(3);auto*tracks=seg->GetTracks();if(tracks)diagnosticObserve(1,[&](SAPDiagnostics&d){d.trackCount=uint32_t(std::min<unsigned long>(tracks->GetTracksCount(),UINT32_MAX));});need(tracks&&tracks->GetTracksCount()==2,"one VP9 plus one AAC track required");const mkvparser::VideoTrack*v=nullptr;const mkvparser::AudioTrack*a=nullptr;
  for(unsigned long i=0;i<tracks->GetTracksCount();++i){auto*t=tracks->GetTrackByIndex(i);need(t&&t->GetCodecId()&&!t->GetContentEncodingCount(),"encrypted/encoded tracks unsupported");if(t->GetType()==mkvparser::Track::kVideo){diagnosticObserve(2,[&](SAPDiagnostics&d){d.videoCodec=!strcmp(t->GetCodecId(),"V_VP9")?1:!strcmp(t->GetCodecId(),"V_MPEG4/ISO/AVC")?3:!strcmp(t->GetCodecId(),"V_MPEGH/ISO/HEVC")?4:!strcmp(t->GetCodecId(),"V_AV1")?5:2;});need(!v&&!strcmp(t->GetCodecId(),"V_VP9"),"single VP9 required");v=static_cast<const mkvparser::VideoTrack*>(t);}else{if(t->GetType()==mkvparser::Track::kAudio)diagnosticObserve(4,[&](SAPDiagnostics&d){d.audioCodec=!strcmp(t->GetCodecId(),"A_AAC")?1:2;});need(!a&&t->GetType()==mkvparser::Track::kAudio&&!strcmp(t->GetCodecId(),"A_AAC"),"single AAC required");a=static_cast<const mkvparser::AudioTrack*>(t);}}
  diagnosticStage(4);if(v)diagnosticObserve(8,[&](SAPDiagnostics&d){d.width=uint32_t(std::max<long long>(0,std::min<long long>(v->GetWidth(),UINT32_MAX)));d.height=uint32_t(std::max<long long>(0,std::min<long long>(v->GetHeight(),UINT32_MAX)));});need(v&&a&&!v->GetCodecDelay()&&!v->GetSeekPreRoll(),"VP9 delay/preroll unsupported");size_t privateSize=0;v->GetCodecPrivate(privateSize);need(privateSize==0,"VP9 CodecPrivate currently unsupported");need(v->GetDisplayUnit()==0&&v->GetDisplayWidth()==v->GetWidth()&&v->GetDisplayHeight()==v->GetHeight()&&v->GetStereoMode()==0&&!v->GetProjection()&&!v->GetColourSpace(),"non-default display/aspect/stereo/projection unsupported");
  vista_colour::Container containerColour;
  SAPDiagnostics colourTraits{};uint64_t colourMask=512|32768|65536;
  if(const auto*c=v->GetColour()){
   colourTraits.containerColourPresent=1;
   auto copy=[&](long long value,int64_t&raw,int64_t&normalized,uint64_t bit){if(value!=mkvparser::Colour::kValueNotPresent){raw=normalized=value;colourMask|=bit;}};
   copy(c->matrix_coefficients,colourTraits.containerMatrix,containerColour.matrix,1024);
   copy(c->transfer_characteristics,colourTraits.containerTransfer,containerColour.transfer,2048);
   copy(c->primaries,colourTraits.containerPrimaries,containerColour.primaries,4096);
   copy(c->range,colourTraits.containerRange,containerColour.range,8192);
   copy(c->bits_per_channel,colourTraits.containerBitsPerChannel,containerColour.bits,16384);
   auto chroma=[&](long long value,int64_t&raw,int64_t&normalized,unsigned bit){if(value!=mkvparser::Colour::kValueNotPresent){raw=normalized=value;colourTraits.containerChromaPresence|=bit;}};
   chroma(c->chroma_subsampling_horz,colourTraits.containerChromaSubsamplingHorz,containerColour.subH,1);
   chroma(c->chroma_subsampling_vert,colourTraits.containerChromaSubsamplingVert,containerColour.subV,2);
   chroma(c->cb_subsampling_horz,colourTraits.containerCbSubsamplingHorz,containerColour.cbH,4);
   chroma(c->cb_subsampling_vert,colourTraits.containerCbSubsamplingVert,containerColour.cbV,8);
   chroma(c->chroma_siting_horz,colourTraits.containerChromaSitingHorz,containerColour.sitingH,16);
   chroma(c->chroma_siting_vert,colourTraits.containerChromaSitingVert,containerColour.sitingV,32);
   containerColour.hdrMask=colourTraits.containerHdrMask=(c->mastering_metadata?1:0)|(c->max_cll!=mkvparser::Colour::kValueNotPresent?2:0)|(c->max_fall!=mkvparser::Colour::kValueNotPresent?4:0);
  }
  diagnosticObserve(colourMask,[&](SAPDiagnostics&d){
   d.containerColourPresent=colourTraits.containerColourPresent;
   d.containerMatrix=colourTraits.containerMatrix;d.containerTransfer=colourTraits.containerTransfer;d.containerPrimaries=colourTraits.containerPrimaries;d.containerRange=colourTraits.containerRange;d.containerBitsPerChannel=colourTraits.containerBitsPerChannel;
   d.containerChromaSubsamplingHorz=colourTraits.containerChromaSubsamplingHorz;d.containerChromaSubsamplingVert=colourTraits.containerChromaSubsamplingVert;d.containerCbSubsamplingHorz=colourTraits.containerCbSubsamplingHorz;d.containerCbSubsamplingVert=colourTraits.containerCbSubsamplingVert;d.containerChromaSitingHorz=colourTraits.containerChromaSitingHorz;d.containerChromaSitingVert=colourTraits.containerChromaSitingVert;
   d.containerChromaPresence=colourTraits.containerChromaPresence;d.containerHdrMask=colourTraits.containerHdrMask;
  });
  if(auto code=vista_colour::ValidateContainer(containerColour))need(false,reasonMessage(code));
  need(v->GetDefaultDuration()>0&&v->GetDefaultDuration()<=NS,"video DefaultDuration required for final sample");diagnosticStage(5);Plan plan;size_t an=0;const auto*asc=a->GetCodecPrivate(an);plan.a=parseASC(asc,an);auto&aa=plan.a;need(a->GetSamplingRate()==aa.rate&&a->GetChannels()==aa.channels&&(a->GetBitDepth()==0||a->GetBitDepth()==16||a->GetBitDepth()==24||a->GetBitDepth()==32),"ASC/container audio rate/channels/bitdepth conflict");need(a->GetCodecDelay()<=NS&&a->GetSeekPreRoll()<=NS,"AAC delay/preroll cap");aa.delay=roundedSamples(a->GetCodecDelay(),aa.rate);aa.seekRoll=roundedSamples(a->GetSeekPreRoll(),aa.rate);aa.scale=seg->GetInfo()->GetTimeCodeScale();diagnosticObserve(2097152,[&](SAPDiagnostics&d){d.containerTimestampTickNS=aa.scale;d.audioCodecDelaySamples=aa.delay;d.audioSeekPrerollSamples=aa.seekRoll;});need(std::llabs(int64_t(a->GetCodecDelay())-roundedNS(aa.delay,aa.rate))<=1,"CodecDelay not an integer sample count within 1 ns");need(a->GetDefaultDuration()==0||std::llabs(int64_t(a->GetDefaultDuration())-roundedNS(1024,aa.rate))<=1,"AAC DefaultDuration inconsistent with 1024-frame LC");need(aa.scale>0&&__int128(aa.scale)*aa.rate*2<1024LL*NS,"container timestamp tick too coarse for unique AAC frame grid");inspectTrackTiming(*r,v,false,0);inspectTrackTiming(*r,a,true,aa.rate);
  auto duration=seg->GetDuration();if(tail)requested=int64_t(duration)-1;need(duration>0&&duration<=MAX_TIME&&requested<duration,"requested time outside known Segment duration");
  diagnosticStage(6);if(index.empty()){
auto*sh=seg->GetSeekHead();const mkvparser::Cues*cues=seg->GetCues();r->stage="cues";if(!cues){need(sh&&sh->GetCount()<=64,"Cues unavailable without bounded SeekHead");int64_t off=-1;for(int i=0;i<sh->GetCount();++i){auto*e=sh->GetEntry(i);if(e&&e->id==0x1C53BB6B){need(off<0,"multiple Cues entries");off=e->pos;}}need(off>=0,"SeekHead has no Cues; no sequential remux fallback");long n=0;need(seg->ParseCues(off,pos,n)==0,"Cues parse");cues=seg->GetCues();}
  need(cues&&cues->m_size>0&&uint64_t(cues->m_size)<=METADATA_TOTAL,"Cues metadata size cap");diagnosticObserve(256,[&](SAPDiagnostics&d){d.cueCount=uint32_t(std::max<long>(0,std::min<long>(cues->GetCount(),UINT32_MAX)));});while(!cues->DoneParsing()){r->live();need(cues->LoadCuePoint(),"Cues load");diagnosticObserve(256,[&](SAPDiagnostics&d){d.cueCount=uint32_t(std::max<long>(0,std::min<long>(cues->GetCount(),UINT32_MAX)));});need(cues->GetCount()<=8192,"cue count cap");}

   int64_t last=-1;for(auto*c=cues->GetFirst();c;c=cues->GetNext(c)){auto t=c->GetTime(seg.get());need(t>=0&&t<=MAX_TIME&&t>=last,"cue timestamp ordering");last=t;if(auto*track=c->Find(v)){need(index.size()<8192&&track->m_pos>=0&&track->m_block>=1&&track->m_block<=2048,"video cue bounds");index.push_back({t,track->m_pos,track->m_block});}}
   need(!index.empty(),"video cue index unavailable");
  }
  diagnosticStage(7);auto at=std::upper_bound(index.begin(),index.end(),requested,[](int64_t t,const CueRecord&c){return t<c.time;});need(at!=index.begin(),"no video cue at or before requested time");--at;
  const CueRecord*chosen=&*at,*prior=at==index.begin()?nullptr:&*(at-1),*tp=chosen,*priorTP=prior;
  need(chosen&&tp,"no video cue at or before requested time");need(tp->m_pos>=0&&tp->m_block>=1&&tp->m_block<=2048,"cue position/block cap");r->stage="target_cluster_metadata";auto*target=seg->FindOrPreloadCluster(tp->m_pos);need(target&&!target->EOS(),"direct cue cluster");auto*first=entryAt(*r,target,tp->m_block-1);
  // CueBlockNumber defaults to 1; mirror libwebm's exact track/time fallback
  // within this already selected cluster, bounded to 2048 metadata entries.
  auto matches=[&](const mkvparser::BlockEntry*e){return e&&!e->EOS()&&e->GetBlock()->GetTrackNumber()==v->GetNumber()&&e->GetBlock()->GetTime(target)==chosen->time&&e->GetBlock()->IsKey();};
  if(!matches(first)){first=nullptr;for(long i=0;i<2048;++i){auto*e=entryAt(*r,target,i);if(!e)break;if(matches(e)){first=e;break;}}}
  need(first&&!first->EOS(),"cue exact video key unavailable within bounded cluster");auto key=metadata(first,target,v->GetNumber(),a->GetNumber());need(key.track==1&&key.key&&key.pts==chosen->time&&key.pts<=requested,"cue must resolve exact prior video keyframe");Packet kp;kp.b=r->payload(key.off,key.len);kp.key=true;plan.vp=validateVP9(kp,nullptr);kp.b.clear();r->metadataOnly();plan.origin=key.pts;diagnosticObserve(4194304,[&](SAPDiagnostics&d){d.selectedVideoOriginNS=plan.origin;});if(auto code=vista_colour::Resolve(containerColour,plan.vp.colourSpace,plan.vp.full,plan.vp.colour))need(false,reasonMessage(code));need(plan.vp.width==v->GetWidth()&&plan.vp.height==v->GetHeight(),"VP9 bitstream/container dimensions differ");
  // ParseHeaders stops at the first Cluster in Segment::m_pos. LoadCluster's
  // pos argument is output-only; a target preload and ParseCues cannot move it.
  // The first officially loaded cluster is inserted ahead of all preloads.
  // This bounded scan reads metadata only, never the source-start AAC payload.
  diagnosticStage(8);r->stage="audio_anchor_metadata";long ln=0;
  need(seg->LoadCluster(pos,ln)==0,"first source cluster metadata");
  const auto*fc=seg->GetFirst();need(fc&&!fc->EOS(),"first source cluster");
  // The anchor is still the true first source AAC packet. Container partitioning
  // and video/audio interleave do not define an audio-clock origin. This scan has
  // its own 2048-block allowance, sharing this plan's allocation/read/time caps.
  bool foundAnchor=false;vista_mkv::MetadataScanBudget anchorScan;const auto*anchorCluster=fc;
  for(;;){
   r->live();bool admitted=anchorScan.enterCluster();diagnosticScan(anchorScan);need(admitted,"generation metadata cluster cap");
   for(long i=0;;++i){auto*e=entryAt(*r,anchorCluster,i);if(!e)break;admitted=anchorScan.addBlock();diagnosticScan(anchorScan);need(admitted,"generation metadata block cap");auto m=metadata(e,anchorCluster,v->GetNumber(),a->GetNumber());if(m.track==2){aa.anchor=m.pts;foundAnchor=true;break;}}
   admitted=anchorScan.leaveCluster();diagnosticScan(anchorScan);need(admitted,"generation empty metadata cluster cap");if(foundAnchor)break;
   const mkvparser::Cluster*next=nullptr;auto st=seg->ParseNext(anchorCluster,next,pos,ln);need(st>=0,"next cluster parse");if(st>0||!next||next->EOS())break;
   need(vista_mkv::MetadataScanBudget::advances(anchorCluster->m_element_start,next->m_element_start),"metadata cluster offset must advance");anchorCluster=next;
  }
  need(foundAnchor,"first AAC anchor unavailable within bounded source-start metadata scan");
  event("{\"kind\":\"audio_anchor_scan\",\"metadataBlocks\":"+std::to_string(anchorScan.blocks)+",\"metadataClusters\":"+std::to_string(anchorScan.clusters)+",\"metadataEmptyClusters\":"+std::to_string(anchorScan.emptyClusters)+"}");
  diagnosticObserve(8388608,[&](SAPDiagnostics&d){d.sourceAudioAnchorNS=aa.anchor;});
  const auto originClock=vista_aac::OriginCut(plan.origin,aa.anchor,aa.rate,aa.delay);
  diagnosticObserve(33554432,[&](SAPDiagnostics&d){d.audioOriginDeltaNS=originClock.deltaNS;d.audioCutSample=originClock.cutSample;d.audioOriginResidual=originClock.residual;});
  need(originClock.exact,"video origin/window is not on exact audio sample grid");
  const int64_t cutSample=originClock.cutSample;
  // CodecDelay can cover a positive raw-PTS offset. Only a true decoded gap
  // needs an empty edit; it retains the source offset without silent packets.
  plan.emptyEditNS=cutSample<0?roundedNS(-cutSample,aa.rate):0;
  diagnosticObserve(67108864,[&](SAPDiagnostics&d){d.audioLeadingEmptyEditNS=plan.emptyEditNS;});
  if(cutSample<0)need(target==fc&&plan.emptyEditNS>0&&plan.emptyEditNS<4*NS,"leading AAC gap requires source first cluster and less than four seconds");
  const int64_t rollFrames=std::max<int64_t>(1,(aa.seekRoll+1023)/1024);need(rollFrames<=8,"AAC preroll exceeds 8 access units");
  int64_t firstN=cutSample<0?0:cutSample/1024-rollFrames;
  if(firstN<0){need(target==fc,"initial AAC priming exception only at source first cluster");firstN=0;}
  plan.firstN=firstN;plan.edit=cutSample<0?0:cutSample-firstN*1024;
  need(plan.edit>=0,"negative audio edit unsupported");
  diagnosticStage(9);diagnosticScan(plan.scan);r->stage="preroll_and_window_metadata";const mkvparser::Cluster*c=prior?seg->FindOrPreloadCluster(priorTP->m_pos):target;need(c&&!c->EOS(),"previous cue cluster for bounded AAC preroll");int64_t lastV=-1,lastA=-1,lastAN=-1;std::vector<Meta>rawAudio;int64_t boundary=-1;bool stop=false;size_t keys=0;
  for(;;){r->live();bool admitted=plan.scan.enterCluster();diagnosticScan(plan.scan);need(admitted,"generation metadata cluster cap");for(long i=0;;++i){auto*e=entryAt(*r,c,i);if(!e)break;admitted=plan.scan.addBlock();diagnosticScan(plan.scan);need(admitted,"generation metadata block cap");auto m=metadata(e,c,v->GetNumber(),a->GetNumber());if(m.track==1){if(m.pts<plan.origin)continue;need(m.pts>lastV,"video timestamps not strictly increasing");lastV=m.pts;if(boundary>=0)continue;if(m.key){if(keys){plan.ends.push_back(m.pts);if(plan.ends.size()==maxSegments)boundary=m.pts;}++keys;}if(!plan.video.empty()){int64_t d=m.pts-plan.video.back().pts;need(d>0&&d<=NS,"video frame duration cap");plan.video.back().duration=d;}if(boundary<0){need(plan.video.size()<1024,"video metadata count cap");plan.video.push_back(m);}}
    else{const auto clock=diagnosticAudioPacket(aa,m.pts,lastAN);need(m.pts>lastA,"AAC raw timestamps not strictly increasing");audioMeta(aa,m,clock);need(lastAN<0||m.n==lastAN+1,"AAC missing/duplicate access unit on global sample grid");need(rawAudio.empty()||rawAudio.back().pad==0,"AAC DiscardPadding only supported on source final packet");lastA=m.pts;lastAN=m.n;need(rawAudio.size()<1024,"AAC metadata count cap");rawAudio.push_back(m);}
    if(boundary>=0&&!rawAudio.empty()&&__int128(rawAudio.back().n*1024-aa.delay)*NS>=__int128(boundary-aa.anchor)*aa.rate){stop=true;break;}
   }admitted=plan.scan.leaveCluster();diagnosticScan(plan.scan);need(admitted,"generation empty metadata cluster cap");if(stop)break;const mkvparser::Cluster*next=nullptr;auto st=seg->ParseNext(c,next,pos,ln);need(st>=0,"next cluster parse");if(st>0||!next||next->EOS()){plan.eof=true;break;}need(vista_mkv::MetadataScanBudget::advances(c->m_element_start,next->m_element_start),"metadata cluster offset must advance");c=next;
  }
  need(!plan.video.empty()&&plan.video.front().key&&plan.video.front().pts==plan.origin&&!rawAudio.empty(),"planned A/V window empty");need(rawAudio.front().n<=firstN,"previous cue cluster does not contain required AAC preroll; no from-zero fallback");
  if(plan.eof){plan.video.back().duration=v->GetDefaultDuration();plan.videoEnd=plan.video.back().pts+plan.video.back().duration;auto&last=rawAudio.back();plan.discard=1024-last.duration;plan.audioEnd=aa.anchor+roundedNS(last.n*1024+last.duration-aa.delay,aa.rate);plan.end=std::max(plan.videoEnd,plan.audioEnd);plan.ends.push_back(plan.end);r->eofCheck();}
  else{need(boundary>=0,"missing finite window boundary");exactSamples(boundary-aa.anchor,aa.rate);plan.videoEnd=plan.end=plan.audioEnd=boundary;need(rawAudio.back().pad==0,"terminal padding encountered at finite boundary without source EOF");}
  need(plan.emptyEditNS==0||plan.emptyEditNS<plan.end-plan.origin,"leading AAC gap must leave audio in first GOP");
  need(plan.audioEnd>plan.origin&&plan.ends.size()<=maxSegments,"audio presentation window/end unsupported");for(auto m:rawAudio)if(m.n>=firstN&&__int128(m.n*1024-aa.delay)*NS<__int128(plan.audioEnd-aa.anchor)*aa.rate){need(!m.pad||(plan.eof&&m.off==rawAudio.back().off),"AAC nonterminal padding unsupported");plan.audio.push_back(m);}need(!plan.audio.empty()&&plan.audio.front().n==firstN,"exact AAC preroll start unavailable");need(plan.audio.back().n*1024+plan.audio.back().duration>=cutSample,"audio never reaches video origin");

 event("{\"kind\":\"gop_plan\",\"originNS\":"+std::to_string(plan.origin)+",\"videoPackets\":"+std::to_string(plan.video.size())+",\"audioPacketsIncludingPreroll\":"+std::to_string(plan.audio.size())+",\"metadataBlocks\":"+std::to_string(plan.scan.blocks)+",\"metadataClusters\":"+std::to_string(plan.scan.clusters)+",\"metadataEmptyClusters\":"+std::to_string(plan.scan.emptyClusters)+",\"parserCumulativeAllocation\":"+std::to_string(budget.charged.load())+",\"sourceEOF\":"+(plan.eof?"true":"false")+"}");
 return plan;
}

void retireStaging(){
 auto&s=*session;unsigned to=s.imported.load();
 while(s.cleaned<to){auto n=name(s.cleaned+1);need(!unlink((fs::path(s.out)/n).c_str()),"retire imported staging file");++s.cleaned;std::lock_guard<std::mutex>g(s.lock);s.snap.stagingRetiredSegments=s.cleaned;}
}
void awaitPermit(unsigned next,bool finalAck=false){
 auto&s=*session;for(;;){retireStaging();need(!s.cancel.load(),"generation cancelled while waiting");if(finalAck?s.imported.load()>=next:next<=s.imported.load()+s.maxSegments)return;
  diagnosticStage(12);s.state=4;std::unique_lock<std::mutex>g(s.lock);s.changed.wait(g,[&]{return s.cancel.load()||s.imported.load()>s.cleaned||(finalAck?s.imported.load()>=next:next<=s.imported.load()+s.maxSegments);});
 }
}
bool startupSegmentCountAllowed(size_t count){return count<=SAP_STARTUP_SEGMENT_MAX;}
int run(){try{
 Reader reader;std::vector<CueRecord>index;Plan tail=planAt(reader,0,index,1);need(tail.eof&&!index.empty(),"tail cue must resolve real source EOF");
 const int64_t wholeAudioEnd=tail.audioEnd,wholeVideoEnd=tail.videoEnd,wholeEnd=tail.end,discard=tail.discard;need(session->requested<wholeEnd,"requested time beyond presentation end");
 auto firstCue=std::upper_bound(index.begin(),index.end(),session->requested,[](int64_t t,const CueRecord&c){return t<c.time;});need(firstCue!=index.begin(),"no cue before requested time");--firstCue;
 std::vector<int64_t>cueTimes;for(auto i=firstCue;i!=index.end();++i)cueTimes.push_back(i->time);
 int64_t maxGOP=0;for(size_t i=0;i<cueTimes.size();++i){auto end=i+1<cueTimes.size()?cueTimes[i+1]:wholeEnd;need(end>cueTimes[i]&&end-cueTimes[i]<=4*NS,"GOP exceeds four-second cap or is unordered");maxGOP=std::max(maxGOP,end-cueTimes[i]);}
 const unsigned targetDuration=unsigned((maxGOP+NS-1)/NS);size_t startup=0;int64_t startupEnd=cueTimes.front();while(startup<cueTimes.size()&&startupEnd-cueTimes.front()<int64_t(3*targetDuration)*NS){startupEnd=startup+1<cueTimes.size()?cueTimes[startup+1]:wholeEnd;++startup;}diagnosticObserve(STARTUP_MASK,[&](SAPDiagnostics&d){d.startupTargetSeconds=targetDuration;d.startupRequiredSegments=uint32_t(startup);});need(startupSegmentCountAllowed(startup),"startup playlist exceeds bounded App window segment contract");
 tail.video.clear();tail.audio.clear();
 Plan first=planAt(reader,session->requested,index,2);Plan base=first;base.video.clear();base.audio.clear();base.ends.clear();base.audioEnd=wholeAudioEnd;base.videoEnd=wholeVideoEnd;base.end=wholeEnd;base.discard=discard;
 {std::lock_guard<std::mutex>g(session->lock);auto&s=session->snap;s.sourceHasAudio=1;s.verifiedKeyGlobalNS=s.itemOriginGlobalNS=base.origin;s.requestedItemNS=session->requested-base.origin;s.audioSampleRate=base.a.rate;s.audioChannels=base.a.channels;s.audioAnchorRawNS=base.a.anchor;s.codecDelaySamples=base.a.delay;s.firstAudioSourceIndex=base.firstN;s.audioEditMediaTime=base.edit;s.audioEditDurationNS=wholeAudioEnd-base.origin;s.audioFirstDecodedGlobalNS=base.a.anchor+roundedNS(base.firstN*1024-base.a.delay,base.a.rate);s.terminalDiscardSamples=discard;s.actualSourceEOF=1;s.sourceEOFValidatedDuringPlan=1;s.width=base.vp.width;s.height=base.vp.height;s.targetDurationSeconds=targetDuration;s.totalSegments=cueTimes.size();s.startupSegments=startup;s.wholePresentationEndNS=wholeEnd;s.wholeVideoEndNS=wholeVideoEnd;s.wholeAudioEndNS=wholeAudioEnd;}
 event("{\"kind\":\"engine_contract\",\"sourceEOFValidatedDuringPlan\":true,\"wholeAudioEndNS\":"+std::to_string(wholeAudioEnd)+",\"wholeVideoEndNS\":"+std::to_string(wholeVideoEnd)+",\"originNS\":"+std::to_string(base.origin)+",\"requestedItemNS\":"+std::to_string(session->requested-base.origin)+",\"totalSegments\":"+std::to_string(cueTimes.size())+",\"videoCueCount\":"+std::to_string(index.size())+",\"targetDuration\":"+std::to_string(targetDuration)+",\"startupSegments\":"+std::to_string(startup)+",\"audioLeadingEmptyEditNS\":"+std::to_string(base.emptyEditNS)+",\"audioEditMediaTime\":"+std::to_string(base.edit)+",\"audioFirstSourceIndex\":"+std::to_string(base.firstN)+",\"terminalDiscardSamples\":"+std::to_string(discard)+"}");
 reader.beginPhase();Mux mux(reader,base);
 for(size_t i=0;i<cueTimes.size();++i){
  awaitPermit(unsigned(i+1));session->state=1;
  Plan current=i==0?std::move(first):planAt(reader,cueTimes[i],index,3);need(current.origin==cueTimes[i]&&current.ends.size()==1,"exact per-GOP plan");bool final=i+1==cueTimes.size();need(current.eof==final,"unexpected continuous EOF");
  if(final)need(current.audioEnd==wholeAudioEnd&&current.videoEnd==wholeVideoEnd&&current.discard==discard,"terminal metadata differs from tail plan");
  reader.beginPhase(true);mux.produceOne(std::move(current),final);retireStaging();
 }
 awaitPermit(unsigned(cueTimes.size()),true);reader.beginPhase();reader.stable();
 event("{\"kind\":\"complete\",\"videoPackets\":"+std::to_string(mux.vc)+",\"audioPackets\":"+std::to_string(mux.ac)+",\"segments\":"+std::to_string(mux.segments)+",\"actualSourceEOF\":true,\"terminalSegmentPublished\":true,\"windowComplete\":true,\"physicalReadBytes\":"+std::to_string(reader.physicalBytes)+",\"sourceReadCalls\":"+std::to_string(reader.physicalReads)+",\"retainedCapacity\":327680,\"fragmentPayloadPeakBytes\":"+std::to_string(mux.peak)+",\"fragmentSamplePeak\":"+std::to_string(mux.packetPeak)+",\"applicationPacketBufferPeakBytes\":"+std::to_string(mux.packetBufferPeak)+",\"stagingPeakBytes\":"+std::to_string(mux.outputPeak)+"}");return 0;
 }catch(const std::exception&e){diagnosticFailure(dynamic_cast<const std::bad_alloc*>(&e)?2:reasonCode(e.what()));{std::lock_guard<std::mutex>g(session->lock);session->error=e.what();}event("{\"kind\":\"error\",\"message\":"+q(e.what())+",\"cancelled\":"+(session->cancel.load()?"true":"false")+"}");return 1;}
}
}

extern "C" SAP*sap_create(SAPSourceCallbacks source,const char*out,const char*receipt,uint64_t generation,int64_t requested,unsigned maxSegments){
 if(!source.context||!source.readExact||!source.validate||!source.verifyEOF||!out||!receipt||requested<0||requested>MAX_TIME||maxSegments<1||maxSegments>12||ownerBusy.exchange(true))return nullptr;
 try{auto s=std::make_unique<SAP>();s->diagnostic.schema=7;s->source=source;s->out=out;s->receipt=receipt;s->generation=generation;s->requested=requested;s->maxSegments=maxSegments;s->snap.generation=generation;s->snap.requestedGlobalNS=requested;s->snap.verifiedKeyGlobalNS=s->snap.itemOriginGlobalNS=s->snap.requestedItemNS=-1;need(!fs::exists(receipt),"receipt exists");s->events.open(receipt);need(bool(s->events),"receipt open");return s.release();}catch(...){ownerBusy=false;return nullptr;}
}
extern "C" int sap_start(SAP*s){if(!s)return 0;int e=0;if(!s->state.compare_exchange_strong(e,1))return 0;try{s->owner=std::thread([s]{session=s;int rc=1;try{rc=run();}catch(...){diagnosticFailure(1);}s->events.flush();if(rc==0)diagnosticStage(13);s->state=s->cancel.load()?5:rc?3:2;session=nullptr;});return 1;}catch(...){{std::lock_guard<std::mutex>g(s->lock);s->diagnostic.reasonCode=3;}s->state=3;return 0;}}
extern "C" void sap_cancel(SAP*s){if(s){s->cancel=true;s->changed.notify_all();}}
extern "C" void sap_join(SAP*s){if(s&&s->owner.joinable())s->owner.join();}
extern "C" void sap_destroy(SAP*s){if(s){sap_cancel(s);sap_join(s);for(unsigned i=s->cleaned+1;i<=s->snap.publishedSegments+1;++i){unlink((fs::path(s->out)/name(i)).c_str());unlink((fs::path(s->out)/(name(i)+".tmp")).c_str());}unlink((fs::path(s->out)/"init.mp4").c_str());unlink((fs::path(s->out)/"init.mp4.tmp").c_str());rmdir(s->out.c_str());delete s;ownerBusy=false;}}
extern "C" int sap_status(SAP*s){return s?s->state.load():-1;}
extern "C" int sap_snapshot(SAP*s,SAPSnapshot*out){if(!s||!out)return 0;std::lock_guard<std::mutex>g(s->lock);*out=s->snap;out->state=s->state.load();return 1;}

extern "C" int sap_segment_info(SAP*s,uint32_t i,SAPSegmentInfo*out){if(!s||!out)return 0;std::lock_guard<std::mutex>g(s->lock);if(!i||i>s->snap.publishedSegments)return 0;*out=s->segments[i-1];return 1;}
extern "C" int sap_error(SAP*s,char*out,uint32_t capacity){if(!s||!out||!capacity)return 0;std::lock_guard<std::mutex>g(s->lock);auto n=std::min<size_t>(capacity-1,s->error.size());memcpy(out,s->error.data(),n);out[n]=0;return int(n);}

extern "C" int sap_ack_imported(SAP*s,uint32_t i){if(!s||s->cancel.load())return 0;std::lock_guard<std::mutex>g(s->lock);if(i!=s->imported.load()+1||i>s->snap.publishedSegments)return 0;s->imported=i;s->changed.notify_all();return 1;}

extern "C" int sap_diagnostics(SAP*s,SAPDiagnostics*out){if(!s||!out)return 0;std::lock_guard<std::mutex>g(s->lock);*out=s->diagnostic;out->publishedSegments=s->snap.publishedSegments;return 1;}
extern "C" int sap_reason_message(uint32_t code,char*out,uint32_t capacity){if(!out||!capacity)return 0;const char*text=reasonMessage(code);size_t n=std::min<size_t>(capacity-1,strlen(text));memcpy(out,text,n);out[n]=0;return int(n);}
