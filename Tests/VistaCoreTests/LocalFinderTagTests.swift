import Foundation
import Darwin
import Testing
@testable import VistaCore

struct LocalFinderTagTests {
    private func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("VistaTags-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func put(_ data:Data,on url:URL)throws {
        let result=url.withUnsafeFileSystemRepresentation {path in
            data.withUnsafeBytes {buffer in setxattr(path!,LocalFinderTagReader.attribute,buffer.baseAddress,buffer.count,0,0)}
        }
        guard result==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
    }
    private func tags(_ values:[String],on url:URL)throws {
        try put(PropertyListSerialization.data(fromPropertyList:values,format:.binary,options:0),on:url)
    }
    @Test func realFileAndDirectoryMetadataReuseExistingParser() async throws {
        let root=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("movie.mp4"),child=root.appendingPathComponent("Child")
        let original=Data([1,2,3,4]);try original.write(to:file)
        try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        try tags(["旅行\n6","👩🏽‍💻工作\n0","Alpha\n4","旅行\n6"],on:file)
        try tags(["Folder\n2"],on:child)
        let provider=LocalDirectoryProvider(testRoot:root)
        let state=try await provider.tags(at:.init(["movie.mp4"]))
        #expect(state == FinderTagParser.parse(try PropertyListSerialization.data(fromPropertyList:["旅行\n6","👩🏽‍💻工作\n0","Alpha\n4","旅行\n6"],format:.binary,options:0)))
        #expect(state.displayTags.count==3)
        #expect(try await provider.tags(at:.init(["Child"])) == .loaded([FinderTag(name:"Folder",color:2)]))
        #expect(try Data(contentsOf:file)==original)
    }
    @Test func missingAndConfirmedEmptyRemainDistinct() async throws {
        let root=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("empty.txt");try Data().write(to:file)
        let provider=LocalDirectoryProvider(testRoot:root)
        #expect(try await provider.tags(at:.init(["empty.txt"])) == .unavailable)
        #expect(try await !provider.hasFinderTagEvidence(at:.init(),names:["empty.txt"],includeDirectory:true))
        try tags([],on:file)
        #expect(try await provider.tags(at:.init(["empty.txt"])) == .loaded([]))
        #expect(try await provider.hasFinderTagEvidence(at:.init(),names:["empty.txt"],includeDirectory:true))
        #expect(try await provider.tags(at:.init(["gone.txt"])) == .failed)
    }
    @Test func rereadingReflectsEditsRemovalAndFolderRefresh() async throws {
        let root=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("movie.mp4");try Data([9]).write(to:file)
        let provider=LocalDirectoryProvider(testRoot:root)
        _=try await provider.page(at:.init(),offset:0)
        try tags(["Before\n1"],on:file)
        #expect(try await provider.tags(at:.init(["movie.mp4"])).label=="Before")
        try tags(["After\n2"],on:file)
        await provider.invalidate()
        #expect(try await provider.tags(at:.init(["movie.mp4"])).label=="After")
        let removed=file.withUnsafeFileSystemRepresentation {removexattr($0!,LocalFinderTagReader.attribute,0)}
        #expect(removed==0)
        #expect(try await provider.tags(at:.init(["movie.mp4"])) == .unavailable)
    }
    @Test func rejectsMalformedAndOversizedAttributesWithoutReadingContent() async throws {
        let root=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("not-a-movie.mp4");try Data([42]).write(to:file)
        let provider=LocalDirectoryProvider(testRoot:root)
        for data in [Data(),Data("not a plist".utf8),Data(repeating:1,count:FinderTagParser.limit+1),Data(repeating:1,count:FinderTagParser.limit+2)] {
            try put(data,on:file)
            #expect(try await provider.tags(at:.init(["not-a-movie.mp4"])) == .invalid)
        }
        #expect(try Data(contentsOf:file)==Data([42]))
    }
    @Test func deniesTraversalAndSymlinksOutsideChosenFolder() async throws {
        let root=try fixture(),outside=try fixture()
        defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:outside)}
        let target=outside.appendingPathComponent("private.txt");try Data([1]).write(to:target)
        try tags(["Outside\n1"],on:target)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:outside)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("file-link"),withDestinationURL:target)
        let provider=LocalDirectoryProvider(testRoot:root)
        for path in [["..",outside.lastPathComponent,"private.txt"],["link","private.txt"],["file-link"]] {
            #expect(try await provider.tags(at:.init(path)) == .failed)
        }
        #expect(try await !provider.hasFinderTagEvidence(at:.init(),names:["../private.txt","file-link","link"],includeDirectory:true))
    }
    @Test func evidenceIsBoundedToOnePageAndMayIncludeFolderItself() async throws {
        let root=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("tagged.txt");try Data().write(to:file);try tags(["Tag"],on:file)
        let provider=LocalDirectoryProvider(testRoot:root)
        let names=Array(repeating:"missing.txt",count:250)+["tagged.txt"]
        #expect(try await !provider.hasFinderTagEvidence(at:.init(),names:names,includeDirectory:false))
        #expect(try await provider.hasFinderTagEvidence(at:.init(),names:["tagged.txt"],includeDirectory:false))
        try tags(["Root"],on:root)
        #expect(try await provider.hasFinderTagEvidence(at:.init(),names:[],includeDirectory:true))
    }
    @Test func cancellationRemainsCancellation() async throws {
        let root=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let provider=LocalDirectoryProvider(testRoot:root)
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            return try await provider.tags(at:.init())
        }
        await #expect(throws:CancellationError.self) {try await task.value}
    }
    @Test func errorsAreNotConvertedToEmptyTags() {
        #expect(LocalFinderTagReader.failure(ENOATTR) == .unavailable)
        #expect(LocalFinderTagReader.failure(ENOTSUP) == .unsupported)
        #expect(LocalFinderTagReader.failure(EACCES) == .denied)
        #expect(LocalFinderTagReader.failure(EPERM) == .denied)
        #expect(LocalFinderTagReader.failure(ERANGE) == .invalid)
        #expect(LocalFinderTagReader.failure(EIO) == .failed)
        #expect(LocalFinderTagReader.failure(ENOENT) == .failed)
    }
}
