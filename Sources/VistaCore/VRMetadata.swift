import Foundation

public enum VRMetadataResult: Equatable, Sendable {
    case recognized(VRFormat)
    case partial(VRFormatDimensions)
    case missing, incomplete, conflicting, unsupported, invalid, unavailable, limitExceeded
    public var format: VRFormat? { if case let .recognized(value) = self { value } else { nil } }
    public var message: String {
        switch self {
        case .recognized: "已依影片格式標記設定"
        case .partial: "已採用已知格式標記，其餘依檔名或預設"
        case .missing: "未找到格式標記，請手動選擇。"
        case .incomplete: "格式標記不完整，請手動選擇。"
        case .conflicting: "格式標記互相衝突，請手動選擇。"
        case .unsupported: "此格式標記尚未支援自動設定，請手動選擇。"
        case .invalid: "格式標記無法安全解析，請手動選擇。"
        case .unavailable: "無法讀取格式標記，請手動選擇。"
        case .limitExceeded: "格式資訊超出讀取上限，請手動選擇。"
        }
    }
}

/// Strict, bounded Spherical Video V2 inspection. Never searches compressed video bytes.
public enum VRMetadataInspector {
    public static let movieLimit = 2_097_152
    public static func inspect(_ file: MediaFile, source: any MediaByteSource) async throws -> VRMetadataResult {
        do {
            let size = try await source.fileSize(for: file)
            var offset: UInt64 = 0, count = 0, movie: Data?, sawFileType = false
            while offset < size {
                try Task.checkCancellation()
                count += 1
                guard count <= 64 else { return .limitExceeded }
                guard size - offset >= 8 else { return .invalid }
                let header = try await read(source, file, offset, 8)
                let type = String(decoding: header[4..<8], as: UTF8.self)
                var length = number(header, 0, 4), headerSize: UInt64 = 8
                if length == 1 {
                    guard size - offset >= 16 else { return .invalid }
                    length = number(try await read(source, file, offset + 8, 8), 0, 8); headerSize = 16
                } else if length == 0 { length = size - offset }
                guard length >= headerSize, length <= size - offset else { return .invalid }
                if type == "ftyp" { sawFileType = true }
                if type == "moof" { return .unsupported }
                if type == "moov" {
                    guard movie == nil else { return .conflicting }
                    guard length - headerSize <= movieLimit else { return .limitExceeded }
                    var bytes = Data(), position = offset + headerSize
                    while position < offset + length {
                        let amount = min(UInt64(65_536), offset + length - position)
                        bytes.append(try await read(source, file, position, amount)); position += amount
                    }
                    movie = bytes
                }
                offset += length
            }
            try Task.checkCancellation()
            guard try await source.fileSize(for: file) == size else { return .invalid }
            guard sawFileType, let movie else { return .unsupported }
            var parser = MovieParser(bytes: Array(movie))
            return try parser.parse()
        } catch is CancellationError { throw CancellationError() }
        catch let failure as MetadataFailure { return failure.result }
        catch { try Task.checkCancellation(); return .unavailable }
    }
    private static func read(_ source: any MediaByteSource, _ file: MediaFile, _ start: UInt64, _ count: UInt64) async throws -> Data {
        try Task.checkCancellation()
        let data = try await source.read(file, range: start..<(start + count))
        try Task.checkCancellation()
        guard data.count == count else { throw MetadataFailure(result: .invalid) }
        return Data(data)
    }
    private static func number(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

private struct MetadataFailure: Error { let result: VRMetadataResult }
private struct MovieParser {
    struct Box { let type: String; let payload: Range<Int> }
    let bytes: [UInt8]
    var count = 0
    private func number(_ offset: Int, _ length: Int = 4) -> UInt64 {
        bytes[offset..<(offset + length)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    mutating func boxes(_ range: Range<Int>) throws -> [Box] {
        var position = range.lowerBound, result: [Box] = []
        while position < range.upperBound {
            count += 1
            guard count <= 4096 else { throw MetadataFailure(result: .limitExceeded) }
            guard range.upperBound - position >= 8 else { throw MetadataFailure(result: .invalid) }
            var length = number(position), header = 8
            let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
            if length == 1 {
                guard range.upperBound - position >= 16 else { throw MetadataFailure(result: .invalid) }
                length = number(position + 8, 8); header = 16
            } else if length == 0 { length = UInt64(range.upperBound - position) }
            guard length >= header, length <= range.upperBound - position else { throw MetadataFailure(result: .invalid) }
            result.append(Box(type: type, payload: (position + header)..<(position + Int(length))))
            position += Int(length)
        }
        return result
    }
    private func one(_ type: String, in boxes: [Box]) throws -> Box {
        let found = boxes.filter { $0.type == type }
        guard found.count <= 1 else { throw MetadataFailure(result: .conflicting) }
        guard let value = found.first else { throw MetadataFailure(result: .incomplete) }
        return value
    }
    private func full(_ box: Box, minimum: Int) throws {
        guard box.payload.count >= minimum else { throw MetadataFailure(result: .invalid) }
        guard number(box.payload.lowerBound) == 0 else { throw MetadataFailure(result: .unsupported) }
    }
    mutating func parse() throws -> VRMetadataResult {
        let root = try boxes(0..<bytes.count)
        guard !root.contains(where: { $0.type == "mvex" }) else { return .unsupported }
        var videos: [[Box]] = []
        for track in root.filter({ $0.type == "trak" }) {
            let children = try boxes(track.payload)
            let media = try boxes(one("mdia", in: children).payload)
            let handler = try one("hdlr", in: media)
            try full(handler, minimum: 12)
            if String(decoding: bytes[(handler.payload.lowerBound + 8)..<(handler.payload.lowerBound + 12)], as: UTF8.self) == "vide" {
                videos.append(children)
            }
        }
        guard videos.count == 1 else { return .unsupported }
        let track = videos[0]
        // V1 XML is not interpreted; never silently ignore a potentially conflicting second scheme.
        let sphericalUUID: [UInt8] = [0xff,0xcc,0x82,0x63,0xf8,0x55,0x4a,0x93,0x88,0x14,0x58,0x7a,0x02,0x52,0x1f,0xdd]
        if track.contains(where: { $0.type == "uuid" && Array(bytes[$0.payload].prefix(16)) == sphericalUUID }) { return .unsupported }
        let tkhd = try one("tkhd", in: track)
        guard tkhd.payload.count >= 4 else { return .invalid }
        let version = bytes[tkhd.payload.lowerBound]
        guard version <= 1 else { return .unsupported }
        let matrix = tkhd.payload.lowerBound + (version == 0 ? 40 : 52)
        guard matrix + 36 <= tkhd.payload.upperBound else { return .invalid }
        let identity: [UInt64] = [65536,0,0,0,65536,0,0,0,1 << 30]
        guard (0..<9).allSatisfy({ number(matrix + $0 * 4) == identity[$0] }) else { return .unsupported }
        let media = try boxes(one("mdia", in: track).payload)
        let information = try boxes(one("minf", in: media).payload)
        let table = try boxes(one("stbl", in: information).payload)
        let descriptor = try one("stsd", in: table)
        try full(descriptor, minimum: 8)
        let entries = try boxes((descriptor.payload.lowerBound + 8)..<descriptor.payload.upperBound)
        guard number(descriptor.payload.lowerBound + 4) == entries.count else { return .invalid }
        guard entries.count == 1, let entry = entries.first,
              ["avc1", "avc3", "hvc1", "hev1", "vp09"].contains(entry.type) else { return .unsupported }
        guard entry.payload.count >= 78 else { return .invalid }
        let extensions = try boxes((entry.payload.lowerBound + 78)..<entry.payload.upperBound)
        let stereo = extensions.filter { $0.type == "st3d" }, spherical = extensions.filter { $0.type == "sv3d" }
        guard !stereo.isEmpty || !spherical.isEmpty else { return .missing }
        guard stereo.count <= 1, spherical.count <= 1 else { return .conflicting }
        var settings = VRSettings()
        if let stereo=stereo.first {
        try full(stereo, minimum: 5)
        switch bytes[stereo.payload.lowerBound + 4] {
        case 0: settings.layout = .mono
        case 1: settings.layout = .overUnder
        case 2: settings.layout = .sideBySide
        case 4: return .unsupported // Reversed eye order is not supported.
        default: return .unsupported
        }
        }
        guard let spherical=spherical.first else {return .partial(.init(layout:settings.layout))}
        let sphericalBoxes = try boxes(spherical.payload)
        let header = try one("svhd", in: sphericalBoxes)
        try full(header, minimum: 5)
        guard bytes[(header.payload.lowerBound + 4)..<header.payload.upperBound].contains(0) else { return .invalid }
        let projection = try boxes(one("proj", in: sphericalBoxes).payload)
        let pose = try one("prhd", in: projection)
        try full(pose, minimum: 16)
        guard (0..<3).allSatisfy({ number(pose.payload.lowerBound + 4 + $0 * 4) == 0 }) else { return .unsupported }
        let mappings = projection.filter { $0.type != "prhd" }
        guard mappings.count <= 1 else { return .conflicting }
        guard let mapping = mappings.first else { return .incomplete }
        guard mapping.type == "equi" else { return .unsupported }
        try full(mapping, minimum: 20)
        let bounds = (0..<4).map { number(mapping.payload.lowerBound + 4 + $0 * 4) }
        if bounds == [0,0,0,0] { settings.projection = .equirectangular360 }
        else if bounds == [0,0,1 << 30,1 << 30] { settings.projection = .equirectangular180 }
        else { return .unsupported }
        if stereo.isEmpty {return .partial(.init(projection:settings.projection))}
        return .recognized(VRFormat(settings))
    }
}


/// Explicit user choices win even if a metadata request finishes later.
public struct VRFormatChoice: Sendable {
    public var manual: VRFormat?
    public var metadata: VRMetadataResult?
    public var manualDimensions:VRFormatDimensions?
    public var filename:String?
    public var resolved:VRResolvedDimensions {
        VRDimensionResolver.resolve(manual:manualDimensions ?? manual.map(VRFormatDimensions.init) ?? .init(),
            metadata:metadata?.dimensions ?? .init(),filename:filename ?? "")
    }
    public var hasManual:Bool {manual != nil || manualDimensions?.isEmpty == false}
    public init(manual: VRFormat? = nil, metadata: VRMetadataResult? = nil) {
        self.manual = manual; self.metadata = metadata
    }
    public var format: VRFormat {
        guard filename != nil else {return manual ?? metadata?.format ?? VRFormat(VRSettings())}
        return resolved.values.completedFormat
    }
    public var confirmed: Bool {filename == nil ? (manual != nil || metadata?.format != nil):(resolved.values.projection != nil && resolved.values.layout != nil)}
}

/// Independent dimensions for the next format-selection UI. Defaults are explicitly 180 degrees and SBS; contradictory filename evidence remains unresolved.
public struct VRFormatDimensions: Codable, Equatable, Sendable {
    public var projection: VRProjection?
    public var layout: VRLayout?
    public var isEmpty:Bool {projection == nil && layout == nil}
    public init(_ format:VRFormat) {projection=format.projection;layout=format.layout}
    public var completedFormat:VRFormat {
        var value=VRSettings();value.projection=projection ?? .equirectangular180
        value.layout=layout ?? .sideBySide
        return VRFormat(value)
    }
    public init(projection:VRProjection?=nil,layout:VRLayout?=nil) {
        self.projection=projection;self.layout=layout
    }
}
public enum VRDimensionOrigin: Equatable, Sendable {case manual,metadata,filename,fallback,unresolved}
public struct VRResolvedDimensions: Equatable, Sendable {
    public let values:VRFormatDimensions
    public let projectionOrigin:VRDimensionOrigin
    public let layoutOrigin:VRDimensionOrigin
}
public struct VRFilenameHints: Equatable, Sendable {
    public var values=VRFormatDimensions()
    public var layoutConflict=false
    public var projectionConflict=false
    public static func parse(_ filename:String)->Self {
        let stem=(filename as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping.lowercased()
        let tokens=Set(stem.split { !$0.isLetter && !$0.isNumber && $0 != "°" }.map(String.init))
        var result=Self()
        let side = !tokens.isDisjoint(with:["sbs","hsbs","左右"])
        let over = !tokens.isDisjoint(with:["ou","tb","hou","htb","上下"])
        let mono = !tokens.isDisjoint(with:["mono","2d","單眼"])
        let layouts:[VRLayout]=[(side,VRLayout.sideBySide),(over,.overUnder),(mono,.mono)].compactMap{$0.0 ? $0.1:nil}
        result.layoutConflict=layouts.count>1
        if layouts.count==1 {result.values.layout=layouts[0]}
        // Bare movie-title numbers are ambiguous. Require explicit VR/degree notation or a separate VR/layout token.
        let context=tokens.contains("vr") || side || over
        let p180 = !tokens.isDisjoint(with:["vr180","180vr","180°"]) || (context && tokens.contains("180"))
        let p360 = !tokens.isDisjoint(with:["vr360","360vr","360°"]) || (context && tokens.contains("360"))
        result.projectionConflict=p180 && p360
        if p180 != p360 {result.values.projection=p180 ? .equirectangular180:.equirectangular360}
        return result
    }
}
public enum VRDimensionResolver {
    public static func resolve(manual:VRFormatDimensions = .init(),metadata:VRFormatDimensions = .init(),filename:String)->VRResolvedDimensions {
        let hint=VRFilenameHints.parse(filename)
        func pick<T>(_ manual:T?,_ metadata:T?,_ hint:T?,fallback:T?)->(T?,VRDimensionOrigin) {
            if let manual {return(manual,.manual)}
            if let metadata {return(metadata,.metadata)}
            if let hint {return(hint,.filename)}
            return(fallback,fallback == nil ? .unresolved:.fallback)
        }
        let projection=pick(manual.projection,metadata.projection,hint.values.projection,fallback:hint.projectionConflict ? nil:.equirectangular180)
        let layout=pick(manual.layout,metadata.layout,hint.values.layout,fallback:hint.layoutConflict ? nil:.sideBySide)
        return VRResolvedDimensions(values:.init(projection:projection.0,layout:layout.0),
                                    projectionOrigin:projection.1,layoutOrigin:layout.1)
    }
}

public extension VRMetadataResult {
    var dimensions:VRFormatDimensions {
        switch self {case .recognized(let format):return .init(format);case .partial(let fields):return fields;default:return .init()}
    }
}
