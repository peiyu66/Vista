import Foundation
import dnssd
import Observation

struct DiscoveredSMB:Identifiable,Equatable {
    let id:String
    let name:String
    let host:String?
}
/// Only user-triggered DNS-SD browsing; never scans address ranges or opens SMB ports.
@MainActor @Observable final class SMBDiscovery:NSObject,@preconcurrency NetServiceBrowserDelegate,@preconcurrency NetServiceDelegate {
    var devices:[DiscoveredSMB]=[]
    private var currentIDs:Set<String>=[]
    private var fixtureStarts=0
    var hasStaleResults:Bool {devices.contains{!currentIDs.contains($0.id)}}
    func isCurrent(_ device:DiscoveredSMB)->Bool {currentIDs.contains(device.id)}
    var running=false
    var resolving=false
    var message:String?
    var selected:(String,String)?
    @ObservationIgnored private var browser:NetServiceBrowser?
    @ObservationIgnored private var services:[String:NetService]=[:]
    @ObservationIgnored private var resolver:NetService?
    @ObservationIgnored private var deadline:Task<Void,Never>?
    private var fixture:Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--network-discovery-fixture")
        #else
        false
        #endif
    }
    func start() {
        stop();currentIDs=[];selected=nil;message=nil;running=true
        if fixture {
            fixtureStarts += 1
            if ProcessInfo.processInfo.arguments.contains("--discovery-empty") {devices=[];return}
            if fixtureStarts>1,ProcessInfo.processInfo.arguments.contains("--discovery-stale") {return}
            devices=[DiscoveredSMB(id:"synthetic",name:"測試 NAS",host:"test-nas.example.test")]
            if ProcessInfo.processInfo.arguments.contains("--discovery-many") {
                devices += (1...8).map {DiscoveredSMB(id:"synthetic-\($0)",name:"範例伺服器 \($0)",host:"nas\($0).example.test")}
                running=true
            } else {running=false}
            currentIDs=Set(devices.map(\.id))
            return
        }
        let serviceBrowser=NetServiceBrowser();browser=serviceBrowser;serviceBrowser.delegate=self
        serviceBrowser.searchForServices(ofType:"_smb._tcp.",inDomain:"local.")
        deadline=Task {try? await Task.sleep(for:.seconds(15));guard !Task.isCancelled else{return};browser?.stop();running=false;if currentIDs.isEmpty {message="未找到可確認的 SMB 主機。可手動輸入，或檢查網路權限。"}}
    }
    func stop() {deadline?.cancel();deadline=nil;browser?.stop();browser?.delegate=nil;browser=nil;resolver?.stop();resolver?.delegate=nil;resolver=nil;services.removeAll();running=false;resolving=false}
    private func key(_ service:NetService)->String {service.name+"\u{0}"+service.type+"\u{0}"+service.domain}
    func netServiceBrowser(_ browser:NetServiceBrowser,didFind service:NetService,moreComing:Bool) {
        guard browser===self.browser,devices.count<100 else{return}
        let id=key(service);services[id]=service;currentIDs.insert(id)
        if !devices.contains(where:{$0.id==id}) {devices.append(DiscoveredSMB(id:id,name:service.name,host:nil));devices.sort{$0.name.localizedStandardCompare($1.name) == .orderedAscending}}
    }
    func netServiceBrowser(_ browser:NetServiceBrowser,didRemove service:NetService,moreComing:Bool) {guard browser===self.browser else{return};let id=key(service);devices.removeAll{$0.id==id};services[id]=nil;currentIDs.remove(id)}
    func netServiceBrowser(_ browser:NetServiceBrowser,didNotSearch errorDict:[String:NSNumber]) {guard browser===self.browser else{return};running=false;message="無法瀏覽區域網路。請確認權限與網路，或手動輸入主機。"}
    func select(_ device:DiscoveredSMB) {
        guard devices.contains(device),isCurrent(device) else{return}
        if fixture,let host=device.host {selected=(device.name,host);return}
        guard let service=services[device.id] else{return}
        resolver?.stop();resolver?.delegate=nil;resolver=service;resolving=true;message=nil
        service.delegate=self;service.resolve(withTimeout:8)
    }
    func netServiceDidResolveAddress(_ sender:NetService) {
        guard sender===resolver else{return};resolving=false
        guard sender.port==445,var host=sender.hostName else {message="此設備未提供可用的標準 SMB 位址，請手動輸入。";return}
        if host.hasSuffix("."){host.removeLast()}
        guard ConnectionInput(server:host,share:"placeholder",username:"placeholder").isValid else {message="無法使用此設備的主機位址，請手動輸入。";return}
        selected=(sender.name,host)
    }
    func netService(_ sender:NetService,didNotResolve errorDict:[String:NSNumber]) {guard sender===resolver else{return};resolving=false;message="無法解析此設備的位址，請重試或手動輸入。"}
}


