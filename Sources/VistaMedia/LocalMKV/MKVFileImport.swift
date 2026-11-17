#if VISTA_LOCAL_MKV_CANDIDATE
import Foundation
import Darwin
enum MKVFileImport {
    // A bounded metadata preflight before allocating the whole imported Data. read()
    // rechecks the descriptor and exact size; producer files are immutable until ack.
    static func size(_ directory:URL,name:String,limit:Int) async throws -> Int {
        try await Task.detached(priority:.utility) {
            let dir=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
            guard dir>=0 else{throw MKVPlaybackError.failure(VistaL10n.text("片段資料夾無法讀取"))};defer{close(dir)}
            let fd=openat(dir,name,O_RDONLY|O_NOFOLLOW)
            guard fd>=0 else{throw MKVPlaybackError.failure(VistaL10n.text("尚未完整產生的片段"))};defer{close(fd)}
            var st=stat();guard fstat(fd,&st)==0,(st.st_mode&S_IFMT)==S_IFREG,st.st_size>0,st.st_size<=limit else{throw MKVPlaybackError.failure(VistaL10n.text("片段超過有界容量"))}
            return Int(st.st_size)
        }.value
    }

    static func read(_ directory: URL,name: String,limit: Int) async throws -> Data {
        try await Task.detached(priority:.utility) {
            let dir=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
            guard dir>=0 else{throw MKVPlaybackError.failure(VistaL10n.text("片段資料夾無法讀取"))};defer{close(dir)}
            let fd=openat(dir,name,O_RDONLY|O_NOFOLLOW)
            guard fd>=0 else{throw MKVPlaybackError.failure(VistaL10n.text("尚未完整產生的片段"))};defer{close(fd)}
            var st=stat();guard fstat(fd,&st)==0,(st.st_mode&S_IFMT)==S_IFREG,st.st_size>0,st.st_size<=limit else{throw MKVPlaybackError.failure(VistaL10n.text("片段超過有界容量"))}
            var data=Data(count:Int(st.st_size));let n=data.withUnsafeMutableBytes{pread(fd,$0.baseAddress!,$0.count,0)}
            guard n==data.count else{throw MKVPlaybackError.failure(VistaL10n.text("片段讀取不完整"))};return data
        }.value
    }
}
#endif
