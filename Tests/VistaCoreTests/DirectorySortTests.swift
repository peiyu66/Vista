import Foundation
import Testing
@testable import VistaCore
struct DirectorySortTests {
    @Test func fixedFractionSizesAndByteOrdering() {
        let locale=Locale(identifier:"en_US_POSIX")
        for (bytes,text) in [(Int64(0),"0.0 B"),(1,"1.0 B"),(1000,"1.0 KB"),(1000000,"1.0 MB"),(1250000000,"1.3 GB"),(999999,"1.0 MB"),(1000000000000,"1.0 TB")] {
            #expect(BrowserSizeText.string(bytes,locale:locale)==text)
        }
        #expect(BrowserSizeText.string(nil)=="—")
        #expect(BrowserSizeText.string(-1)=="—")
        #expect(BrowserSizeText.string(1500,locale:Locale(identifier:"de_DE"))=="1,5 KB")
        let entries=[FileEntry("a",.video,byteSize:1040000),FileEntry("z",.video,byteSize:1010000),FileEntry("GB",.video,byteSize:1000000000)]
        #expect(BrowserSizeText.string(entries[0].byteSize,locale:locale)==BrowserSizeText.string(entries[1].byteSize,locale:locale))
        #expect(DirectorySort(field:.size).sorted(entries).map(\.name)==["z","a","GB"])
        #expect(DirectorySort(field:.size,ascending:false).sorted(entries).map(\.name)==["GB","a","z"])
    }

    @Test func explicitDatesAndCreationOrdering() {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let date=calendar.date(from:DateComponents(year:2026,month:11,day:4,hour:15,minute:5))!
        #expect(BrowserDateText.string(date,timeZone:calendar.timeZone)=="2026/11/4 3:05 PM")
        let midnight=calendar.date(from:DateComponents(year:2026,month:1,day:2,hour:0,minute:0))!
        #expect(BrowserDateText.string(midnight,timeZone:calendar.timeZone)=="2026/1/2 12:00 AM")
        #expect(BrowserDateText.string(nil)=="—")
        let entries=[FileEntry("unknown",.video),FileEntry("b",.video,createdAt:date),FileEntry("a",.video,createdAt:date),FileEntry("old",.video,createdAt:midnight)]
        #expect(DirectorySort(field:.created).sorted(entries).map(\.name)==["old","a","b","unknown"])
        #expect(DirectorySort(field:.created,ascending:false).sorted(entries).map(\.name)==["a","b","old","unknown"])
    }

    @Test func missingValuesFoldersAndTies() {
        let entries=[FileEntry("z",.video),FileEntry("b",.video,modifiedAt:Date(timeIntervalSince1970:2),byteSize:20),FileEntry("a",.video,modifiedAt:Date(timeIntervalSince1970:2),byteSize:10),FileEntry("folder",.directory)]
        for ascending in [true,false] {
            #expect(DirectorySort(field:.modified,ascending:ascending).sorted(entries).map(\.name)==["folder","a","b","z"])
        }
        #expect(DirectorySort(field:.size,ascending:false).sorted(entries).map(\.name)==["folder","b","a","z"])
        #expect(DirectorySort(field:.name,ascending:false).sorted(entries).map(\.name)==["folder","z","b","a"])
        #expect(FileEntry("bad",.video,modifiedAt:Date(timeIntervalSince1970:.infinity),byteSize:-1).modifiedAt == nil)
        #expect(FileEntry("bad",.video,byteSize:-1).byteSize == nil)
    }
    @Test func numericNamesAndStableEqualEntries() {
        let entries=[FileEntry("10",.video,byteSize:1),FileEntry("2",.video),FileEntry("10",.video,byteSize:2)]
        let ordered=DirectorySort().sorted(entries)
        #expect(ordered.map(\.name)==["2","10","10"])
        #expect(ordered[1].byteSize==1)
    }
    @Test func entireDirectorySortedBeforePaging() async throws {
        let provider=DemoDirectoryProvider(),path=DirectoryPath(["大量影片"])
        for field in [DirectorySort.Field.name,.modified,.size] {
            let sort=DirectorySort(field:field,ascending:false)
            let first=try await provider.page(at:path,offset:0,sort:sort)
            let second=try await provider.page(at:path,offset:100,sort:sort)
            #expect(first.entries.first?.name=="影片 5000.mp4")
            #expect(second.entries.first?.name=="影片 4900.mp4")
            #expect(first.nextOffset==100)
        }
    }
}