/// Positive-only DNS-SD evidence, bound to the matching SMB endpoint and interface.
@MainActor final class BonjourTagProbe {
    private var references:[DNSServiceRef]=[]
    private var queries:[DNSServiceRef:(host:String,interface:UInt32)]=[:]
    private var seen:Set<String>=[]
    private var continuation:CheckedContinuation<Bool,Never>?
    private var deadline:Task<Void,Never>?
    private var endpoint=""
    func check(server:String) async ->Bool {
        guard continuation==nil else{return false}
        endpoint=server
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation=continuation
                if Task.isCancelled {finish(false);return}
                var ref:DNSServiceRef?
                let status=DNSServiceBrowse(&ref,0,0,"_smb._tcp.","local.",{_,flags,index,error,name,type,domain,context in
                    guard error==0,flags & UInt32(kDNSServiceFlagsAdd) != 0,let name,let type,let domain,let context else{return}
                    let instance=String(cString:name),serviceType=String(cString:type),serviceDomain=String(cString:domain)
                    MainActor.assumeIsolated {
                        Unmanaged<BonjourTagProbe>.fromOpaque(context).takeUnretainedValue()
                            .resolve(instance,type:serviceType,domain:serviceDomain,interface:index)
                    }
                },Unmanaged.passUnretained(self).toOpaque())
                guard attach(ref,status:status) else{finish(false);return}
                deadline=Task {try? await Task.sleep(for:.seconds(3));guard !Task.isCancelled else{return};finish(false)}
            }
        } onCancel:{Task {@MainActor in self.finish(false)}}
    }
    private func attach(_ ref:DNSServiceRef?,status:DNSServiceErrorType)->Bool {
        guard status==0,let ref else{return false}
        guard DNSServiceSetDispatchQueue(ref,.main)==0 else{DNSServiceRefDeallocate(ref);return false}
        references.append(ref);return true
    }
    private func resolve(_ name:String,type:String,domain:String,interface:UInt32) {
        guard continuation != nil,interface != 0,seen.count<16,seen.insert("\(interface)/"+name+"."+domain).inserted else{return}
        // Context has the service instance and domain so TXT lookup uses the same DNS-SD identity.
        var full=[CChar](repeating:0,count:Int(kDNSServiceMaxDomainName))
        guard DNSServiceConstructFullName(&full,name,"_device-info._tcp.",domain)==0 else{return}
        let deviceName=String(decoding:full.prefix(while:{$0 != 0}).map{UInt8(bitPattern:$0)},as:UTF8.self)
        var ref:DNSServiceRef?
        let status=DNSServiceResolve(&ref,0,interface,name,type,domain,{ref,_,index,error,fullName,host,port,length,txt,context in
            guard error==0,let ref,let host,let context else{return}
            let endpoint=String(cString:host)
            let data=length<=1024 && txt != nil ? Data(bytes:txt!,count:Int(length)):Data()
            MainActor.assumeIsolated {
                Unmanaged<BonjourTagProbe>.fromOpaque(context).takeUnretainedValue()
                    .resolved(ref:ref,host:endpoint,port:Int(UInt16(bigEndian:port)),interface:index,txt:data)
            }
        },Unmanaged.passUnretained(self).toOpaque())
        if attach(ref,status:status),let ref {resolveNames[ref]=deviceName}
    }
    private var resolveNames:[DNSServiceRef:String]=[:]
    private func resolved(ref:DNSServiceRef,host:String,port:Int,interface:UInt32,txt:Data) {
        guard continuation != nil,port==445,
              TagSupportEvidence.endpoint(host)==TagSupportEvidence.endpoint(endpoint),
              let deviceName=resolveNames.removeValue(forKey:ref) else{return}
        if TagSupportEvidence.bonjour(server:endpoint,resolvedHost:host,port:port,txt:NetService.dictionary(fromTXTRecord:txt)) {finish(true);return}
        var query:DNSServiceRef?
        let status=DNSServiceQueryRecord(&query,0,interface,deviceName,UInt16(kDNSServiceType_TXT),UInt16(kDNSServiceClass_IN),{ref,flags,index,error,_,type,_,length,bytes,_,context in
            guard error==0,flags & UInt32(kDNSServiceFlagsAdd) != 0,type==kDNSServiceType_TXT,
                  length<=1024,let ref,let bytes,let context else{return}
            let data=Data(bytes:bytes,count:Int(length))
            MainActor.assumeIsolated {
                Unmanaged<BonjourTagProbe>.fromOpaque(context).takeUnretainedValue().received(ref:ref,interface:index,data:data)
            }
        },Unmanaged.passUnretained(self).toOpaque())
        if attach(query,status:status),let query {queries[query]=(host,interface)}
    }
    private func received(ref:DNSServiceRef,interface:UInt32,data:Data) {
        guard continuation != nil,let query=queries[ref],query.interface==interface else{return}
        if TagSupportEvidence.bonjour(server:endpoint,resolvedHost:query.host,port:445,txt:NetService.dictionary(fromTXTRecord:data)) {finish(true)}
    }
    private func finish(_ value:Bool) {
        deadline?.cancel();deadline=nil
        for ref in references {DNSServiceRefDeallocate(ref)}
        references=[];queries=[:];resolveNames=[:];seen=[]
        let pending=continuation;continuation=nil;pending?.resume(returning:value)
    }
}
