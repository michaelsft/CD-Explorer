import SwiftUI
import AppKit
import AVFoundation
import Foundation
import Darwin
import Libmpv
import OpenGL.GL
import UniformTypeIdentifiers

struct CDTrack: Identifiable, Hashable {
    let id: UUID
    let session: Int
    let number: Int
    let startLBA: Int
    let endLBA: Int
    let description: String

    init(id: UUID = UUID(), session: Int, number: Int, startLBA: Int, endLBA: Int, description: String) {
        self.id = id
        self.session = session
        self.number = number
        self.startLBA = startLBA
        self.endLBA = endLBA
        self.description = description
    }

    var isAudio: Bool { description.localizedCaseInsensitiveContains("audio") }
    var sectorCount: Int { max(0, endLBA - startLBA) }
    var kindLabel: String { isAudio ? "Audio" : "Data" }
    var startLabel: String { Self.msf(fromLBA: startLBA) }
    var durationLabel: String {
        let frames = sectorCount
        let seconds = frames / 75
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var sizeLabel: String {
        let bytes = Int64(sectorCount) * Int64(isAudio ? 2352 : 2048)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func msf(fromLBA lba: Int) -> String {
        let absolute = lba + 150
        return String(format: "%02d:%02d.%02d", absolute / (60 * 75), (absolute / 75) % 60, absolute % 75)
    }
}

struct NamedAudioTrack: Identifiable, Hashable {
    let track: CDTrack
    let name: String
    var id: UUID { track.id }
}

struct DiscSnapshot {
    let device: String
    let driveName: String
    let volumeName: String
    let tracks: [CDTrack]
    let hiddenTrack: CDTrack?
    let cdText: CDTextMetadata?
}

struct CDTextMetadata {
    let albumTitle: String?
    let performer: String?
    let trackTitles: [Int: String]

    var isEmpty: Bool {
        albumTitle?.isEmpty != false && performer?.isEmpty != false && trackTitles.isEmpty
    }
}

enum ExtractorError: LocalizedError {
    case cancelled
    case noDisc
    case commandFailed(String)
    case malformedTOC(String)
    case shortRead(Int)
    case unsupportedSectorMode(UInt8)
    case mode2Form2
    case noISO9660
    case invalidISO(String)
    case noVideoFiles
    case unverifiedAudioSector(Int)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled."
        case .noDisc: return "No readable CD was found."
        case .commandFailed(let text): return text
        case .malformedTOC(let text): return "Could not understand the disc table of contents: \(text)"
        case .shortRead(let lba): return "The drive returned an incomplete sector at LBA \(lba)."
        case .unsupportedSectorMode(let mode): return "Unsupported data-sector mode \(mode)."
        case .mode2Form2: return "Mode 2 Form 2 sectors are not an ISO filesystem."
        case .noISO9660: return "No ISO 9660 or Joliet filesystem was found in this data track."
        case .invalidISO(let text): return "The ISO filesystem is invalid: \(text)"
        case .noVideoFiles: return "No standalone video files were recognised. The video may be packed inside an old multimedia projector."
        case .unverifiedAudioSector(let lba):
            return "Audio sector \(lba) could not be read consistently after several attempts. Nothing was silently substituted; clean the disc and try again."
        }
    }
}

private final class OperationCancellation: @unchecked Sendable {
    static let shared = OperationCancellation()
    private let lock = NSLock()
    private var generation = 0
    private var processes: [ObjectIdentifier: Process] = [:]

    func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    func isCurrent(_ ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket == generation
    }

    func check(_ ticket: Int) throws {
        if !isCurrent(ticket) { throw ExtractorError.cancelled }
    }

    func register(_ process: Process) {
        lock.lock(); processes[ObjectIdentifier(process)] = process; lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock(); processes.removeValue(forKey: ObjectIdentifier(process)); lock.unlock()
    }

    func cancel() {
        lock.lock()
        generation += 1
        let running = Array(processes.values)
        lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }
}

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> String {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        OperationCancellation.shared.register(process)
        defer { OperationCancellation.shared.unregister(process) }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw ExtractorError.commandFailed("\((executable as NSString).lastPathComponent) did not answer within \(Int(timeout)) seconds. Cancel any other operation using the optical drive, then try again.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ExtractorError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

    static func runWithProgress(_ executable: String, _ arguments: [String], duration: TimeInterval,
                                timeout: TimeInterval, progress: @escaping (Double) -> Void) throws -> String {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var captured = Data()
        var pending = ""

        func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            var reported: [Double] = []
            lock.lock()
            captured.append(data)
            pending += String(decoding: data, as: UTF8.self)
            let lines = pending.components(separatedBy: .newlines)
            pending = lines.last ?? ""
            for line in lines.dropLast() {
                if line == "progress=end" {
                    reported.append(1)
                } else if line.hasPrefix("out_time_us="),
                          let microseconds = Double(line.dropFirst("out_time_us=".count)), duration > 0 {
                    reported.append(min(0.995, max(0, microseconds / 1_000_000 / duration)))
                }
            }
            lock.unlock()
            for value in reported { progress(value) }
        }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in consume(handle.availableData) }
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        OperationCancellation.shared.register(process)
        defer { OperationCancellation.shared.unregister(process) }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            output.fileHandleForReading.readabilityHandler = nil
            throw ExtractorError.commandFailed("\((executable as NSString).lastPathComponent) did not finish within \(Int(timeout)) seconds.")
        }
        output.fileHandleForReading.readabilityHandler = nil
        consume(output.fileHandleForReading.readDataToEndOfFile())
        lock.lock()
        let text = String(decoding: captured, as: UTF8.self)
        lock.unlock()
        guard process.terminationStatus == 0 else {
            throw ExtractorError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        progress(1)
        return text
    }
}

enum DiscScanner {
    static func scan() throws -> DiscSnapshot {
        let status = try CommandRunner.run("/usr/bin/drutil", ["status"])
        let toc = try CommandRunner.run("/usr/bin/drutil", ["toc"])
        guard let device = firstMatch(#"Name:\s*(/dev/disk\d+)"#, in: status, group: 1) else {
            throw ExtractorError.noDisc
        }
        let vendor = firstMatch(#"(?m)^\s*Vendor\s+Product\s+Rev\s*$\n\s*(.+?)\s*$"#, in: status, group: 1) ?? "Optical Drive"
        let info = (try? CommandRunner.run("/usr/sbin/diskutil", ["info", device])) ?? ""
        let volume = firstMatch(#"(?m)^\s*Volume Name:\s*(.+?)\s*$"#, in: info, group: 1) ?? "Enhanced CD"
        let tracks = try parseTOC(toc)
        let cdTextOutput = (try? CommandRunner.run("/usr/bin/drutil", ["cdtext"])) ?? ""
        let cdText = parseCDText(cdTextOutput)
        let firstAudio = tracks.first(where: \.isAudio)
        let hiddenTrack = firstAudio.flatMap { first -> CDTrack? in
            // A first audio index materially beyond the normal 2-second lead-in is
            // hidden track one audio (HTOA): audio stored before Track 1, reached by rewinding.
            guard first.number == 1, first.startLBA >= 75 else { return nil }
            return CDTrack(session: first.session, number: 0, startLBA: 0,
                           endLBA: first.startLBA, description: "2ch hidden pre-gap audio")
        }
        return DiscSnapshot(device: device, driveName: vendor, volumeName: volume,
                            tracks: tracks, hiddenTrack: hiddenTrack, cdText: cdText)
    }

    private static func parseCDText(_ text: String) -> CDTextMetadata? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var album: String?
        var performer: String?
        var titles: [Int: String] = [:]
        var currentTrack: Int?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numberText = firstMatch(#"(?i)^track\s*(\d+)"#, in: line, group: 1),
               let number = Int(numberText) {
                currentTrack = number
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if key.contains("title") || key.contains("name") {
                if let track = currentTrack { titles[track] = value }
                else if album == nil { album = value }
            } else if (key.contains("performer") || key.contains("artist")), currentTrack == nil {
                performer = value
            }
        }
        let result = CDTextMetadata(albumTitle: album, performer: performer, trackTitles: titles)
        return result.isEmpty ? nil : result
    }

    private static func parseTOC(_ text: String) throws -> [CDTrack] {
        let trackRegex = try NSRegularExpression(
            pattern: #"Session\s+(\d+),\s*Track\s+(\d+):\s+(\d+):(\d+)\.(\d+)\s+(.+)"#
        )
        let leadRegex = try NSRegularExpression(pattern: #"Lead-out:\s+(\d+):(\d+)\.(\d+)"#)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        struct Parsed { let session: Int; let number: Int; let start: Int; let details: String }
        var parsed: [Parsed] = []
        for match in trackRegex.matches(in: text, range: full) {
            let session = Int(ns.substring(with: match.range(at: 1)))!
            let number = Int(ns.substring(with: match.range(at: 2)))!
            let minute = Int(ns.substring(with: match.range(at: 3)))!
            let second = Int(ns.substring(with: match.range(at: 4)))!
            let frame = Int(ns.substring(with: match.range(at: 5)))!
            let details = ns.substring(with: match.range(at: 6)).trimmingCharacters(in: .whitespaces)
            parsed.append(Parsed(session: session, number: number, start: lba(minute, second, frame), details: details))
        }
        guard !parsed.isEmpty else { throw ExtractorError.malformedTOC(text) }

        let leadouts = leadRegex.matches(in: text, range: full).map { match -> Int in
            lba(Int(ns.substring(with: match.range(at: 1)))!,
                Int(ns.substring(with: match.range(at: 2)))!,
                Int(ns.substring(with: match.range(at: 3)))!)
        }
        let sessions = Array(Set(parsed.map(\.session))).sorted()
        var sessionEnds: [Int: Int] = [:]
        for (index, session) in sessions.enumerated() where index < leadouts.count {
            sessionEnds[session] = leadouts[index]
        }

        return parsed.enumerated().map { index, item in
            let nextInSession = parsed.dropFirst(index + 1).first(where: { $0.session == item.session })?.start
            let fallback = parsed.dropFirst(index + 1).first?.start ?? item.start
            let end = nextInSession ?? sessionEnds[item.session] ?? fallback
            return CDTrack(session: item.session, number: item.number, startLBA: item.start,
                           endLBA: end, description: item.details)
        }
    }

    private static func lba(_ minute: Int, _ second: Int, _ frame: Int) -> Int {
        (minute * 60 + second) * 75 + frame - 150
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol ISOBlockReader: AnyObject {
    func dataSector(lba: Int) throws -> Data
    func fileData(extent: Int, size: Int, progress: ((Int) -> Void)?) throws -> Data
}

final class RawCDReader: ISOBlockReader {
    let handle: FileHandle
    let sectorSize: UInt64 = 2352

    init(device: String) throws {
        let rawDevice = device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        var descriptor: Int32 = -1
        var lastErrno: Int32 = ENOENT
        for _ in 0..<150 {
            descriptor = rawDevice.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK) }
            if descriptor >= 0 { break }
            lastErrno = errno
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(lastErrno),
                          userInfo: [NSLocalizedDescriptionKey: "The raw CD device could not be opened."])
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit { try? handle.close() }

    func rawSector(lba: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(lba) * sectorSize)
        guard let data = try handle.read(upToCount: Int(sectorSize)), data.count == Int(sectorSize) else {
            throw ExtractorError.shortRead(lba)
        }
        return data
    }

    func rawSectors(lba: Int, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(lba) * sectorSize)
        let expected = count * Int(sectorSize)
        var data = Data(); data.reserveCapacity(expected)
        // Optical raw devices commonly require each read to be exactly one
        // 2352-byte CD sector. Keep the handle positioned sequentially so a
        // block incurs one seek, but never request an unsupported large read.
        for sectorOffset in 0..<count {
            guard let part = try handle.read(upToCount: Int(sectorSize)),
                  part.count == Int(sectorSize) else {
                throw ExtractorError.shortRead(lba + sectorOffset)
            }
            data.append(part)
        }
        return data
    }

    func dataSector(lba: Int) throws -> Data {
        let raw = try rawSector(lba: lba)
        guard raw.count == 2352 else { throw ExtractorError.shortRead(lba) }
        switch raw[15] {
        case 1:
            return raw.subdata(in: 16..<(16 + 2048))
        case 2:
            if raw[18] & 0x20 != 0 { throw ExtractorError.mode2Form2 }
            return raw.subdata(in: 24..<(24 + 2048))
        default:
            throw ExtractorError.unsupportedSectorMode(raw[15])
        }
    }

    func fileData(extent: Int, size: Int, progress: ((Int) -> Void)? = nil) throws -> Data {
        var result = Data()
        result.reserveCapacity(size)
        var remaining = size
        var lba = extent
        var completed = 0
        while remaining > 0 {
            let sector = try dataSector(lba: lba)
            let count = min(remaining, 2048)
            result.append(sector.prefix(count))
            remaining -= count
            completed += count
            progress?(completed)
            lba += 1
        }
        return result
    }
}

final class DiscImageReader: ISOBlockReader {
    enum Layout {
        case iso2048(baseLBA: Int)
        case raw2352(baseLBA: Int)

        var sectorSize: Int {
            switch self { case .iso2048: return 2048; case .raw2352: return 2352 }
        }
        var baseLBA: Int {
            switch self { case .iso2048(let value), .raw2352(let value): return value }
        }
    }

    let url: URL
    let handle: FileHandle
    let layout: Layout
    let sectorCount: Int

    init(url: URL) throws {
        self.url = url
        self.handle = try FileHandle(forReadingFrom: url)
        let byteCount = Int((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        guard byteCount > 0 else { throw ExtractorError.invalidISO("the image file is empty") }
        guard let detected = try Self.detectLayout(handle: handle, byteCount: byteCount) else {
            throw ExtractorError.invalidISO("no ISO 9660 filesystem was found. CD Explorer supports 2048-byte ISO images and 2352-byte raw CD images")
        }
        layout = detected
        sectorCount = max(0, byteCount / detected.sectorSize - detected.baseLBA)
    }

    deinit { try? handle.close() }

    private static func detectLayout(handle: FileHandle, byteCount: Int) throws -> Layout? {
        for base in [0, 150] where byteCount >= (base + 17) * 2048 {
            try handle.seek(toOffset: UInt64((base + 16) * 2048))
            if let data = try handle.read(upToCount: 2048), isVolumeDescriptor(data) {
                return .iso2048(baseLBA: base)
            }
        }
        for base in [0, 150] where byteCount >= (base + 17) * 2352 {
            try handle.seek(toOffset: UInt64((base + 16) * 2352))
            if let raw = try handle.read(upToCount: 2352), raw.count == 2352,
               let data = try? userData(from: raw, lba: 16), isVolumeDescriptor(data) {
                return .raw2352(baseLBA: base)
            }
        }
        return nil
    }

    private static func isVolumeDescriptor(_ data: Data) -> Bool {
        data.count >= 6 && (data[0] == 1 || data[0] == 2)
            && String(data: data.subdata(in: 1..<6), encoding: .ascii) == "CD001"
    }

    private static func userData(from raw: Data, lba: Int) throws -> Data {
        guard raw.count == 2352 else { throw ExtractorError.shortRead(lba) }
        switch raw[15] {
        case 1: return raw.subdata(in: 16..<(16 + 2048))
        case 2:
            if raw[18] & 0x20 != 0 { throw ExtractorError.mode2Form2 }
            return raw.subdata(in: 24..<(24 + 2048))
        default: throw ExtractorError.unsupportedSectorMode(raw[15])
        }
    }

    func dataSector(lba: Int) throws -> Data {
        let physicalLBA = layout.baseLBA + lba
        try handle.seek(toOffset: UInt64(physicalLBA * layout.sectorSize))
        guard let bytes = try handle.read(upToCount: layout.sectorSize), bytes.count == layout.sectorSize else {
            throw ExtractorError.shortRead(lba)
        }
        switch layout {
        case .iso2048: return bytes
        case .raw2352: return try Self.userData(from: bytes, lba: lba)
        }
    }

    func fileData(extent: Int, size: Int, progress: ((Int) -> Void)? = nil) throws -> Data {
        var result = Data(); result.reserveCapacity(size)
        var remaining = size; var lba = extent; var completed = 0
        while remaining > 0 {
            let sector = try dataSector(lba: lba)
            let count = min(remaining, 2048)
            result.append(sector.prefix(count))
            remaining -= count; completed += count; lba += 1
            progress?(completed)
        }
        return result
    }
}

struct ISOEntry {
    let path: [String]
    let extent: Int
    let size: Int
}

struct CDDataFile: Identifiable, Hashable {
    let trackNumber: Int
    let trackStart: Int
    let volumeName: String
    let path: [String]
    let extent: Int
    let size: Int

    var id: String { "\(trackNumber):\(displayPath)" }
    var displayPath: String { path.joined(separator: "/") }
    var fileExtension: String { (path.last as NSString?)?.pathExtension.lowercased() ?? "" }
    var isVideo: Bool { ["mov", "mpg", "mpeg", "mp4", "m4v", "avi", "wmv", "vob"].contains(fileExtension) }
    var isAudio: Bool { ["wav", "wave", "aif", "aiff", "flac", "mp3", "mp2", "aac", "m4a", "ogg", "wma", "au", "snd", "mid", "midi"].contains(fileExtension) }
    var isImage: Bool { ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "pict", "pct", "webp"].contains(fileExtension) }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

struct VideoProbe {
    let videoCodec: String
    let videoDescription: String
    let audioCodec: String?
    let audioDescription: String?
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Double
    let sourceSAR: Double
    let detectedCrop: VideoCrop?
    let detectedBlackFloor: Int?
    let interlaceAnalysis: VideoInterlaceAnalysis?

    // Kept deliberately conservative: a codec omitted here is not declared
    // unplayable; it simply receives the compatibility choice before export.
    private static let nativeVideoCodecs: Set<String> = [
        "h264", "hevc", "prores", "prores_raw", "mpeg4", "mjpeg", "mjpegb",
        "jpeg2000", "dvvideo", "rawvideo", "qtrle"
    ]
    private static let nativeAudioCodecs: Set<String> = [
        "aac", "alac", "mp3", "ac3", "eac3", "adpcm_ima_qt",
        "pcm_s8", "pcm_u8", "pcm_s16be", "pcm_s16le", "pcm_s24be", "pcm_s24le",
        "pcm_s32be", "pcm_s32le", "pcm_f32be", "pcm_f32le", "pcm_f64be", "pcm_f64le"
    ]

    var needsConversion: Bool {
        !Self.nativeVideoCodecs.contains(videoCodec)
            || (audioCodec.map { !Self.nativeAudioCodecs.contains($0) } ?? false)
    }

    var usesPALFrameRate: Bool {
        abs(frameRate - 25) < 0.6 || abs(frameRate - 50) < 0.6
    }

    var hasNonStandardFrameRate: Bool {
        let standards = [24000.0 / 1001.0, 24, 25, 30000.0 / 1001.0, 30, 50, 60000.0 / 1001.0, 60]
        return frameRate > 0 && !standards.contains { abs(frameRate - $0) < 0.08 }
    }

    var isBelowDVDResolution: Bool {
        width < 720 || height < (usesPALFrameRate ? 576 : 480)
    }

    var estimatedAspectRatio: String {
        guard width > 0, height > 0 else { return "unknown" }
        let ratio = Double(width) * max(0.001, sourceSAR) / Double(height)
        let standards: [(Double, String)] = [
            (1, "1:1"), (4.0 / 3.0, "4:3"), (3.0 / 2.0, "3:2"),
            (16.0 / 9.0, "16:9"), (1.85, "1.85:1"),
            (2.0, "2:1"), (2.35, "2.35:1"), (2.39, "2.39:1")
        ]
        if let closest = standards.min(by: { abs($0.0 - ratio) < abs($1.0 - ratio) }),
           abs(closest.0 - ratio) / closest.0 <= 0.06 {
            return closest.1
        }
        return String(format: "%.2f:1", ratio)
    }

    var needsVideoChoice: Bool {
        needsConversion || isBelowDVDResolution || detectedCrop != nil || detectedBlackFloor != nil
    }

    var codecSummary: String {
        let video = videoDescription.isEmpty ? videoCodec : videoDescription
        guard let audioCodec else { return "Video: \(video)" }
        let audio = (audioDescription?.isEmpty == false ? audioDescription! : audioCodec)
        return "Video: \(video)\nAudio: \(audio)"
    }

    var potentiallyUnsupportedCodecSummary: String {
        var lines: [String] = []
        if !Self.nativeVideoCodecs.contains(videoCodec) {
            lines.append("Video: \(videoDescription.isEmpty ? videoCodec : videoDescription)")
        }
        if let audioCodec, !Self.nativeAudioCodecs.contains(audioCodec) {
            let description = audioDescription?.isEmpty == false ? audioDescription! : audioCodec
            lines.append("Audio: \(description)")
        }
        return lines.joined(separator: "\n")
    }

    var compatibilityWarning: String {
        let videoIsOlder = !Self.nativeVideoCodecs.contains(videoCodec)
        let audioIsOlder = audioCodec.map { !Self.nativeAudioCodecs.contains($0) } ?? false
        if videoIsOlder && audioIsOlder { return "uses video and audio codecs that may not play on your Mac" }
        if videoIsOlder { return "uses a video codec that may not play on your Mac" }
        return "uses an audio codec that may not play on your Mac"
    }
}

struct VideoInterlaceAnalysis {
    let topFieldFirst: Int
    let bottomFieldFirst: Int
    let progressive: Int
    let undetermined: Int

    var interlaced: Int { topFieldFirst + bottomFieldFirst }
    var totalKnown: Int { interlaced + progressive }
    var shouldOfferDeinterlacing: Bool {
        totalKnown > 0 && interlaced >= max(5, Int(Double(totalKnown) * 0.10))
    }
    var isMixed: Bool {
        shouldOfferDeinterlacing && progressive >= max(5, Int(Double(totalKnown) * 0.10))
    }
    var parity: String {
        if isMixed { return "auto" }
        if topFieldFirst > max(2, bottomFieldFirst * 5 / 4) { return "tff" }
        if bottomFieldFirst > max(2, topFieldFirst * 5 / 4) { return "bff" }
        return "auto"
    }
    var summary: String {
        let kind = isMixed ? "Mixed progressive/interlaced material detected" : "Interlaced video detected"
        let order: String
        switch parity {
        case "tff": order = "top field first"
        case "bff": order = "bottom field first"
        default: order = "field order uncertain"
        }
        return "\(kind) - \(order)."
    }
}

struct VideoCrop: Hashable {
    let width: Int
    let height: Int
    let x: Int
    let y: Int
    var filter: String { "crop=\(width):\(height):\(x):\(y)" }
}

enum VideoOutputSize: Hashable {
    case source, dvdPAL, dvdNTSC, hd720, hd1080

    var label: String {
        switch self {
        case .source: return "Original size (no upscale)"
        case .dvdPAL: return "DVD PAL - 720 × 576"
        case .dvdNTSC: return "DVD NTSC - 720 × 480"
        case .hd720: return "HD 720p - 1280 × 720"
        case .hd1080: return "Full HD 1080p - 1920 × 1080"
        }
    }
}

struct VideoExtractionRequest {
    let saveOriginal: Bool
    let outputSizes: [VideoOutputSize]
    let aspectCorrection: VideoAspectCorrection?
    let forceRec709: Bool
    let fitToWidescreen: Bool
    let crop: VideoCrop?
    let colorSettings: VideoColorSettings?
    let targetFrameRate: String?
    let deinterlace: VideoDeinterlaceSettings?
    let clipRange: VideoClipRange?
    let destination: URL?
}

enum VideoAspectCorrection: Equatable {
    case stretchTo16x9
    case squeezeTo4x3
}

struct VideoClipRange: Hashable {
    let startFrame: Int
    let endFrameExclusive: Int
    let sourceFrameRate: Double

    var startSeconds: Double { Double(startFrame) / max(0.001, sourceFrameRate) }
    var endSeconds: Double { Double(endFrameExclusive) / max(0.001, sourceFrameRate) }
    var duration: Double { max(0, endSeconds - startSeconds) }
    var videoFilter: String { "trim=start_frame=\(startFrame):end_frame=\(endFrameExclusive),setpts=PTS-STARTPTS" }
    var audioFilter: String {
        String(format: "atrim=start=%.9f:end=%.9f,asetpts=PTS-STARTPTS", startSeconds, endSeconds)
    }
}

struct VideoDeinterlaceSettings {
    let sendFields: Bool
    let parity: String
    let selective: Bool

    var filter: String {
        "bwdif=mode=\(sendFields ? "send_field" : "send_frame"):parity=\(parity):deint=\(selective ? "interlaced" : "all")"
    }
}

struct VideoColorSettings {
    var brightness: Double
    var contrast: Double
    var blackPoint: Int
    var saturation: Double = 1
}

private final class ModalButtonHandler: NSObject {
    static let adjustBordersResponse = NSApplication.ModalResponse(rawValue: 1001)
    @objc func accept() { NSApp.stopModal(withCode: .OK) }
    @objc func cancel() { NSApp.stopModal(withCode: .cancel) }
    @objc func adjustBorders() { NSApp.stopModal(withCode: Self.adjustBordersResponse) }
}

private final class ClosureAction: NSObject {
    var action: (() -> Void)?
    @objc func run() { action?() }
}

private final class ClosureButton: NSButton {
    var callback: (() -> Void)?
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() {
        callback?()
    }
}

private final class VideoOptionsHandler: NSObject {
    var acceptAction: (() -> Void)?
    var cancelAction: (() -> Void)?
    var adjustAction: (() -> Void)?
    var adjustColourAction: (() -> Void)?
    weak var stretchButton: NSButton?
    weak var squeezeButton: NSButton?
    weak var widescreenButton: NSButton?
    @objc func accept() { acceptAction?() }
    @objc func cancel() { cancelAction?() }
    @objc func openBorderEditor(_ sender: Any?) { adjustAction?() }
    @objc func openColourEditor(_ sender: Any?) { adjustColourAction?() }
    @objc func chooseStretch(_ sender: NSButton) {
        if sender.state == .on {
            squeezeButton?.state = .off
            widescreenButton?.state = .off
            widescreenButton?.isEnabled = false
        } else {
            widescreenButton?.isEnabled = true
        }
    }
    @objc func chooseSqueeze(_ sender: NSButton) {
        if sender.state == .on { stretchButton?.state = .off }
        widescreenButton?.isEnabled = true
    }
    func clearActions() { acceptAction = nil; cancelAction = nil; adjustAction = nil; adjustColourAction = nil }
}

private final class CropOverlayView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var sourcePixelSize = NSSize(width: 1, height: 1) { didSet { needsDisplay = true } }
    var edgeInsets = NSEdgeInsetsZero { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }

        let available = bounds.insetBy(dx: 2, dy: 2)
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        let imageSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let imageRect = NSRect(x: available.midX - imageSize.width / 2,
                               y: available.midY - imageSize.height / 2,
                               width: imageSize.width, height: imageSize.height)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)

        let pixelWidth = max(1, sourcePixelSize.width)
        let pixelHeight = max(1, sourcePixelSize.height)
        let retainedRect = NSRect(
            x: imageRect.minX + imageRect.width * edgeInsets.left / pixelWidth,
            y: imageRect.minY + imageRect.height * edgeInsets.bottom / pixelHeight,
            width: imageRect.width * max(0, pixelWidth - edgeInsets.left - edgeInsets.right) / pixelWidth,
            height: imageRect.height * max(0, pixelHeight - edgeInsets.top - edgeInsets.bottom) / pixelHeight)

        let mask = NSBezierPath(rect: imageRect)
        mask.append(NSBezierPath(rect: retainedRect))
        mask.windingRule = .evenOdd
        NSColor.gray.withAlphaComponent(0.62).setFill()
        mask.fill()

        NSColor.systemYellow.setStroke()
        let outline = NSBezierPath(rect: retainedRect.insetBy(dx: 0.375, dy: 0.375))
        outline.lineWidth = 0.75
        outline.stroke()
    }
}

private final class BorderEditorController: NSObject, NSTextFieldDelegate {
    let source: URL
    let probe: VideoProbe
    let left = NSTextField(), right = NSTextField(), top = NSTextField(), bottom = NSTextField()
    let leftStepper = NSStepper(), rightStepper = NSStepper(), topStepper = NSStepper(), bottomStepper = NSStepper()
    let previewView = CropOverlayView()
    let previousFrame = NSButton(title: "◀", target: nil, action: nil)
    let nextFrame = NSButton(title: "▶", target: nil, action: nil)
    let frameLabel = NSTextField(labelWithString: "Frame 1 of 10")
    let status = NSTextField(labelWithString: "Loading preview frames…")
    private var frames: [NSImage?]
    private var currentFrameIndex = 0
    private let sampleCount: Int

    init(source: URL, probe: VideoProbe, initial: VideoCrop?) {
        self.source = source; self.probe = probe
        self.sampleCount = probe.duration > 0 ? min(10, max(1, Int(ceil(probe.duration)))) : 1
        self.frames = Array(repeating: nil, count: sampleCount)
        super.init()
        let crop = initial ?? VideoCrop(width: probe.width, height: probe.height, x: 0, y: 0)
        left.integerValue = crop.x
        right.integerValue = max(0, probe.width - crop.width - crop.x)
        top.integerValue = crop.y
        bottom.integerValue = max(0, probe.height - crop.height - crop.y)
        for (field, stepper, maximum) in [(left, leftStepper, probe.width - 2),
                                           (right, rightStepper, probe.width - 2),
                                           (top, topStepper, probe.height - 2),
                                           (bottom, bottomStepper, probe.height - 2)] {
            field.delegate = self
            stepper.minValue = 0
            stepper.maxValue = Double(maximum)
            stepper.increment = 1
            stepper.integerValue = field.integerValue
            stepper.target = self
            stepper.action = #selector(stepperChanged(_:))
        }
        previewView.sourcePixelSize = NSSize(width: probe.width, height: probe.height)
        previousFrame.target = self; previousFrame.action = #selector(showPreviousFrame)
        nextFrame.target = self; nextFrame.action = #selector(showNextFrame)
        previousFrame.toolTip = "Previous frame"
        nextFrame.toolTip = "Next frame"
        updateStepperLimits()
        updateOverlay()
        updateFrameControls()
    }

    var crop: VideoCrop? {
        let l = max(0, min(probe.width - right.integerValue - 2, left.integerValue))
        let r = max(0, min(probe.width - l - 2, right.integerValue))
        let t = max(0, min(probe.height - bottom.integerValue - 2, top.integerValue))
        let b = max(0, min(probe.height - t - 2, bottom.integerValue))
        if l + r + t + b == 0 { return nil }
        return VideoCrop(width: probe.width - l - r, height: probe.height - t - b, x: l, y: t)
    }

    @objc func updatePreview() {
        updateOverlay()
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        if sender === leftStepper { left.integerValue = sender.integerValue }
        else if sender === rightStepper { right.integerValue = sender.integerValue }
        else if sender === topStepper { top.integerValue = sender.integerValue }
        else if sender === bottomStepper { bottom.integerValue = sender.integerValue }
        validate(changedField: field(for: sender))
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        validate(changedField: field)
    }

    func loadInitialPreviews() {
        status.stringValue = "Loading preview frames…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for index in 0..<self.sampleCount {
                let fraction = Double(index + 1) / Double(self.sampleCount + 1)
                let image = VideoCompatibility.previewImage(source: self.source, probe: self.probe,
                                                            crop: nil, colorSettings: nil,
                                                            atFraction: fraction)
                DispatchQueue.main.async {
                    self.frames[index] = image
                    if index == self.currentFrameIndex { self.previewView.image = image }
                    let loaded = self.frames.compactMap { $0 }.count
                    if loaded == self.sampleCount { self.status.stringValue = "" }
                    else if image == nil { self.status.stringValue = "Some preview frames could not be loaded." }
                    else { self.status.stringValue = "Loaded \(loaded) of \(self.sampleCount) preview frames…" }
                }
            }
        }
    }

    @objc private func showPreviousFrame() {
        currentFrameIndex = (currentFrameIndex - 1 + sampleCount) % sampleCount
        showCurrentFrame()
    }

    @objc private func showNextFrame() {
        currentFrameIndex = (currentFrameIndex + 1) % sampleCount
        showCurrentFrame()
    }

    private func showCurrentFrame() {
        previewView.image = frames[currentFrameIndex]
        updateFrameControls()
        if frames[currentFrameIndex] == nil { status.stringValue = "Loading this preview frame…" }
    }

    private func updateFrameControls() {
        frameLabel.stringValue = "Frame \(currentFrameIndex + 1) of \(sampleCount)"
        previousFrame.isEnabled = sampleCount > 1
        nextFrame.isEnabled = sampleCount > 1
    }

    private func field(for stepper: NSStepper) -> NSTextField {
        if stepper === leftStepper { return left }
        if stepper === rightStepper { return right }
        if stepper === topStepper { return top }
        return bottom
    }

    private func validate(changedField field: NSTextField) {
        let maximum: Int
        if field === left { maximum = probe.width - right.integerValue - 2 }
        else if field === right { maximum = probe.width - left.integerValue - 2 }
        else if field === top { maximum = probe.height - bottom.integerValue - 2 }
        else { maximum = probe.height - top.integerValue - 2 }
        field.integerValue = max(0, min(maximum, field.integerValue))
        syncSteppers()
        updateStepperLimits()
        updateOverlay()
    }

    private func syncSteppers() {
        leftStepper.integerValue = left.integerValue
        rightStepper.integerValue = right.integerValue
        topStepper.integerValue = top.integerValue
        bottomStepper.integerValue = bottom.integerValue
    }

    private func updateStepperLimits() {
        leftStepper.maxValue = Double(max(0, probe.width - right.integerValue - 2))
        rightStepper.maxValue = Double(max(0, probe.width - left.integerValue - 2))
        topStepper.maxValue = Double(max(0, probe.height - bottom.integerValue - 2))
        bottomStepper.maxValue = Double(max(0, probe.height - top.integerValue - 2))
    }

    private func updateOverlay() {
        previewView.edgeInsets = NSEdgeInsets(top: CGFloat(top.integerValue),
                                              left: CGFloat(left.integerValue),
                                              bottom: CGFloat(bottom.integerValue),
                                              right: CGFloat(right.integerValue))
    }

    @objc func resetInsets() {
        [left, right, top, bottom].forEach { $0.integerValue = 0 }
        [leftStepper, rightStepper, topStepper, bottomStepper].forEach { $0.integerValue = 0 }
        updateStepperLimits()
        updateOverlay()
    }
}

private final class BorderEditorSheetHandler: NSObject {
    let parent: NSWindow
    let panel: NSPanel
    let controller: BorderEditorController
    var completion: ((Bool, VideoCrop?) -> Void)?

    init(parent: NSWindow, panel: NSPanel, controller: BorderEditorController) {
        self.parent = parent; self.panel = panel; self.controller = controller
    }

    @objc func apply() { finish(true) }
    @objc func cancel() { finish(false) }

    private func finish(_ applied: Bool) {
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        let callback = completion
        completion = nil
        callback?(applied, controller.crop)
    }
}

private final class ColorEditorController: NSObject {
    let source: URL
    let probe: VideoProbe
    let brightness = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    let contrast = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    let saturation = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    let blackPoint = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    let brightnessValue = NSTextField(labelWithString: "0.00")
    let contrastValue = NSTextField(labelWithString: "0.00")
    let saturationValue = NSTextField(labelWithString: "0.00")
    let blackPointValue = NSTextField(labelWithString: "0.00")
    let imageViews = (0..<4).map { _ in NSImageView() }
    let status = NSTextField(labelWithString: "Loading previews…")
    private var generation = 0

    init(source: URL, probe: VideoProbe, initial: VideoColorSettings?) {
        self.source = source; self.probe = probe
        super.init()
        let guess = initial ?? VideoColorSettings(brightness: 0,
            contrast: probe.detectedBlackFloor == nil ? 1 : 1.05,
            blackPoint: probe.detectedBlackFloor ?? 16)
        brightness.doubleValue = guess.brightness / 0.25
        contrast.doubleValue = guess.contrast >= 1 ? (guess.contrast - 1) / 0.75 : (guess.contrast - 1) / 0.5
        saturation.doubleValue = guess.saturation - 1
        blackPoint.doubleValue = guess.blackPoint >= 16 ? Double(guess.blackPoint - 16) / 48 : Double(guess.blackPoint - 16) / 16
        [brightness, contrast, saturation, blackPoint].forEach { slider in
            slider.target = self; slider.action = #selector(changed)
            slider.isContinuous = true
        }
        updateLabels()
    }

    var settings: VideoColorSettings {
        let normalizedContrast = contrast.doubleValue
        let normalizedBlackPoint = blackPoint.doubleValue
        return VideoColorSettings(brightness: brightness.doubleValue * 0.25,
                           contrast: normalizedContrast >= 0 ? 1 + normalizedContrast * 0.75 : 1 + normalizedContrast * 0.5,
                           blackPoint: Int((normalizedBlackPoint >= 0 ? 16 + normalizedBlackPoint * 48 : 16 + normalizedBlackPoint * 16).rounded()),
                           saturation: 1 + saturation.doubleValue)
    }

    @objc func changed(_ sender: NSSlider) {
        sender.doubleValue = (sender.doubleValue * 100).rounded() / 100
        updateLabels()
        refresh()
    }

    private func updateLabels() {
        brightnessValue.stringValue = normalizedLabel(brightness.doubleValue)
        contrastValue.stringValue = normalizedLabel(contrast.doubleValue)
        saturationValue.stringValue = normalizedLabel(saturation.doubleValue)
        blackPointValue.stringValue = normalizedLabel(blackPoint.doubleValue)
    }

    private func normalizedLabel(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return abs(rounded) < 0.005 ? "0.00" : String(format: "%+.2f", rounded)
    }

    func refresh() {
        generation += 1
        let requestedGeneration = generation
        let selected = settings
        status.stringValue = "Updating previews…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fractions = [0.15, 0.4, 0.65, 0.9]
            let images = fractions.map {
                VideoCompatibility.previewImage(source: self.source, probe: self.probe, crop: nil,
                                                colorSettings: selected, atFraction: $0)
            }
            DispatchQueue.main.async {
                guard requestedGeneration == self.generation else { return }
                for (view, image) in zip(self.imageViews, images) { view.image = image }
                self.status.stringValue = images.contains(where: { $0 == nil }) ? "One or more previews could not be loaded." : ""
            }
        }
    }
}

private final class ColorEditorSheetHandler: NSObject {
    let parent: NSWindow, panel: NSPanel, controller: ColorEditorController
    var completion: ((Bool, VideoColorSettings) -> Void)?
    init(parent: NSWindow, panel: NSPanel, controller: ColorEditorController) {
        self.parent = parent; self.panel = panel; self.controller = controller
    }
    @objc func apply() { finish(true) }
    @objc func cancel() { finish(false) }
    private func finish(_ applied: Bool) {
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        let callback = completion; completion = nil
        callback?(applied, controller.settings)
    }
}

private final class ClipTimelineView: NSControl {
    let totalFrames: Int
    var currentFrame = 0 { didSet { needsDisplay = true } }
    var inFrame = 0 { didSet { needsDisplay = true } }
    var outFrame: Int { didSet { needsDisplay = true } }
    var onFrameChange: ((Int, Bool) -> Void)?

    init(totalFrames: Int) {
        self.totalFrames = max(1, totalFrames)
        self.outFrame = max(0, totalFrames - 1)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let horizontalInset: CGFloat = 8
        let track = NSRect(x: horizontalInset, y: bounds.midY - 3,
                           width: max(1, bounds.width - horizontalInset * 2), height: 6)
        let fullPath = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        NSColor.quaternaryLabelColor.setFill(); fullPath.fill()

        func x(_ frame: Int) -> CGFloat {
            guard totalFrames > 1 else { return track.minX }
            return track.minX + CGFloat(frame) / CGFloat(totalFrames - 1) * track.width
        }
        let selectedLeft = x(inFrame)
        let selectedRight = x(outFrame)
        let selected = NSRect(x: selectedLeft, y: track.minY,
                              width: max(2, selectedRight - selectedLeft), height: track.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: selected, xRadius: 3, yRadius: 3).fill()

        let knobCentre = NSPoint(x: x(currentFrame), y: bounds.midY)
        let knob = NSRect(x: knobCentre.x - 8, y: knobCentre.y - 8, width: 16, height: 16)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor.separatorColor.setStroke()
        let outline = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5)); outline.lineWidth = 1; outline.stroke()
    }

    override func mouseDown(with event: NSEvent) { update(event, final: false) }
    override func mouseDragged(with event: NSEvent) { update(event, final: false) }
    override func mouseUp(with event: NSEvent) { update(event, final: true) }

    private func update(_ event: NSEvent, final: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let usable = max(1, bounds.width - 16)
        let fraction = max(0, min(1, (point.x - 8) / usable))
        let frame = Int((fraction * CGFloat(max(0, totalFrames - 1))).rounded())
        currentFrame = frame
        onFrameChange?(frame, final)
    }
}

private func mpvOpenGLGetProcAddress(_ context: UnsafeMutableRawPointer?,
                                     _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name,
          let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString),
          let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
    else { return nil }
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}

private func mpvRenderUpdate(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let view = Unmanaged<MpvOpenGLView>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { view.needsDisplay = true }
}

private final class MpvOpenGLView: NSOpenGLView {
    private var mpvRenderContext: OpaquePointer?

    init() {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            0
        ]
        super.init(frame: .zero, pixelFormat: NSOpenGLPixelFormat(attributes: attributes))!
        wantsBestResolutionOpenGLSurface = true
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
    }

    required init?(coder: NSCoder) { nil }

    func createRenderer(for handle: OpaquePointer) -> String? {
        openGLContext?.makeCurrentContext()
        var apiName = Array("opengl".utf8CString)
        var initParameters = mpv_opengl_init_params(get_proc_address: mpvOpenGLGetProcAddress,
                                                    get_proc_address_ctx: nil)
        var created: OpaquePointer?
        let result = apiName.withUnsafeMutableBufferPointer { apiBuffer in
            withUnsafeMutablePointer(to: &initParameters) { initPointer in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                     data: UnsafeMutableRawPointer(apiBuffer.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                                     data: UnsafeMutableRawPointer(initPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                return mpv_render_context_create(&created, handle, &parameters)
            }
        }
        guard result >= 0, let created else {
            return "libmpv could not initialise its video renderer."
        }
        mpvRenderContext = created
        mpv_render_context_set_update_callback(created, mpvRenderUpdate,
                                               Unmanaged.passUnretained(self).toOpaque())
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let mpvRenderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            openGLContext?.flushBuffer()
            return
        }
        openGLContext?.makeCurrentContext()
        let backing = convertToBacking(bounds).size
        var framebuffer = mpv_opengl_fbo(fbo: 0, w: Int32(max(1, backing.width)),
                                         h: Int32(max(1, backing.height)), internal_format: 0)
        var flip: Int32 = 1
        withUnsafeMutablePointer(to: &framebuffer) { framebufferPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO,
                                     data: UnsafeMutableRawPointer(framebufferPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y,
                                     data: UnsafeMutableRawPointer(flipPointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(mpvRenderContext, &parameters)
            }
        }
        openGLContext?.flushBuffer()
    }

    func tearDown() {
        guard let mpvRenderContext else { return }
        openGLContext?.makeCurrentContext()
        mpv_render_context_set_update_callback(mpvRenderContext, nil, nil)
        mpv_render_context_free(mpvRenderContext)
        self.mpvRenderContext = nil
    }
}

private final class ClipPlaybackView: NSView {
    private let videoView = MpvOpenGLView()
    private let stillImage = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        stillImage.imageScaling = .scaleProportionallyUpOrDown
        stillImage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stillImage)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stillImage.leadingAnchor.constraint(equalTo: leadingAnchor),
            stillImage.trailingAnchor.constraint(equalTo: trailingAnchor),
            stillImage.topAnchor.constraint(equalTo: topAnchor),
            stillImage.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func createRenderer(for handle: OpaquePointer) -> String? { videoView.createRenderer(for: handle) }
    func tearDown() { videoView.tearDown() }

    func showStill(_ image: NSImage?) {
        stillImage.image = image
        stillImage.isHidden = false
    }

    func showPlayer() {
        stillImage.isHidden = true
    }

    func showCurrentStill() {
        stillImage.isHidden = false
    }
}

private final class MpvClipPlayer {
    private var handle: OpaquePointer?
    private weak var preview: ClipPlaybackView?
    private var pollTimer: Timer?
    private(set) var isPlaying = false
    var onTimeChange: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?

    init(source: URL, preview: ClipPlaybackView) throws {
        guard let created = mpv_create() else { throw PlayerError("libmpv could not be started.") }
        handle = created
        self.preview = preview
        mpv_set_option_string(created, "config", "no")
        mpv_set_option_string(created, "terminal", "no")
        mpv_set_option_string(created, "keep-open", "yes")
        mpv_set_option_string(created, "pause", "yes")
        mpv_set_option_string(created, "hwdec", "auto-safe")
        // Without this explicit video output, mpv's macOS backend creates its own
        // player window instead of sending frames to our render context.
        mpv_set_option_string(created, "vo", "libmpv")
        guard mpv_initialize(created) >= 0 else {
            mpv_terminate_destroy(created); handle = nil
            throw PlayerError("libmpv could not be initialised.")
        }
        if let message = preview.createRenderer(for: created) {
            mpv_terminate_destroy(created); handle = nil
            throw PlayerError(message)
        }
        let loadResult = command(["loadfile", source.path, "replace"])
        guard loadResult >= 0 else {
            stop()
            throw PlayerError(errorText(loadResult))
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    struct PlayerError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    func play(from seconds: Double) {
        seek(to: seconds)
        setFlag("pause", false)
        isPlaying = true
    }

    func pause() {
        setFlag("pause", true)
        isPlaying = false
    }

    func seek(to seconds: Double) {
        _ = command(["seek", String(format: "%.9f", max(0, seconds)), "absolute+exact"])
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        preview?.tearDown()
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
    }

    private func poll() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                onReady?()
            case MPV_EVENT_END_FILE:
                let end = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if let end, end.error < 0 { onError?(errorText(end.error)) }
                else { isPlaying = false; onEnd?() }
            default:
                break
            }
        }
        guard isPlaying else { return }
        var seconds = 0.0
        if mpv_get_property(handle, "time-pos", MPV_FORMAT_DOUBLE, &seconds) >= 0 {
            onTimeChange?(seconds)
        }
    }

    private func setFlag(_ name: String, _ enabled: Bool) {
        guard let handle else { return }
        var flag: Int32 = enabled ? 1 : 0
        _ = mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
    }

    @discardableResult private func command(_ arguments: [String]) -> Int32 {
        guard let handle else { return Int32(MPV_ERROR_UNINITIALIZED.rawValue) }
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = strings.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        pointers.append(nil)
        return mpv_command(handle, &pointers)
    }

    private func errorText(_ code: Int32) -> String {
        guard let text = mpv_error_string(code) else { return "libmpv could not open this video." }
        return "libmpv: " + String(cString: text)
    }

    deinit { stop() }
}

private final class ClipEditorController: NSObject, NSTextFieldDelegate {
    let source: URL
    let probe: VideoProbe
    let preview = ClipPlaybackView()
    let timeline: ClipTimelineView
    let frameField = NSTextField()
    let frameStepper = NSStepper()
    let playPause = NSButton(title: "▶", target: nil, action: nil)
    let previous = NSButton(title: "◀", target: nil, action: nil)
    let next = NSButton(title: "▶", target: nil, action: nil)
    let frameLabel = NSTextField(labelWithString: "")
    let inLabel = NSTextField(labelWithString: "")
    let outLabel = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    let totalFrames: Int
    private(set) var inFrame: Int
    private(set) var outFrame: Int
    private var currentFrameIndex: Int
    private var generation = 0
    private var player: MpvClipPlayer?
    private var isPlaying = false

    init(source: URL, probe: VideoProbe, initial: VideoClipRange?) {
        self.source = source
        self.probe = probe
        let rate = max(0.001, probe.frameRate)
        self.totalFrames = max(1, Int((probe.duration * rate).rounded()))
        self.inFrame = max(0, min((initial?.startFrame ?? 0), totalFrames - 1))
        self.outFrame = max(self.inFrame, min((initial.map { $0.endFrameExclusive - 1 } ?? totalFrames - 1), totalFrames - 1))
        self.currentFrameIndex = self.inFrame
        self.timeline = ClipTimelineView(totalFrames: totalFrames)
        super.init()
        do {
            let player = try MpvClipPlayer(source: source, preview: preview)
            self.player = player
            player.onTimeChange = { [weak self] seconds in self?.playbackAdvanced(to: seconds) }
            player.onEnd = { [weak self] in self?.playbackEnded() }
            player.onReady = { [weak self] in self?.preview.showPlayer() }
            player.onError = { [weak self] message in self?.playbackFailed(message) }
        } catch {
            status.stringValue = error.localizedDescription
        }
        timeline.currentFrame = currentFrameIndex; timeline.inFrame = inFrame; timeline.outFrame = outFrame
        timeline.onFrameChange = { [weak self] frame, final in
            guard let self else { return }
            if final { self.pausePlayback() }
            self.setCurrent(frame, loadImage: final)
        }
        frameField.stringValue = String(inFrame + 1)
        frameField.alignment = .right
        frameField.delegate = self
        frameStepper.minValue = 1; frameStepper.maxValue = Double(totalFrames); frameStepper.increment = 1
        frameStepper.integerValue = inFrame + 1; frameStepper.target = self; frameStepper.action = #selector(stepperChanged)
        previous.target = self; previous.action = #selector(previousFrame)
        next.target = self; next.action = #selector(nextFrame)
        playPause.target = self; playPause.action = #selector(togglePlayback)
        playPause.toolTip = "Play or pause"
        updatePlayPauseAppearance()
        updateLabels()
    }

    deinit { stopPlayback() }

    var currentFrame: Int { currentFrameIndex }
    var clipRange: VideoClipRange? {
        if inFrame == 0 && outFrame == totalFrames - 1 { return nil }
        return VideoClipRange(startFrame: inFrame, endFrameExclusive: outFrame + 1,
                              sourceFrameRate: max(0.001, probe.frameRate))
    }

    @objc private func stepperChanged() { pausePlayback(); setCurrent(frameStepper.integerValue - 1) }
    @objc private func previousFrame() { pausePlayback(); setCurrent(currentFrame - 1) }
    @objc private func nextFrame() { pausePlayback(); setCurrent(currentFrame + 1) }
    @objc func jumpToInPoint() { pausePlayback(); setCurrent(inFrame) }
    @objc func jumpToOutPoint() { pausePlayback(); setCurrent(outFrame) }
    @objc private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            isPlaying = true
            updatePlayPauseAppearance()
            preview.showPlayer()
            player?.play(from: seconds(for: currentFrame))
        }
    }
    @objc func setInPoint() {
        commitFrameField()
        inFrame = min(currentFrame, outFrame)
        updateLabels()
    }
    @objc func setOutPoint() {
        commitFrameField()
        outFrame = max(currentFrame, inFrame)
        updateLabels()
    }
    @objc func resetRange() {
        pausePlayback()
        inFrame = 0; outFrame = totalFrames - 1
        setCurrent(0)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        commitFrameField()
    }

    private func commitFrameField() {
        let ungrouped = frameField.stringValue.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        setCurrent((Int(ungrouped) ?? currentFrame + 1) - 1)
    }

    private func setCurrent(_ requested: Int, loadImage: Bool = true) {
        let value = max(0, min(totalFrames - 1, requested))
        currentFrameIndex = value
        frameField.stringValue = String(value + 1)
        frameStepper.integerValue = value + 1
        timeline.currentFrame = value
        updateLabels()
        if loadImage {
            seekPlayer(to: value)
            loadPreview()
        }
    }

    private func seekPlayer(to frame: Int) {
        player?.seek(to: seconds(for: frame))
    }

    private func seconds(for frame: Int) -> Double {
        Double(frame) / max(0.001, probe.frameRate)
    }

    private func playbackAdvanced(to seconds: Double) {
        guard isPlaying, seconds.isFinite else { return }
        let frame = min(totalFrames - 1, max(0, Int((seconds * probe.frameRate).rounded(.down))))
        setCurrent(frame, loadImage: false)
    }

    private func playbackEnded() {
        isPlaying = false
        updatePlayPauseAppearance()
        setCurrent(totalFrames - 1, loadImage: false)
    }

    private func playbackFailed(_ message: String) {
        player?.pause()
        isPlaying = false
        updatePlayPauseAppearance()
        preview.showCurrentStill()
        status.stringValue = message
    }

    private func updatePlayPauseAppearance() {
        playPause.title = isPlaying ? "❚❚" : "▶"
        playPause.bezelColor = isPlaying ? .systemOrange : .systemGreen
        playPause.contentTintColor = .white
    }

    func pausePlayback() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
        updatePlayPauseAppearance()
    }

    func stopPlayback() {
        player?.stop()
        player = nil
    }

    private func timestamp(_ frame: Int) -> String {
        let seconds = Double(frame) / max(0.001, probe.frameRate)
        let whole = Int(seconds)
        return String(format: "%02d:%02d:%02d.%03d", whole / 3600, (whole / 60) % 60,
                      whole % 60, Int((seconds - Double(whole)) * 1000))
    }

    private func updateLabels() {
        frameLabel.stringValue = "Frame \(currentFrame + 1) of \(totalFrames)  •  \(timestamp(currentFrame))"
        inLabel.stringValue = "In: frame \(inFrame + 1)  •  \(timestamp(inFrame))"
        outLabel.stringValue = "Out: frame \(outFrame + 1)  •  \(timestamp(outFrame))"
        timeline.inFrame = inFrame; timeline.outFrame = outFrame; timeline.currentFrame = currentFrame
        previous.isEnabled = currentFrame > 0
        next.isEnabled = currentFrame < totalFrames - 1
    }

    func loadPreview() {
        generation += 1
        let requestedGeneration = generation
        let frame = currentFrame
        status.stringValue = "Loading frame \(frame + 1)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let image = VideoCompatibility.previewFrame(source: self.source, frame: frame)
            DispatchQueue.main.async {
                guard requestedGeneration == self.generation else { return }
                if !self.isPlaying { self.preview.showStill(image) }
                self.status.stringValue = image == nil ? "This frame could not be previewed." : ""
            }
        }
    }
}

private final class ClipEditorSheetHandler: NSObject {
    let parent: NSWindow, panel: NSPanel, controller: ClipEditorController
    var completion: ((Bool, VideoClipRange?) -> Void)?
    init(parent: NSWindow, panel: NSPanel, controller: ClipEditorController) {
        self.parent = parent; self.panel = panel; self.controller = controller
    }
    @objc func apply() { finish(true) }
    @objc func cancel() { finish(false) }
    private func finish(_ applied: Bool) {
        controller.stopPlayback()
        parent.removeChildWindow(panel); panel.orderOut(nil)
        let callback = completion; completion = nil
        callback?(applied, controller.clipRange)
    }
}

enum VideoCompatibility {
    private static var borderEditors: [BorderEditorSheetHandler] = []
    private static var colorEditors: [ColorEditorSheetHandler] = []
    private static var clipEditors: [ClipEditorSheetHandler] = []
    private static var videoOptionHandlers: [VideoOptionsHandler] = []
    private struct ProbeResponse: Decodable {
        struct Stream: Decodable {
            let codec_name: String?
            let codec_long_name: String?
            let codec_type: String?
            let width: Int?
            let height: Int?
            let avg_frame_rate: String?
            let sample_aspect_ratio: String?
        }
        struct Format: Decodable { let duration: String? }
        let streams: [Stream]
        let format: Format?
    }

    static func inspect(_ file: URL) throws -> VideoProbe {
        guard let ffprobe = BundledMediaTools.ffprobeExecutable else {
            throw ExtractorError.commandFailed("FFprobe is required to check whether video files are compatible with current macOS.")
        }
        let output = try CommandRunner.run(ffprobe,
            ["-v", "error", "-print_format", "json", "-show_entries",
             "format=duration:stream=codec_type,codec_name,codec_long_name,width,height,avg_frame_rate,sample_aspect_ratio", file.path], timeout: 120)
        guard let data = output.data(using: .utf8) else {
            throw ExtractorError.commandFailed("FFprobe returned unreadable codec information.")
        }
        let result = try JSONDecoder().decode(ProbeResponse.self, from: data)
        guard let video = result.streams.first(where: { $0.codec_type == "video" }),
              let videoCodec = video.codec_name else {
            throw ExtractorError.commandFailed("No video stream was found in \(file.lastPathComponent).")
        }
        let audio = result.streams.first(where: { $0.codec_type == "audio" })
        let rateParts = (video.avg_frame_rate ?? "0/1").split(separator: "/").compactMap { Double($0) }
        let frameRate = rateParts.count == 2 && rateParts[1] != 0 ? rateParts[0] / rateParts[1] : 0
        let sarParts = (video.sample_aspect_ratio ?? "1:1").split(separator: ":").compactMap { Double($0) }
        let sourceSAR = sarParts.count == 2 && sarParts[1] != 0 ? sarParts[0] / sarParts[1] : 1
        return VideoProbe(videoCodec: videoCodec,
                          videoDescription: video.codec_long_name ?? videoCodec,
                          audioCodec: audio?.codec_name,
                          audioDescription: audio?.codec_long_name,
                          duration: Double(result.format?.duration ?? "") ?? 0,
                          width: video.width ?? 0,
                          height: video.height ?? 0,
                          frameRate: frameRate,
                          sourceSAR: sourceSAR,
                          detectedCrop: nil,
                          detectedBlackFloor: nil,
                          interlaceAnalysis: nil)
    }

    static func detectingEmbeddedLetterbox(in file: URL, probe: VideoProbe) -> VideoProbe {
        guard probe.width > 0, probe.height > 0,
              let ffmpeg = BundledMediaTools.ffmpegExecutable else { return probe }
        var candidates: [VideoCrop] = []
        for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let start = max(0, probe.duration * fraction - 0.75)
            guard let output = try? CommandRunner.run(ffmpeg,
                ["-hide_banner", "-loglevel", "info", "-ss", String(format: "%.3f", start),
                 "-i", file.path, "-t", "1.5", "-an", "-vf", "cropdetect=limit=40:round=2:reset=0",
                 "-f", "null", "-"], timeout: 45) else { continue }
            let pattern = #"crop=(\d+):(\d+):(\d+):(\d+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
                  let wRange = Range(match.range(at: 1), in: output),
                  let hRange = Range(match.range(at: 2), in: output),
                  let xRange = Range(match.range(at: 3), in: output),
                  let yRange = Range(match.range(at: 4), in: output),
                  let width = Int(output[wRange]), let height = Int(output[hRange]),
                  let x = Int(output[xRange]), let y = Int(output[yRange]) else { continue }
            let crop = VideoCrop(width: width, height: height, x: x, y: y)
            let croppedRatio = Double(width) * probe.sourceSAR / Double(max(1, height))
            let verticalRemoved = Double(probe.height - height) / Double(probe.height)
            let horizontalRemoved = Double(probe.width - width) / Double(probe.width)
            if croppedRatio >= 1.1, croppedRatio <= 2.5,
               max(verticalRemoved, horizontalRemoved) >= 0.05,
               Double(width * height) / Double(probe.width * probe.height) >= 0.55 {
                candidates.append(crop)
            }
        }
        let clusters = candidates.map { candidate in
            candidates.filter {
                abs($0.width - candidate.width) <= 8 && abs($0.height - candidate.height) <= 8
                    && abs($0.x - candidate.x) <= 6 && abs($0.y - candidate.y) <= 6
            }
        }
        let best = clusters.max(by: { $0.count < $1.count }) ?? []
        let detectedCrop: VideoCrop? = best.count >= 2 ? VideoCrop(
            width: best.map(\.width).sorted()[best.count / 2] / 2 * 2,
            height: best.map(\.height).sorted()[best.count / 2] / 2 * 2,
            x: best.map(\.x).sorted()[best.count / 2] / 2 * 2,
            y: best.map(\.y).sorted()[best.count / 2] / 2 * 2) : nil
        var blackSamples: [Int] = []
        for fraction in [0.2, 0.5, 0.8] {
            let start = max(0, probe.duration * fraction)
            var filters: [String] = []
            if let detectedCrop { filters.append(detectedCrop.filter) }
            filters += ["signalstats", "metadata=print"]
            guard let output = try? CommandRunner.run(ffmpeg,
                ["-hide_banner", "-loglevel", "info", "-ss", String(format: "%.3f", start),
                 "-i", file.path, "-frames:v", "12", "-an", "-vf", filters.joined(separator: ","),
                 "-f", "null", "-"], timeout: 45),
                  let regex = try? NSRegularExpression(pattern: #"lavfi\.signalstats\.YLOW=(\d+)"#) else { continue }
            let values = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap { match -> Int? in
                guard let range = Range(match.range(at: 1), in: output) else { return nil }
                return Int(output[range])
            }
            if !values.isEmpty { blackSamples.append(values.sorted()[values.count / 2]) }
        }
        let blackFloor: Int? = blackSamples.count >= 3 && (blackSamples.min() ?? 0) >= 28
            ? blackSamples.sorted()[blackSamples.count / 2] : nil
        let interlaceAnalysis: VideoInterlaceAnalysis? = {
            guard let output = try? CommandRunner.run(ffmpeg,
                ["-hide_banner", "-loglevel", "info", "-i", file.path,
                 "-filter:v", "idet", "-frames:v", "1500", "-an", "-f", "null", "-"],
                timeout: 180),
                  let regex = try? NSRegularExpression(pattern:
                    #"Multi frame detection:\s*TFF:\s*(\d+)\s+BFF:\s*(\d+)\s+Progressive:\s*(\d+)\s+Undetermined:\s*(\d+)"#),
                  let match = regex.matches(in: output,
                    range: NSRange(output.startIndex..., in: output)).last else { return nil }
            func value(_ index: Int) -> Int {
                guard let range = Range(match.range(at: index), in: output) else { return 0 }
                return Int(output[range]) ?? 0
            }
            return VideoInterlaceAnalysis(topFieldFirst: value(1), bottomFieldFirst: value(2),
                                           progressive: value(3), undetermined: value(4))
        }()
        return VideoProbe(videoCodec: probe.videoCodec, videoDescription: probe.videoDescription,
                          audioCodec: probe.audioCodec, audioDescription: probe.audioDescription,
                          duration: probe.duration, width: probe.width, height: probe.height,
                          frameRate: probe.frameRate, sourceSAR: probe.sourceSAR,
                          detectedCrop: detectedCrop, detectedBlackFloor: blackFloor,
                          interlaceAnalysis: interlaceAnalysis)
    }

    static func askUser(fileName: String, source: URL, probe: VideoProbe,
                        window preferredWindow: NSWindow?, canSaveOriginal: Bool = true) -> VideoExtractionRequest? {
        let dvdSize: VideoOutputSize = probe.usesPALFrameRate ? .dvdPAL : .dvdNTSC
        var request: VideoExtractionRequest?
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let parent = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Video Extraction Options"
            let root = NSStackView()
            root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
            root.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView = NSView()
            panel.contentView?.addSubview(root)
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
                root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
                root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 22),
                root.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -20)
            ])

            let title = NSTextField(labelWithString: fileName)
            title.font = .boldSystemFont(ofSize: 18); root.addArrangedSubview(title)
            if probe.needsConversion {
                let warning = NSTextField(wrappingLabelWithString:
                    "This file uses codecs that may not play on your Mac. Converting it to H.264/AAC is recommended for reliable playback on current Macs. You can keep the original, create one or more converted copies, or do both.")
                warning.textColor = .systemRed
                root.addArrangedSubview(warning)
            }
            let mediaDetails = NSTextField(wrappingLabelWithString:
                probe.codecSummary.replacingOccurrences(of: "\n", with: " • "))
            mediaDetails.textColor = .secondaryLabelColor
            root.addArrangedSubview(mediaDetails)
            let sourceDetails = NSTextField(labelWithString:
                "Source: \(probe.width) × \(probe.height), \(String(format: "%.3g", probe.frameRate)) fps • Estimated aspect ratio: \(probe.estimatedAspectRatio)")
            sourceDetails.textColor = .secondaryLabelColor
            root.addArrangedSubview(sourceDetails)

            let frameRateValues = ["24", "24000/1001", "25", "30000/1001", "30", "50", "60000/1001", "60"]
            let frameRatePicker = NSPopUpButton(frame: .zero, pullsDown: false)
            frameRatePicker.addItems(withTitles: [
                "Keep original - \(String(format: "%.3g", probe.frameRate)) fps",
                "24 fps", "23.976 fps", "25 fps", "29.97 fps", "30 fps",
                "50 fps", "59.94 fps", "60 fps"
            ])
            frameRatePicker.selectItem(at: 0)
            let frameRateToggle = NSButton(checkboxWithTitle: "Change frame rate", target: nil, action: nil)
            frameRateToggle.state = .off
            let frameRateAction = ClosureAction()
            frameRateAction.action = {
                frameRateToggle.state = frameRatePicker.indexOfSelectedItem > 0 ? .on : .off
            }
            frameRatePicker.target = frameRateAction
            frameRatePicker.action = #selector(ClosureAction.run)

            var deinterlaceToggle: NSButton?
            var deinterlaceModePicker: NSPopUpButton?
            if let analysis = probe.interlaceAnalysis, analysis.shouldOfferDeinterlacing {
                let note = NSTextField(wrappingLabelWithString:
                    "\(analysis.summary) BWDIF deinterlacing is recommended for converted copies.")
                note.textColor = .secondaryLabelColor
                root.addArrangedSubview(note)
                let toggle = NSButton(checkboxWithTitle: "Deinterlace converted copies", target: nil, action: nil)
                toggle.state = .on
                root.addArrangedSubview(toggle)
                let picker = NSPopUpButton(frame: .zero, pullsDown: false)
                let sourceRate = probe.frameRate > 0 ? probe.frameRate : 25
                picker.addItems(withTitles: [
                    "One frame per input frame - \(String(format: "%.3g", sourceRate)) fps",
                    "One frame per field - \(String(format: "%.3g", sourceRate * 2)) fps"
                ])
                picker.selectItem(at: 0)
                picker.toolTip = "Field-rate output retains each field's distinct moment; frame-rate output preserves the source frame rate."
                let row = NSStackView(views: [NSTextField(labelWithString: "Deinterlaced output"), picker])
                row.orientation = .horizontal; row.spacing = 12
                root.addArrangedSubview(row)
                deinterlaceToggle = toggle
                deinterlaceModePicker = picker
            }

            let original = NSButton(checkboxWithTitle: "Save original file", target: nil, action: nil)
            original.state = .on
            let sourceCopy = NSButton(checkboxWithTitle: "Create H.264/AAC - original size", target: nil, action: nil)
            sourceCopy.state = canSaveOriginal ? .off : .on
            let dvdCopy = NSButton(checkboxWithTitle: "Create H.264/AAC - \(dvdSize.label)", target: nil, action: nil)
            let hdCopy = NSButton(checkboxWithTitle: "Create H.264/AAC - \(VideoOutputSize.hd720.label)", target: nil, action: nil)
            let fullHDCopy = NSButton(checkboxWithTitle: "Create H.264/AAC - \(VideoOutputSize.hd1080.label)", target: nil, action: nil)
            if canSaveOriginal { root.addArrangedSubview(original) }
            [sourceCopy, dvdCopy, hdCopy, fullHDCopy].forEach(root.addArrangedSubview)
            let handler = VideoOptionsHandler()

            let processingSpacer = NSView()
            processingSpacer.translatesAutoresizingMaskIntoConstraints = false
            processingSpacer.heightAnchor.constraint(equalToConstant: 16).isActive = true
            root.addArrangedSubview(processingSpacer)

            let frameRateRow = NSStackView(views: [frameRateToggle, frameRatePicker])
            frameRateRow.orientation = .horizontal; frameRateRow.spacing = 12
            root.addArrangedSubview(frameRateRow)
            if probe.hasNonStandardFrameRate {
                let note = NSTextField(wrappingLabelWithString:
                    "The source uses a non-standard frame rate; motion-compensated conversion is available.")
                note.textColor = .secondaryLabelColor
                root.addArrangedSubview(note)
            }

            var chosenClip: VideoClipRange?
            let clipToggle = NSButton(checkboxWithTitle: "Converted range", target: nil, action: nil)
            clipToggle.state = .off
            let clipSummary = NSTextField(labelWithString: "Full video")
            clipSummary.textColor = .secondaryLabelColor
            let editClip = ClosureButton(title: "Adjust Clip")
            let clipRow = NSStackView(views: [clipToggle, clipSummary, editClip])
            clipRow.orientation = .horizontal; clipRow.spacing = 12
            root.addArrangedSubview(clipRow)

            let stretch = NSButton(checkboxWithTitle: "Convert video to 16:9", target: nil, action: nil)
            let squeeze = NSButton(checkboxWithTitle: "Convert video to 4:3", target: nil, action: nil)
            stretch.state = .off; squeeze.state = .off
            stretch.toolTip = "Corrects a horizontally compressed picture by reshaping the active image to 16:9."
            squeeze.toolTip = "Corrects a horizontally stretched picture by reshaping the active image to 4:3."
            stretch.target = handler; stretch.action = #selector(VideoOptionsHandler.chooseStretch(_:))
            squeeze.target = handler; squeeze.action = #selector(VideoOptionsHandler.chooseSqueeze(_:))
            handler.stretchButton = stretch; handler.squeezeButton = squeeze
            root.addArrangedSubview(stretch)
            root.addArrangedSubview(squeeze)

            let forceRec709 = NSButton(checkboxWithTitle: "Force Rec.709 tags for YouTube", target: nil, action: nil)
            forceRec709.state = .off
            forceRec709.toolTip = "Replaces colour metadata with Rec.709 limited-range tags without applying a gamma, brightness or pixel-level colour conversion."
            root.addArrangedSubview(forceRec709)

            let widescreen = NSButton(checkboxWithTitle: "Place converted video in a 16:9 frame", target: nil, action: nil)
            widescreen.state = .off
            widescreen.toolTip = "Adds black letterbox or pillarbox borders without stretching the picture. Leave this off to retain the video's natural frame shape."
            handler.widescreenButton = widescreen
            root.addArrangedSubview(widescreen)

            var chosenCrop = probe.detectedCrop
            let cropToggle = NSButton(checkboxWithTitle: "Remove embedded borders", target: nil, action: nil)
            cropToggle.state = .off
            let editCrop = ClosureButton(title: "Adjust Borders")
            let cropRow = NSStackView(views: [cropToggle, editCrop])
            cropRow.orientation = .horizontal; cropRow.spacing = 12
            root.addArrangedSubview(cropRow)

            var chosenColor = VideoColorSettings(brightness: 0,
                contrast: probe.detectedBlackFloor == nil ? 1 : 1.05,
                blackPoint: probe.detectedBlackFloor ?? 16)
            let blacks = NSButton(checkboxWithTitle: "Adjust brightness, contrast, saturation and black levels", target: nil, action: nil)
            blacks.state = .off
            if let floor = probe.detectedBlackFloor {
                blacks.toolTip = "Detected black level: \(floor) (normal video black is approximately 16)."
            }
            let editColour = ClosureButton(title: "Adjust Picture")
            let colourRow = NSStackView(views: [blacks, editColour])
            colourRow.orientation = .horizontal; colourRow.spacing = 12
            root.addArrangedSubview(colourRow)

            let buttonSpacer = NSView()
            buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
            buttonSpacer.heightAnchor.constraint(equalToConstant: 18).isActive = true
            root.addArrangedSubview(buttonSpacer)

            let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
            let cancel = NSButton(title: "Cancel", target: handler, action: #selector(VideoOptionsHandler.cancel))
            let proceed = NSButton(title: "Continue", target: handler, action: #selector(VideoOptionsHandler.accept))
            proceed.keyEquivalent = "\r"
            buttons.addArrangedSubview(cancel); buttons.addArrangedSubview(proceed)
            let buttonRow = NSStackView(views: [NSView(), buttons])
            buttonRow.orientation = .horizontal
            root.addArrangedSubview(buttonRow)
            buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

            editCrop.callback = {
                showBorderEditor(source: source, probe: probe, initial: chosenCrop, parent: panel) { applied, edited in
                    guard applied else { return }
                    chosenCrop = edited
                    cropToggle.state = edited == nil ? .off : .on
                }
            }
            editClip.callback = {
                showClipEditor(source: source, probe: probe, initial: chosenClip, parent: panel) { applied, range in
                    guard applied else { return }
                    chosenClip = range
                    if let range {
                        clipSummary.stringValue = "Frames \(range.startFrame + 1)-\(range.endFrameExclusive)"
                        clipToggle.state = .on
                        original.title = "Save original file (full, untrimmed)"
                        sourceCopy.state = .on
                    } else {
                        clipSummary.stringValue = "Full video"
                        clipToggle.state = .off
                        original.title = "Save original file"
                    }
                }
            }
            editColour.callback = {
                showColorEditor(source: source, probe: probe, initial: chosenColor, parent: panel) { applied, settings in
                    guard applied else { return }
                    chosenColor = settings
                    blacks.state = .on
                }
            }

            panel.contentView?.layoutSubtreeIfNeeded()
            let requiredHeight = ceil(root.fittingSize.height) + 42
            panel.setContentSize(NSSize(width: 620, height: requiredHeight))

            if let parent {
                panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                             y: parent.frame.midY - panel.frame.height / 2))
                panel.hidesOnDeactivate = false
                parent.addChildWindow(panel, ordered: .above)
            } else { panel.center() }
            panel.makeKeyAndOrderFront(nil)
            videoOptionHandlers.append(handler)
            let closePanel = {
                if let parent { parent.removeChildWindow(panel) }
                panel.orderOut(nil)
                handler.clearActions()
                videoOptionHandlers.removeAll { $0 === handler }
                finished.signal()
            }
            let buildRequest: (URL?) -> VideoExtractionRequest = { destination in
                _ = frameRateAction
                var outputs: [VideoOutputSize] = []
                if sourceCopy.state == .on { outputs.append(.source) }
                if dvdCopy.state == .on { outputs.append(dvdSize) }
                if hdCopy.state == .on { outputs.append(.hd720) }
                if fullHDCopy.state == .on { outputs.append(.hd1080) }
                if !canSaveOriginal && outputs.isEmpty { outputs.append(.source) }
                let saveOriginal = canSaveOriginal && (original.state == .on || outputs.isEmpty)
                let selectedRate: String?
                if frameRateToggle.state == .on, frameRatePicker.indexOfSelectedItem > 0 {
                    selectedRate = frameRateValues[frameRatePicker.indexOfSelectedItem - 1]
                } else {
                    selectedRate = nil
                }
                let deinterlace: VideoDeinterlaceSettings?
                if let analysis = probe.interlaceAnalysis,
                   deinterlaceToggle?.state == .on {
                    deinterlace = VideoDeinterlaceSettings(
                        sendFields: deinterlaceModePicker?.indexOfSelectedItem == 1,
                        parity: analysis.parity,
                        selective: analysis.isMixed)
                } else {
                    deinterlace = nil
                }
                let aspectCorrection: VideoAspectCorrection?
                if stretch.state == .on { aspectCorrection = .stretchTo16x9 }
                else if squeeze.state == .on { aspectCorrection = .squeezeTo4x3 }
                else { aspectCorrection = nil }
                return VideoExtractionRequest(saveOriginal: saveOriginal, outputSizes: outputs,
                                               aspectCorrection: aspectCorrection,
                                               forceRec709: forceRec709.state == .on,
                                               fitToWidescreen: widescreen.state == .on,
                                               crop: cropToggle.state == .on ? chosenCrop : nil,
                                               colorSettings: blacks.state == .on ? chosenColor : nil,
                                               targetFrameRate: selectedRate,
                                               deinterlace: deinterlace,
                                               clipRange: clipToggle.state == .on ? chosenClip : nil,
                                               destination: destination)
            }
            handler.acceptAction = {
                if canSaveOriginal {
                    request = buildRequest(nil)
                    closePanel()
                    return
                }
                let folder = NSOpenPanel()
                folder.title = "Choose a folder for the video"
                folder.prompt = "Choose Folder"
                folder.canChooseDirectories = true
                folder.canChooseFiles = false
                folder.canCreateDirectories = true
                folder.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                folder.beginSheetModal(for: panel) { response in
                    guard response == .OK, let destination = folder.url else {
                        panel.makeKeyAndOrderFront(nil)
                        return
                    }
                    request = buildRequest(destination)
                    closePanel()
                }
            }
            handler.cancelAction = { closePanel() }
        }
        finished.wait()
        return request
    }

    private static func showBorderEditor(source: URL, probe: VideoProbe, initial: VideoCrop?,
                                         parent: NSWindow,
                                         completion: @escaping (Bool, VideoCrop?) -> Void) {
        let owner = parent.parent ?? parent
        let controller = BorderEditorController(source: source, probe: probe, initial: initial)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Adjust Embedded Borders"
        panel.level = .modalPanel
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView(); panel.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18)
        ])
        root.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "Set the pixels to remove from each edge. Shaded areas will be removed; use the arrows below the image to check the crop throughout the video."))
        controller.previewView.translatesAutoresizingMaskIntoConstraints = false
        controller.previewView.wantsLayer = true
        controller.previewView.layer?.borderColor = NSColor.separatorColor.cgColor
        controller.previewView.layer?.borderWidth = 1
        controller.previewView.layer?.cornerRadius = 5
        controller.previewView.widthAnchor.constraint(equalToConstant: 900).isActive = true
        controller.previewView.heightAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
        controller.previewView.setContentHuggingPriority(.defaultLow, for: .vertical)
        controller.previewView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(controller.previewView)

        let frameNavigation = NSStackView(views: [controller.previousFrame, controller.frameLabel, controller.nextFrame])
        frameNavigation.orientation = .horizontal
        frameNavigation.alignment = .centerY
        frameNavigation.spacing = 10
        frameNavigation.setContentHuggingPriority(.required, for: .horizontal)

        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 12
        for (label, field, stepper) in [("Left", controller.left, controller.leftStepper),
                                        ("Right", controller.right, controller.rightStepper),
                                        ("Top", controller.top, controller.topStepper),
                                        ("Bottom", controller.bottom, controller.bottomStepper)] {
            let pair = NSStackView(); pair.orientation = .horizontal; pair.spacing = 5
            let labelView = NSTextField(labelWithString: label)
            labelView.setContentHuggingPriority(.required, for: .horizontal)
            pair.addArrangedSubview(labelView)
            field.alignment = .right; field.frame.size.width = 58
            field.widthAnchor.constraint(equalToConstant: 58).isActive = true
            pair.addArrangedSubview(field)
            pair.addArrangedSubview(stepper)
            pair.setContentHuggingPriority(.required, for: .horizontal)
            controls.addArrangedSubview(pair)
        }
        let reset = NSButton(title: "Reset", target: controller, action: #selector(BorderEditorController.resetInsets))
        controls.addArrangedSubview(reset)
        controls.setContentHuggingPriority(.required, for: .horizontal)
        let controlSpacer = NSView()
        controlSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let combinedControls = NSStackView(views: [frameNavigation, controlSpacer, controls])
        combinedControls.orientation = .horizontal
        combinedControls.alignment = .centerY
        combinedControls.spacing = 12
        root.addArrangedSubview(combinedControls)
        combinedControls.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        controller.status.textColor = .secondaryLabelColor
        root.addArrangedSubview(controller.status)

        let handler = BorderEditorSheetHandler(parent: owner, panel: panel, controller: controller)
        let cancel = NSButton(title: "Cancel", target: handler, action: #selector(BorderEditorSheetHandler.cancel))
        let apply = NSButton(title: "Apply", target: handler, action: #selector(BorderEditorSheetHandler.apply)); apply.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, apply]); actions.orientation = .horizontal; actions.spacing = 10
        root.addArrangedSubview(actions)
        borderEditors.append(handler)
        handler.completion = { applied, crop in
            borderEditors.removeAll { $0 === handler }
            completion(applied, crop)
        }
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                     y: parent.frame.midY - panel.frame.height / 2))
        panel.level = owner.level
        panel.hidesOnDeactivate = false
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        controller.loadInitialPreviews()
    }

    private static func showColorEditor(source: URL, probe: VideoProbe, initial: VideoColorSettings,
                                        parent: NSWindow,
                                        completion: @escaping (Bool, VideoColorSettings) -> Void) {
        let owner = parent.parent ?? parent
        let controller = ColorEditorController(source: source, probe: probe, initial: initial)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Adjust Picture"
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView(); panel.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18),
            root.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -18)
        ])
        root.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "The starting values are the app’s best estimate. Adjust them while comparing four points from the video, then click Apply."))
        let grid = NSGridView(views: [
            [controller.imageViews[0], controller.imageViews[1]],
            [controller.imageViews[2], controller.imageViews[3]]
        ])
        grid.rowSpacing = 10; grid.columnSpacing = 10
        for view in controller.imageViews {
            view.imageScaling = .scaleProportionallyUpOrDown; view.imageFrameStyle = .grayBezel
            view.widthAnchor.constraint(equalToConstant: 420).isActive = true
            view.heightAnchor.constraint(equalToConstant: 200).isActive = true
        }
        root.addArrangedSubview(grid)
        for (name, slider, value) in [("Brightness", controller.brightness, controller.brightnessValue),
                                      ("Contrast", controller.contrast, controller.contrastValue),
                                      ("Saturation", controller.saturation, controller.saturationValue),
                                      ("Black level", controller.blackPoint, controller.blackPointValue)] {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            let label = NSTextField(labelWithString: name); label.frame.size.width = 85
            label.widthAnchor.constraint(equalToConstant: 85).isActive = true
            slider.widthAnchor.constraint(equalToConstant: 650).isActive = true
            value.alignment = .right; value.widthAnchor.constraint(equalToConstant: 55).isActive = true
            row.addArrangedSubview(label); row.addArrangedSubview(slider); row.addArrangedSubview(value)
            root.addArrangedSubview(row)
        }
        controller.status.textColor = .secondaryLabelColor; root.addArrangedSubview(controller.status)
        let handler = ColorEditorSheetHandler(parent: owner, panel: panel, controller: controller)
        let cancel = NSButton(title: "Cancel", target: handler, action: #selector(ColorEditorSheetHandler.cancel))
        let apply = NSButton(title: "Apply", target: handler, action: #selector(ColorEditorSheetHandler.apply)); apply.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, apply]); actions.orientation = .horizontal; actions.spacing = 10
        root.addArrangedSubview(actions)
        colorEditors.append(handler)
        handler.completion = { applied, settings in
            colorEditors.removeAll { $0 === handler }
            completion(applied, settings)
        }
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                     y: parent.frame.midY - panel.frame.height / 2))
        panel.level = owner.level
        panel.hidesOnDeactivate = false
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        controller.refresh()
    }

    private static func showClipEditor(source: URL, probe: VideoProbe, initial: VideoClipRange?,
                                       parent: NSWindow,
                                       completion: @escaping (Bool, VideoClipRange?) -> Void) {
        let owner = parent.parent ?? parent
        let controller = ClipEditorController(source: source, probe: probe, initial: initial)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 690),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Adjust Clip"
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView(); panel.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18),
            root.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -18)
        ])
        root.addArrangedSubview(NSTextField(wrappingLabelWithString:
            "Move to an exact source frame, then mark it as the In or Out point. The chosen inclusive range is applied to every re-encoded version."))
        controller.preview.translatesAutoresizingMaskIntoConstraints = false
        controller.preview.widthAnchor.constraint(equalToConstant: 900).isActive = true
        controller.preview.heightAnchor.constraint(equalToConstant: 460).isActive = true
        root.addArrangedSubview(controller.preview)
        controller.timeline.translatesAutoresizingMaskIntoConstraints = false
        controller.timeline.widthAnchor.constraint(equalToConstant: 900).isActive = true
        controller.timeline.heightAnchor.constraint(equalToConstant: 26).isActive = true
        root.addArrangedSubview(controller.timeline)

        controller.frameField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let navigation = NSStackView(views: [controller.playPause, controller.previous,
            NSTextField(labelWithString: "Frame"), controller.frameField, controller.frameStepper,
            controller.next, controller.frameLabel])
        navigation.orientation = .horizontal; navigation.alignment = .centerY; navigation.spacing = 8
        root.addArrangedSubview(navigation)

        let setIn = NSButton(title: "Set In", target: controller, action: #selector(ClipEditorController.setInPoint))
        let jumpIn = NSButton(title: "[", target: controller, action: #selector(ClipEditorController.jumpToInPoint))
        jumpIn.toolTip = "Move to the In frame"
        jumpIn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let setOut = NSButton(title: "Set Out", target: controller, action: #selector(ClipEditorController.setOutPoint))
        let jumpOut = NSButton(title: "]", target: controller, action: #selector(ClipEditorController.jumpToOutPoint))
        jumpOut.toolTip = "Move to the Out frame"
        jumpOut.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let reset = NSButton(title: "Reset", target: controller, action: #selector(ClipEditorController.resetRange))
        let points = NSStackView(views: [setIn, jumpIn, controller.inLabel,
                                         setOut, jumpOut, controller.outLabel, reset])
        points.orientation = .horizontal; points.alignment = .centerY; points.spacing = 12
        root.addArrangedSubview(points)
        controller.status.textColor = .secondaryLabelColor
        root.addArrangedSubview(controller.status)

        let handler = ClipEditorSheetHandler(parent: owner, panel: panel, controller: controller)
        let cancel = NSButton(title: "Cancel", target: handler, action: #selector(ClipEditorSheetHandler.cancel))
        let apply = NSButton(title: "Apply", target: handler, action: #selector(ClipEditorSheetHandler.apply)); apply.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, apply]); actions.orientation = .horizontal; actions.spacing = 10
        root.addArrangedSubview(actions)
        clipEditors.append(handler)
        handler.completion = { applied, range in
            clipEditors.removeAll { $0 === handler }
            completion(applied, range)
        }
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                     y: parent.frame.midY - panel.frame.height / 2))
        panel.level = owner.level; panel.hidesOnDeactivate = false
        owner.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        controller.loadPreview()
    }

    static func previewFrame(source: URL, frame: Int) -> NSImage? {
        guard let ffmpeg = BundledMediaTools.ffmpegExecutable else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("CDExplorer-frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        let filter = "select=eq(n\\,\(max(0, frame))),scale=900:460:force_original_aspect_ratio=decrease:flags=lanczos"
        let arguments = ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path,
                         "-vf", filter, "-frames:v", "1", output.path]
        if (try? CommandRunner.run(ffmpeg, arguments, timeout: 120)) == nil { return nil }
        guard let data = try? Data(contentsOf: output) else { return nil }
        return NSImage(data: data)
    }

    static func previewImage(source: URL, probe: VideoProbe, crop: VideoCrop?, restoreBlacks: Bool) -> NSImage? {
        previewImage(source: source, probe: probe, crop: crop,
                     colorSettings: restoreBlacks ? VideoColorSettings(brightness: 0, contrast: 1.05,
                                                                      blackPoint: probe.detectedBlackFloor ?? 16) : nil,
                     atFraction: 0.5)
    }

    static func previewImage(source: URL, probe: VideoProbe, crop: VideoCrop?,
                             colorSettings: VideoColorSettings?, atFraction: Double) -> NSImage? {
        guard let ffmpeg = BundledMediaTools.ffmpegExecutable else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("CDExplorerPreview-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        var filters: [String] = []
        if let crop { filters.append(crop.filter) }
        if let colorSettings { filters += colorFilters(colorSettings) }
        filters.append("scale=860:660:force_original_aspect_ratio=decrease:flags=lanczos")
        let midpoint = max(0, probe.duration * atFraction)
        let arguments = ["-y", "-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", midpoint),
                         "-i", source.path, "-frames:v", "1", "-vf", filters.joined(separator: ","), output.path]
        if (try? CommandRunner.run(ffmpeg, arguments, timeout: 60)) == nil { return nil }
        guard let data = try? Data(contentsOf: output) else { return nil }
        return NSImage(data: data)
    }

    private static func blackLevelFilter(_ floor: Int) -> String {
        let value = min(64, max(17, floor))
        return "lutyuv=y='clip((val-\(value))*219/(235-\(value))+16,16,235)'"
    }

    private static func colorFilters(_ settings: VideoColorSettings) -> [String] {
        var filters: [String] = []
        if settings.blackPoint != 16 { filters.append(blackLevelFilter(settings.blackPoint)) }
        filters.append(String(format: "eq=brightness=%.3f:contrast=%.3f:saturation=%.3f",
                              settings.brightness, settings.contrast, settings.saturation))
        return filters
    }

    static func convertToH264(source: URL, destination: URL, probe: VideoProbe,
                              outputSize: VideoOutputSize = .source,
                              aspectCorrection: VideoAspectCorrection? = nil,
                              forceRec709: Bool = false,
                              fitToWidescreen: Bool = false,
                              crop: VideoCrop? = nil, colorSettings: VideoColorSettings? = nil,
                              targetFrameRate: String? = nil,
                              deinterlace: VideoDeinterlaceSettings? = nil,
                              clipRange: VideoClipRange? = nil,
                              progress: @escaping (Double) -> Void = { _ in }) throws {
        guard let ffmpeg = BundledMediaTools.ffmpegExecutable else {
            throw ExtractorError.commandFailed("FFmpeg is required to convert older video codecs to H.264.")
        }
        let canCopyH264Video = forceRec709 && probe.videoCodec == "h264" && outputSize == .source
            && aspectCorrection == nil && !fitToWidescreen && crop == nil && colorSettings == nil
            && targetFrameRate == nil && deinterlace == nil && clipRange == nil
        if canCopyH264Video {
            let metadataFilter = "h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0"
            let arguments = ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path,
                             "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                             "-c:v", "copy", "-bsf:v", metadataFilter,
                             "-c:a", "aac", "-b:a", "256k",
                             "-color_primaries:v", "bt709", "-color_trc:v", "bt709",
                             "-colorspace:v", "bt709", "-color_range:v", "tv",
                             "-movflags", "+faststart+write_colr",
                             "-progress", "pipe:1", "-nostats", destination.path]
            _ = try CommandRunner.runWithProgress(ffmpeg, arguments,
                duration: probe.duration, timeout: max(300, probe.duration * 2 + 120), progress: progress)
            let converted = try inspect(destination)
            guard converted.videoCodec == "h264" else {
                throw ExtractorError.commandFailed("The Rec.709-tagged video could not be validated as H.264.")
            }
            return
        }
        var filters: [String] = []
        if let clipRange { filters.append(clipRange.videoFilter) }
        if let deinterlace { filters.append(deinterlace.filter) }
        if let crop { filters.append(crop.filter) }
        if let colorSettings { filters += colorFilters(colorSettings) }
        if let targetFrameRate {
            filters.append("minterpolate=fps=\(targetFrameRate):mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1")
        }
        switch aspectCorrection {
        case .stretchTo16x9:
            // Deliberately reshape the active picture rather than preserving
            // its current proportions. Subsequent sizing/padding sees 16:9.
            filters += ["scale=trunc(ih*16/9/2)*2:trunc(ih/2)*2:flags=lanczos", "setsar=1"]
        case .squeezeTo4x3:
            // Correct a source whose pixels have been stored too wide.
            filters += ["scale=trunc(ih*4/3/2)*2:trunc(ih/2)*2:flags=lanczos", "setsar=1"]
        case nil:
            break
        }
        switch outputSize {
        case .source:
            if fitToWidescreen {
                // First convert the displayed picture to square pixels, then
                // expand whichever canvas dimension is necessary to reach 16:9.
                // The max() expressions guarantee padding is never smaller
                // than the post-crop input, including extra-wide sources.
                filters += ["scale=trunc(iw*sar/2)*2:trunc(ih/2)*2:flags=lanczos", "setsar=1",
                            "pad=ceil(max(iw\\,ih*16/9)/2)*2:ceil(max(ih\\,iw*9/16)/2)*2:(ow-iw)/2:(oh-ih)/2:black"]
            } else {
                filters += ["scale=trunc(iw*sar/2)*2:trunc(ih/2)*2:flags=lanczos", "setsar=1"]
            }
        case .dvdPAL:
            if fitToWidescreen {
                // Work in a square-pixel 16:9 canvas, then store it as anamorphic PAL.
                filters += ["scale=trunc(iw*sar/2)*2:trunc(ih/2)*2:flags=lanczos", "setsar=1",
                            "scale=1024:576:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos",
                            "pad=1024:576:(ow-iw)/2:(oh-ih)/2:black",
                            "scale=720:576:flags=lanczos", "setsar=64/45"]
            } else {
                filters += ["scale=trunc(iw*sar/2)*2:ih:flags=lanczos", "setsar=1",
                            "scale=720:576:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos"]
            }
        case .dvdNTSC:
            if fitToWidescreen {
                filters += ["scale=trunc(iw*sar/2)*2:trunc(ih/2)*2:flags=lanczos", "setsar=1",
                            "scale=854:480:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos",
                            "pad=854:480:(ow-iw)/2:(oh-ih)/2:black",
                            "scale=720:480:flags=lanczos", "setsar=32/27"]
            } else {
                filters += ["scale=trunc(iw*sar/2)*2:ih:flags=lanczos", "setsar=1",
                            "scale=720:480:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos"]
            }
        case .hd720:
            if fitToWidescreen {
                filters += ["scale=trunc(iw*sar/2)*2:trunc(ih/2)*2:flags=lanczos", "setsar=1",
                            "scale=1280:720:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos",
                            "pad=1280:720:(ow-iw)/2:(oh-ih)/2:black", "setsar=1"]
            } else {
                filters += ["scale=trunc(iw*sar/2)*2:ih:flags=lanczos", "setsar=1",
                            "scale=1280:720:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos"]
            }
        case .hd1080:
            if fitToWidescreen {
                filters += ["scale=trunc(iw*sar/2)*2:trunc(ih/2)*2:flags=lanczos", "setsar=1",
                            "scale=1920:1080:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos",
                            "pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black", "setsar=1"]
            } else {
                filters += ["scale=trunc(iw*sar/2)*2:ih:flags=lanczos", "setsar=1",
                            "scale=1920:1080:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos"]
            }
        }
        if fitToWidescreen {
            filters.append("setdar=16/9")
        } else if aspectCorrection == .stretchTo16x9 {
            filters.append("setdar=16/9")
        } else if aspectCorrection == .squeezeTo4x3 {
            filters.append("setdar=4/3")
        }
        if forceRec709 {
            // Metadata only: replace the final frame properties inherited by
            // libx264 without performing any colour-space or pixel conversion.
            filters.append("setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709")
        }
        var arguments = ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path,
                         "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                         "-vf", filters.joined(separator: ",")]
        if let clipRange { arguments += ["-af", clipRange.audioFilter] }
        if deinterlace != nil { arguments += ["-field_order", "progressive"] }
        arguments += ["-c:v", "libx264", "-preset", "slow", "-crf", "16", "-profile:v", "high", "-pix_fmt", "yuv420p"]
        if forceRec709 {
            // Encoder colour options write the H.264 VUI values; write_colr
            // ensures the same values are also present in the MP4 container.
            arguments += ["-color_primaries:v", "bt709", "-color_trc:v", "bt709",
                          "-colorspace:v", "bt709", "-color_range:v", "tv"]
        }
        arguments += ["-c:a", "aac", "-b:a", "256k",
                      "-movflags", forceRec709 ? "+faststart+write_colr" : "+faststart",
                      "-progress", "pipe:1", "-nostats", destination.path]
        let outputDuration = clipRange?.duration ?? probe.duration
        _ = try CommandRunner.runWithProgress(ffmpeg, arguments,
            duration: outputDuration, timeout: max(300, outputDuration * 5 + 120), progress: progress)
        let converted = try inspect(destination)
        guard converted.videoCodec == "h264" else {
            throw ExtractorError.commandFailed("The converted video could not be validated as H.264.")
        }
    }
}

struct DataTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    let file: CDDataFile?
    let children: [DataTreeNode]?

    var descendantFileIDs: Set<String> {
        if let file { return [file.id] }
        return Set((children ?? []).flatMap(\.descendantFileIDs))
    }

    var descendantFolderIDs: Set<String> {
        guard file == nil else { return [] }
        return Set([id]).union((children ?? []).flatMap(\.descendantFolderIDs))
    }

    static func roots(for files: [CDDataFile]) -> [DataTreeNode] {
        make(files: files, depth: 0, prefix: "")
    }

    private static func make(files: [CDDataFile], depth: Int, prefix: String) -> [DataTreeNode] {
        let groups = Dictionary(grouping: files) { file in
            depth < file.path.count ? file.path[depth] : (file.path.last ?? "unnamed")
        }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            guard let members = groups[name], let sample = members.first else { return nil }
            let nodePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if members.count == 1, depth == sample.path.count - 1 {
                return DataTreeNode(id: sample.id, name: name, file: sample, children: nil)
            }
            return DataTreeNode(id: "folder:\(sample.trackNumber):\(nodePath)", name: name, file: nil,
                                children: make(files: members, depth: depth + 1, prefix: nodePath))
        }
    }
}

final class ISO9660Reader {
    private let disc: ISOBlockReader
    private let trackStart: Int
    private var joliet = false
    private var extentsAreAbsolute = false
    private var rootExtent = 0
    private var rootSize = 0
    private(set) var volumeName = "Data"

    init(disc: ISOBlockReader, trackStart: Int) throws {
        self.disc = disc
        self.trackStart = trackStart
        try locateVolumeDescriptor()
    }

    private func locateVolumeDescriptor() throws {
        var primary: Data?
        var supplementary: Data?
        for index in 16..<80 {
            let sector = try disc.dataSector(lba: trackStart + index)
            guard sector.count >= 2048 else { continue }
            let identifier = String(data: sector.subdata(in: 1..<6), encoding: .ascii)
            guard identifier == "CD001" else { continue }
            if sector[0] == 1 { primary = sector }
            if sector[0] == 2, sector[88] == 0x25, sector[89] == 0x2F { supplementary = sector }
            if sector[0] == 255 { break }
        }
        guard let descriptor = supplementary ?? primary else { throw ExtractorError.noISO9660 }
        joliet = supplementary != nil
        volumeName = decodeVolumeName(descriptor.subdata(in: 40..<72))
        let rootLength = Int(descriptor[156])
        guard rootLength >= 34, 156 + rootLength <= descriptor.count else {
            throw ExtractorError.invalidISO("missing root directory")
        }
        rootExtent = Int(le32(descriptor, 158))
        rootSize = Int(le32(descriptor, 166))
        // Multisession discs exist in both forms. Test both possible addresses
        // against the ISO root-directory record rather than trusting a numeric
        // heuristic: Enhanced-CD authoring tools vary considerably here.
        if trackStart == 0 {
            guard looksLikeRootDirectory(at: rootExtent) else {
                throw ExtractorError.invalidISO("the root directory could not be read")
            }
            extentsAreAbsolute = false
        } else {
            let absoluteIsValid = looksLikeRootDirectory(at: rootExtent)
            let relativeIsValid = looksLikeRootDirectory(at: trackStart + rootExtent)
            switch (absoluteIsValid, relativeIsValid) {
            case (true, false): extentsAreAbsolute = true
            case (false, true): extentsAreAbsolute = false
            case (true, true): extentsAreAbsolute = rootExtent >= trackStart
            case (false, false):
                throw ExtractorError.invalidISO("neither multisession extent convention produced a valid root directory")
            }
        }
    }

    private func looksLikeRootDirectory(at discLBA: Int) -> Bool {
        guard discLBA >= 0,
              let sector = try? disc.dataSector(lba: discLBA),
              sector.count >= 34 else { return false }
        let length = Int(sector[0])
        guard length >= 34, length <= sector.count,
              Int(sector[32]) == 1, sector[33] == 0,
              sector[25] & 0x02 != 0 else { return false }
        return Int(le32(sector, 2)) == rootExtent
    }

    func entries() throws -> [ISOEntry] {
        var result: [ISOEntry] = []
        var visited = Set<Int>()
        try walkDirectory(extent: rootExtent, size: rootSize, path: [], visited: &visited, result: &result, depth: 0)
        var seen = Set<String>()
        return result.filter { seen.insert($0.path.joined(separator: "/").lowercased()).inserted }
    }

    func extract(_ suppliedEntries: [ISOEntry]? = nil, to destination: URL, flattenSingle: Bool = false,
                 cancellationTicket: Int? = nil,
                 progress: @escaping (Double, String) -> Void) throws -> Int {
        let selected = try suppliedEntries ?? entries()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let totalBytes = max(1, selected.reduce(0) { $0 + $1.size })
        var completedBytes = 0
        for entry in selected {
            if let cancellationTicket { try OperationCancellation.shared.check(cancellationTicket) }
            let outputPath = flattenSingle && selected.count == 1 ? [entry.path.last ?? "unnamed"] : entry.path
            let relative = outputPath.reduce(destination) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(at: relative.deletingLastPathComponent(), withIntermediateDirectories: true)
            let displayPath = entry.path.joined(separator: "/")
            progress(Double(completedBytes) / Double(totalBytes), displayPath)
            let data = try fileData(extent: entry.extent, size: entry.size,
                                    cancellationTicket: cancellationTicket) { fileBytes in
                progress(Double(completedBytes + fileBytes) / Double(totalBytes), displayPath)
            }
            try data.write(to: relative, options: .atomic)
            completedBytes += entry.size
        }
        progress(1, "Complete")
        return selected.count
    }

    private func walkDirectory(extent: Int, size: Int, path: [String], visited: inout Set<Int>,
                               result: inout [ISOEntry], depth: Int) throws {
        guard depth < 64, !visited.contains(extent) else { return }
        visited.insert(extent)
        let bytes = try fileData(extent: extent, size: size)
        var offset = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 {
                offset = ((offset / 2048) + 1) * 2048
                continue
            }
            guard length >= 34, offset + length <= bytes.count else { break }
            let record = bytes.subdata(in: offset..<(offset + length))
            let nameLength = Int(record[32])
            guard 33 + nameLength <= record.count else { break }
            let nameBytes = record.subdata(in: 33..<(33 + nameLength))
            if nameLength == 1 && (nameBytes[0] == 0 || nameBytes[0] == 1) {
                offset += length
                continue
            }
            let name = safeName(decodeName(nameBytes))
            let childExtent = Int(le32(record, 2))
            let childSize = Int(le32(record, 10))
            let isDirectory = record[25] & 0x02 != 0
            if isDirectory {
                try walkDirectory(extent: childExtent, size: childSize, path: path + [name],
                                  visited: &visited, result: &result, depth: depth + 1)
            } else {
                result.append(ISOEntry(path: path + [name], extent: childExtent, size: childSize))
            }
            offset += length
        }
    }

    func fileData(extent: Int, size: Int, cancellationTicket: Int? = nil,
                  progress: ((Int) -> Void)? = nil) throws -> Data {
        let discExtent = extentsAreAbsolute ? extent : trackStart + extent
        guard cancellationTicket != nil else {
            return try disc.fileData(extent: discExtent, size: size, progress: progress)
        }
        var result = Data(); result.reserveCapacity(size)
        var remaining = size; var lba = discExtent; var completed = 0
        while remaining > 0 {
            if let cancellationTicket { try OperationCancellation.shared.check(cancellationTicket) }
            let sector = try disc.dataSector(lba: lba)
            let count = min(remaining, 2048)
            result.append(sector.prefix(count))
            remaining -= count; completed += count; lba += 1
            progress?(completed)
        }
        return result
    }

    private func decodeVolumeName(_ data: Data) -> String {
        let value: String
        if joliet {
            value = String(data: data, encoding: .utf16BigEndian) ?? "Data"
        } else {
            value = String(data: data, encoding: .ascii) ?? "Data"
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }

    private func decodeName(_ data: Data) -> String {
        var name: String
        if joliet {
            name = String(data: data, encoding: .utf16BigEndian) ?? "unnamed"
        } else {
            name = String(data: data, encoding: .ascii) ?? "unnamed"
        }
        if let semicolon = name.lastIndex(of: ";") { name = String(name[..<semicolon]) }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    private func safeName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let parts = name.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }
        let cleaned = parts.joined()
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "unnamed" : cleaned
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

enum AudioOutputFormat: String, CaseIterable, Identifiable {
    case wav = "WAV (lossless)"
    case aiff = "AIFF (lossless)"
    case flac = "FLAC (lossless)"
    case mp3 = "MP3 (320 kbps)"
    case aac = "AAC (320 kbps)"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .flac: return "flac"
        case .mp3: return "mp3"
        case .aac: return "m4a"
        }
    }
}

struct AudioExtractionReport {
    var retriedSectors = 0
    var rereadAttempts = 0
}

enum AudioExtractor {
    private static let bytesPerSector = 2352
    private static let sectorsPerChunk = 27

    static func extract(track: CDTrack, disc: RawCDReader, to destination: URL,
                        format: AudioOutputFormat, cancellationTicket: Int,
                        progress: (Double) -> Void) throws -> AudioExtractionReport {
        let temporaryWAV = format == .wav
            ? destination
            : destination.deletingLastPathComponent().appendingPathComponent(".CD Explorer Track \(track.number) \(UUID().uuidString).wav")
        var completed = false
        defer {
            if temporaryWAV != destination { try? FileManager.default.removeItem(at: temporaryWAV) }
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }

        let dataSize = track.sectorCount * bytesPerSector
        try waveHeader(dataSize: dataSize).write(to: temporaryWAV, options: .atomic)
        let output = try FileHandle(forWritingTo: temporaryWAV)
        defer { try? output.close() }
        try output.seekToEnd()

        var report = AudioExtractionReport()
        var offset = 0
        while offset < track.sectorCount {
            try OperationCancellation.shared.check(cancellationTicket)
            let count = min(sectorsPerChunk, track.sectorCount - offset)
            let lba = track.startLBA + offset
            let first = try disc.rawSectors(lba: lba, count: count)
            let second = try disc.rawSectors(lba: lba, count: count)
            if first == second {
                try output.write(contentsOf: first)
            } else {
                var verified = Data()
                verified.reserveCapacity(count * bytesPerSector)
                for sectorIndex in 0..<count {
                    let sectorLBA = lba + sectorIndex
                    let range = (sectorIndex * bytesPerSector)..<((sectorIndex + 1) * bytesPerSector)
                    let firstSector = first.subdata(in: range)
                    let secondSector = second.subdata(in: range)
                    if firstSector == secondSector {
                        verified.append(firstSector)
                        continue
                    }
                    report.retriedSectors += 1
                    var seen: [Data: Int] = [firstSector: 1, secondSector: 1]
                    var match: Data?
                    for _ in 0..<6 {
                        try OperationCancellation.shared.check(cancellationTicket)
                        let candidate = try disc.rawSector(lba: sectorLBA)
                        report.rereadAttempts += 1
                        seen[candidate, default: 0] += 1
                        if seen[candidate, default: 0] >= 2 { match = candidate; break }
                    }
                    guard let match else { throw ExtractorError.unverifiedAudioSector(sectorLBA) }
                    verified.append(match)
                }
                try output.write(contentsOf: verified)
            }
            offset += count
            progress(Double(offset) / Double(max(1, track.sectorCount)) * (format == .wav ? 1 : 0.9))
        }
        try output.synchronize()
        try output.close()

        if format != .wav {
            try OperationCancellation.shared.check(cancellationTicket)
            guard let ffmpeg = BundledMediaTools.ffmpegExecutable else {
                throw ExtractorError.commandFailed("FFmpeg is required for \(format.rawValue) output. WAV extraction works without it.")
            }
            var arguments = ["-y", "-hide_banner", "-loglevel", "error", "-i", temporaryWAV.path, "-map_metadata", "-1"]
            switch format {
            case .wav: break
            case .aiff: arguments += ["-c:a", "pcm_s16be"]
            case .flac: arguments += ["-c:a", "flac", "-compression_level", "8"]
            case .mp3: arguments += ["-c:a", "libmp3lame", "-b:a", "320k"]
            case .aac: arguments += ["-c:a", "aac", "-b:a", "320k"]
            }
            arguments.append(destination.path)
            _ = try CommandRunner.run(ffmpeg, arguments,
                                      timeout: max(120, Double(track.sectorCount) / 75 * 2 + 60))
            progress(1)
        }

        let info = try CommandRunner.run("/usr/bin/afinfo", [destination.path], timeout: 30)
        guard info.contains("Data format:") else {
            throw ExtractorError.commandFailed("The extracted audio file could not be validated by macOS.")
        }
        completed = true
        return report
    }

    private static func waveHeader(dataSize: Int) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(value.data(using: .ascii)!) }
        func le16(_ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }
        func le32(_ value: UInt32) {
            data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8((value >> 24) & 0xff))
        }
        text("RIFF"); le32(UInt32(36 + dataSize)); text("WAVE")
        text("fmt "); le32(16); le16(1); le16(2); le32(44_100); le32(176_400); le16(4); le16(16)
        text("data"); le32(UInt32(dataSize))
        return data
    }
}

enum AudioSilenceAnalyzer {
    // −50 dBFS: quiet enough to be an intentional CD gap, without treating an ordinary
    // fade or a quiet musical passage as silence. A split also requires two full seconds.
    private static let silencePeak = 104
    private static let minimumGapSectors = 150
    private static let minimumPieceSectors = 75 * 20
    // Read in manageable blocks, testing every sector. RawCDReader performs one
    // seek per block but uses the one-sector reads required by optical devices.
    private static let readChunkSectors = 75 * 20

    static func suggestions(for sources: [CDTrack], disc: RawCDReader, cancellationTicket: Int,
                            progress: (Double) -> Void) throws -> [NamedAudioTrack] {
        let total = max(1, sources.reduce(0) { $0 + $1.sectorCount })
        var examined = 0
        var result: [NamedAudioTrack] = []

        for source in sources {
            var gaps: [Range<Int>] = []
            var silenceStart: Int?
            var chunkStart = source.startLBA
            while chunkStart < source.endLBA {
                try OperationCancellation.shared.check(cancellationTicket)
                let count = min(readChunkSectors, source.endLBA - chunkStart)
                let bytes = try disc.rawSectors(lba: chunkStart, count: count)
                let silent = silenceFlags(in: bytes, sectorCount: count)
                for index in 0..<count {
                    let lba = chunkStart + index
                    if silent[index], silenceStart == nil { silenceStart = lba }
                    if !silent[index], let start = silenceStart {
                        if lba - start >= minimumGapSectors { gaps.append(start..<lba) }
                        silenceStart = nil
                    }
                }
                examined += count
                progress(Double(examined) / Double(total))
                chunkStart += count
            }
            if let start = silenceStart, source.endLBA - start >= minimumGapSectors {
                gaps.append(start..<source.endLBA)
            }

            var contentStart = source.startLBA
            var contentEnd = source.endLBA
            if let first = gaps.first, first.lowerBound == source.startLBA { contentStart = first.upperBound }
            if let last = gaps.last, last.upperBound == source.endLBA { contentEnd = last.lowerBound }
            let interior = gaps.filter { $0.lowerBound > contentStart && $0.upperBound < contentEnd }
            guard !interior.isEmpty else { continue }
            var ranges: [Range<Int>] = []
            var cursor = contentStart
            for gap in interior {
                if gap.lowerBound - cursor >= minimumPieceSectors { ranges.append(cursor..<gap.lowerBound) }
                cursor = gap.upperBound
            }
            if contentEnd - cursor >= minimumPieceSectors { ranges.append(cursor..<contentEnd) }
            guard ranges.count > 1 else { continue }

            for (index, range) in ranges.enumerated() {
                let name: String
                if source.number == 0 {
                    name = "Hidden Track \(index + 1)"
                } else if index == 0 {
                    name = "Track \(source.number) (without silence)"
                } else {
                    name = index == 1 ? "End Hidden Track" : "End Hidden Track \(index)"
                }
                let slice = CDTrack(session: source.session, number: source.number,
                                    startLBA: range.lowerBound, endLBA: range.upperBound,
                                    description: "suggested split audio")
                result.append(NamedAudioTrack(track: slice, name: name))
            }
        }
        progress(1)
        return result
    }

    private static func silenceFlags(in data: Data, sectorCount: Int) -> [Bool] {
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let samplesPerSector = 2352 / MemoryLayout<Int16>.size
            var result = Array(repeating: true, count: sectorCount)
            for sector in 0..<sectorCount {
                let start = sector * samplesPerSector
                let end = min(samples.count, start + samplesPerSector)
                for index in start..<end {
                    let sample = samples[index]
                    let magnitude = sample == Int16.min ? 32768 : abs(Int(sample))
                    if magnitude > silencePeak {
                        result[sector] = false
                        break
                    }
                }
            }
            return result
        }
    }
}

final class DiscAudioPlayer {
    private let queue = DispatchQueue(label: "CDExplorer.AudioPlayback", qos: .userInitiated)
    private let lock = NSLock()
    private var token = UUID()
    private var waitingSlots: DispatchSemaphore?
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?

    func stop() {
        lock.lock()
        token = UUID()
        let slots = waitingSlots
        waitingSlots = nil
        lock.unlock()
        for _ in 0..<4 { slots?.signal() }
        DispatchQueue.main.async {
            self.node?.stop()
            self.engine?.stop()
            self.node = nil
            self.engine = nil
        }
    }

    func play(track: CDTrack, device: String, started: @escaping () -> Void,
              finished: @escaping () -> Void, failed: @escaping (Error) -> Void) {
        stop()
        let current = UUID()
        lock.lock(); token = current; lock.unlock()
        queue.async {
            do {
                let disc = try RawCDReader(device: device)
                let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100,
                                           channels: 2, interleaved: true)!
                let slots = DispatchSemaphore(value: 3)
                self.lock.lock(); self.waitingSlots = slots; self.lock.unlock()
                var lba = track.startLBA
                var first = true
                while lba < track.endLBA, self.isCurrent(current) {
                    slots.wait()
                    guard self.isCurrent(current) else { break }
                    let count = min(300, track.endLBA - lba)
                    let data = try disc.rawSectors(lba: lba, count: count)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                        frameCapacity: AVAudioFrameCount(data.count / 4)) else {
                        throw ExtractorError.commandFailed("Could not prepare audio playback.")
                    }
                    buffer.frameLength = buffer.frameCapacity
                    data.copyBytes(to: buffer.mutableAudioBufferList.pointee.mBuffers.mData!
                        .assumingMemoryBound(to: UInt8.self), count: data.count)
                    let isLast = lba + count >= track.endLBA
                    DispatchQueue.main.sync {
                        guard self.isCurrent(current) else { slots.signal(); return }
                        if first {
                            let engine = AVAudioEngine()
                            let node = AVAudioPlayerNode()
                            engine.attach(node)
                            engine.connect(node, to: engine.mainMixerNode, format: format)
                            try? engine.start()
                            self.engine = engine; self.node = node
                        }
                        self.node?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                            slots.signal()
                            if isLast {
                                DispatchQueue.main.async {
                                    if self.isCurrent(current) { finished(); self.stop() }
                                }
                            }
                        }
                        if first { self.node?.play(); started(); first = false }
                    }
                    lba += count
                }
            } catch {
                DispatchQueue.main.async { if self.isCurrent(current) { failed(error); self.stop() } }
            }
        }
    }

    private func isCurrent(_ value: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == value
    }
}

enum BundledMediaTools {
    static var ffmpegCandidates: [String] {
        bundledToolCandidates(named: "ffmpeg") + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    }

    static var ffprobeCandidates: [String] {
        bundledToolCandidates(named: "ffprobe") + ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
    }

    private static func bundledToolCandidates(named name: String) -> [String] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        return [resources.appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent(name).path]
    }

    static var ffmpegExecutable: String? {
        ffmpegCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static var ffprobeExecutable: String? {
        ffprobeCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}
struct CDMetadata: Identifiable, Hashable {
    let id: String
    let artist: String
    let release: String
    let edition: String
    let trackTitles: [String]
}

enum MusicBrainzLookup {
    private enum LookupError: LocalizedError {
        case invalidResponse
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "MusicBrainz returned an unreadable response."
            case .server(let status):
                return "MusicBrainz returned HTTP status \(status)."
            }
        }
    }

    static func fetch(for disc: DiscSnapshot, completion: @escaping (Result<[CDMetadata], Error>) -> Void) {
        let audio = disc.tracks.filter(\.isAudio)
        guard let last = audio.last, !audio.isEmpty else { completion(.success([])); return }
        let offsets = audio.map { String($0.startLBA + 150) }.joined(separator: "+")
        let toc = "1+\(audio.count)+\(last.endLBA + 150)+\(offsets)"
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/discid/-")
        components?.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: "recordings+artist-credits"),
            URLQueryItem(name: "cdstubs", value: "no"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "toc", value: toc)
        ]
        guard let url = components?.url else {
            completion(.success([])); return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("CDExplorer/3.1 (https://github.com/michaelsft/CD-Explorer)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        perform(request, audioCount: audio.count, attempt: 1, completion: completion)
    }

    private static func perform(_ request: URLRequest, audioCount: Int, attempt: Int,
                                completion: @escaping (Result<[CDMetadata], Error>) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                retry(request, audioCount: audioCount, attempt: attempt, error: error, completion: completion)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                retry(request, audioCount: audioCount, attempt: attempt, error: LookupError.invalidResponse,
                      completion: completion)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let lookupError = LookupError.server(http.statusCode)
                if http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                    retry(request, audioCount: audioCount, attempt: attempt, error: lookupError,
                          completion: completion)
                } else {
                    completion(.failure(lookupError))
                }
                return
            }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let releases = root["releases"] as? [[String: Any]] else {
                retry(request, audioCount: audioCount, attempt: attempt, error: LookupError.invalidResponse,
                      completion: completion)
                return
            }
            completion(.success(parse(releases: releases, audioCount: audioCount)))
        }.resume()
    }

    private static func retry(_ request: URLRequest, audioCount: Int, attempt: Int, error: Error,
                              completion: @escaping (Result<[CDMetadata], Error>) -> Void) {
        guard attempt < 3 else { completion(.failure(error)); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(attempt)) {
            perform(request, audioCount: audioCount, attempt: attempt + 1, completion: completion)
        }
    }

    private static func parse(releases: [[String: Any]], audioCount: Int) -> [CDMetadata] {
        var choices: [CDMetadata] = []
        var seen = Set<String>()
        for release in releases {
            guard let media = release["media"] as? [[String: Any]] else { continue }
            let artistCredits = release["artist-credit"] as? [[String: Any]]
            let artist = artistCredits?.compactMap { credit -> String? in
                (credit["artist"] as? [String: Any])?["name"] as? String
            }.joined(separator: ", ") ?? ""
            let releaseID = release["id"] as? String ?? UUID().uuidString
            let editionParts = [release["date"] as? String, release["country"] as? String,
                                release["status"] as? String, release["disambiguation"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for (mediumIndex, medium) in media.enumerated() {
                guard let tracks = medium["tracks"] as? [[String: Any]], tracks.count == audioCount else { continue }
                let titles = tracks.compactMap { track -> String? in
                    if let title = track["title"] as? String { return title }
                    return (track["recording"] as? [String: Any])?["title"] as? String
                }
                guard titles.count == audioCount else { continue }
                let mediumPosition = (medium["position"] as? NSNumber)?.intValue ?? mediumIndex + 1
                let choiceID = "\(releaseID)-\(mediumPosition)"
                guard seen.insert(choiceID).inserted else { continue }
                var details = editionParts
                if media.count > 1 { details.append("Disc \(mediumPosition)") }
                choices.append(CDMetadata(id: choiceID, artist: artist,
                    release: release["title"] as? String ?? "Unknown release",
                    edition: details.joined(separator: " • "), trackTitles: titles))
            }
        }
        return choices
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tracks: [CDTrack] = []
    @Published var hiddenTrack: CDTrack?
    @Published var splitTracks: [NamedAudioTrack] = []
    @Published var selected = Set<UUID>()
    @Published var selectedDataFiles = Set<String>()
    @Published var expandedDataTracks = Set<Int>()
    @Published var expandedDataFolders = Set<String>()
    @Published var dataFiles: [CDDataFile] = []
    @Published var filterDataVideos = false
    @Published var filterDataAudio = false
    @Published var filterDataImages = false
    @Published var audioFormat: AudioOutputFormat = .wav
    @Published var status = "Insert a CD, then click Scan CD."
    @Published var details = ""
    @Published var progress = 0.0
    @Published var busy = false
    @Published var showCompletion = false
    @Published var completionMessage = ""
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var playingTrackID: UUID?
    @Published var playbackProgress = 0.0
    @Published var playbackElapsed = 0.0
    @Published var trackNames: [UUID: String] = [:]
    @Published var artistName = ""
    @Published var releaseTitle = ""
    @Published var metadataOptions: [CDMetadata] = []
    @Published var showMetadataChoices = false
    @Published var isDiscImage = false
    private var snapshot: DiscSnapshot?
    private var discImageURL: URL?
    private let audioPlayer = DiscAudioPlayer()
    private var playbackTimer: Timer?
    private var playbackStartedAt: Date?
    private var playbackBaseSeconds = 0.0
    private var playbackDuration = 0.0
    func toggleTrack(_ track: CDTrack) {
        if track.isAudio {
            if selected.contains(track.id) { selected.remove(track.id) }
            else { selected.insert(track.id) }
        } else {
            let ids = Set(visibleDataFiles.filter { $0.trackNumber == track.number }.map(\.id))
            if !ids.isEmpty, ids.isSubset(of: selectedDataFiles) { selectedDataFiles.subtract(ids) }
            else { selectedDataFiles.formUnion(ids) }
        }
    }

    func trackIsSelected(_ track: CDTrack) -> Bool {
        if track.isAudio { return selected.contains(track.id) }
        let ids = Set(visibleDataFiles.filter { $0.trackNumber == track.number }.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: selectedDataFiles)
    }

    func toggleDataNode(_ node: DataTreeNode) {
        let ids = node.descendantFileIDs
        if !ids.isEmpty, ids.isSubset(of: selectedDataFiles) { selectedDataFiles.subtract(ids) }
        else { selectedDataFiles.formUnion(ids) }
    }

    func dataNodeIsSelected(_ node: DataTreeNode) -> Bool {
        let ids = node.descendantFileIDs
        return !ids.isEmpty && ids.isSubset(of: selectedDataFiles)
    }

    var visibleDataFiles: [CDDataFile] {
        guard filterDataVideos || filterDataAudio || filterDataImages else { return dataFiles }
        return dataFiles.filter {
            (filterDataVideos && $0.isVideo) || (filterDataAudio && $0.isAudio) || (filterDataImages && $0.isImage)
        }
    }

    func dataTree(for track: CDTrack) -> [DataTreeNode] {
        DataTreeNode.roots(for: visibleDataFiles.filter { $0.trackNumber == track.number })
    }

    func displayName(for track: CDTrack, fallback: String) -> String {
        trackNames[track.id] ?? fallback
    }

    func setName(_ value: String, for track: CDTrack) { trackNames[track.id] = value }

    func sectionIsSelected(_ audioTracks: [CDTrack]) -> Bool {
        !audioTracks.isEmpty && Set(audioTracks.map(\.id)).isSubset(of: selected)
    }

    func selectSection(_ audioTracks: [CDTrack], _ value: Bool) {
        let ids = Set(audioTracks.map(\.id))
        if value { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    var allDataSelected: Bool {
        !visibleDataFiles.isEmpty && Set(visibleDataFiles.map(\.id)).isSubset(of: selectedDataFiles)
    }

    func selectAllData(_ value: Bool) {
        let ids = Set(visibleDataFiles.map(\.id))
        if value { selectedDataFiles.formUnion(ids) } else { selectedDataFiles.subtract(ids) }
    }

    var allSelected: Bool {
        let audioIDs = Set(([hiddenTrack].compactMap { $0 } + tracks.filter(\.isAudio) + splitTracks.map(\.track)).map(\.id))
        return (!audioIDs.isEmpty || !dataFiles.isEmpty)
            && audioIDs.isSubset(of: selected)
            && Set(dataFiles.map(\.id)).isSubset(of: selectedDataFiles)
    }

    func selectAll(_ value: Bool) {
        if value {
            selected = Set(([hiddenTrack].compactMap { $0 } + tracks.filter(\.isAudio) + splitTracks.map(\.track)).map(\.id))
            selectedDataFiles = Set(dataFiles.map(\.id))
        } else {
            selected = []
            selectedDataFiles = []
        }
    }

    func togglePlayback(_ track: CDTrack, name: String) {
        guard !busy, snapshot != nil else { return }
        if playingTrackID == track.id {
            stopPlayback(); status = "Playback stopped."
            return
        }
        startPlayback(track, name: name, fraction: 0)
    }

    func seekPlayback(_ track: CDTrack, name: String, fraction: Double) {
        guard playingTrackID == track.id else { return }
        startPlayback(track, name: name, fraction: min(1, max(0, fraction)))
    }

    private func startPlayback(_ track: CDTrack, name: String, fraction: Double) {
        guard let snapshot else { return }
        audioPlayer.stop(); playbackTimer?.invalidate()
        let offset = min(track.sectorCount - 1, max(0, Int(Double(track.sectorCount) * fraction)))
        let playbackTrack = CDTrack(id: track.id, session: track.session, number: track.number,
                                    startLBA: track.startLBA + offset, endLBA: track.endLBA,
                                    description: track.description)
        playingTrackID = track.id
        playbackDuration = Double(track.sectorCount) / 75
        playbackBaseSeconds = Double(offset) / 75
        playbackElapsed = playbackBaseSeconds
        playbackProgress = playbackDuration > 0 ? playbackBaseSeconds / playbackDuration : 0
        status = "Buffering \(name)…"
        audioPlayer.play(track: playbackTrack, device: snapshot.device) {
            self.playbackStartedAt = Date()
            self.playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                Task { @MainActor in
                    guard let started = self.playbackStartedAt else { return }
                    self.playbackElapsed = min(self.playbackDuration,
                        self.playbackBaseSeconds + Date().timeIntervalSince(started))
                    self.playbackProgress = self.playbackDuration > 0 ? self.playbackElapsed / self.playbackDuration : 0
                }
            }
            self.status = "Playing \(name)…"
        } finished: {
            self.stopPlayback(); self.status = "Playback finished."
        } failed: { error in
            self.stopPlayback(); self.fail(error)
        }
    }

    private func stopPlayback() {
        audioPlayer.stop(); playbackTimer?.invalidate(); playbackTimer = nil
        playbackStartedAt = nil; playingTrackID = nil; playbackProgress = 0; playbackElapsed = 0
    }

    func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func updateDiscDetails() {
        guard let snapshot else { details = ""; return }
        if isDiscImage {
            details = "\(snapshot.volumeName) • Disc Image"
            return
        }
        let hasData = snapshot.tracks.contains { !$0.isAudio }
        let hasHidden = snapshot.hiddenTrack != nil || splitTracks.contains { $0.name.contains("Hidden") }
        let type: String
        if hasData && hasHidden { type = "Enhanced CD with Hidden Audio Tracks" }
        else if hasData { type = "Enhanced CD" }
        else if hasHidden { type = "Audio CD with Hidden Tracks" }
        else { type = "Audio CD" }
        let identity = [artistName, releaseTitle].filter { !$0.isEmpty }.joined(separator: " - ")
        details = identity.isEmpty ? type : "\(identity) • \(type)"
    }

    private func lookupMetadata(for disc: DiscSnapshot) {
        status = "Looking up album and track names…"
        MusicBrainzLookup.fetch(for: disc) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let choices) where !choices.isEmpty:
                    self.metadataOptions = choices
                    self.showMetadataChoices = true
                    self.status = "Choose the correct MusicBrainz match, or continue without metadata."
                case .success:
                    self.updateDiscDetails()
                    self.status = disc.cdText == nil
                        ? "Disc scanned. No MusicBrainz match was found; track names remain editable."
                        : "Disc scanned. CD-Text was loaded; no MusicBrainz match was found."
                case .failure:
                    self.updateDiscDetails()
                    self.status = disc.cdText == nil
                        ? "Disc scanned. Track-name lookup was unavailable; names remain editable."
                        : "Disc scanned. CD-Text was loaded; MusicBrainz was unavailable."
                }
            }
        }
    }

    func applyMetadata(_ metadata: CDMetadata) {
        artistName = metadata.artist
        releaseTitle = metadata.release
        let audio = tracks.filter(\.isAudio)
        for (track, title) in zip(audio, metadata.trackTitles) { trackNames[track.id] = title }
        metadataOptions = []
        showMetadataChoices = false
        updateDiscDetails()
        status = "Track names loaded from MusicBrainz."
    }

    func declineMetadata() {
        metadataOptions = []
        showMetadataChoices = false
        updateDiscDetails()
        status = snapshot?.cdText == nil
            ? "Disc scanned without MusicBrainz metadata; track names remain editable."
            : "CD-Text retained; MusicBrainz metadata was not applied."
    }

    func findSplitTracks() {
        guard !busy, let snapshot else { return }
        var sources: [CDTrack] = []
        if let hiddenTrack { sources.append(hiddenTrack) }
        if let last = tracks.last(where: \.isAudio), last.sectorCount >= 75 * 60 * 8 { sources.append(last) }
        guard !sources.isEmpty else { status = "No likely hidden-track regions were found."; return }
        let cancellationTicket = OperationCancellation.shared.begin()
        audioPlayer.stop(); playingTrackID = nil
        busy = true; progress = 0; status = "Looking for tracks to separate…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let disc = try RawCDReader(device: snapshot.device)
                let suggestions = try AudioSilenceAnalyzer.suggestions(for: sources, disc: disc,
                                                                        cancellationTicket: cancellationTicket) { value in
                    DispatchQueue.main.async {
                        guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                        self.progress = value
                        self.status = "Looking for tracks to separate… \(Int(value * 100))%"
                    }
                }
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.splitTracks = suggestions
                    for item in suggestions { self.trackNames[item.id] = item.name }
                    self.updateDiscDetails()
                    self.progress = 1; self.busy = false
                    self.status = suggestions.isEmpty
                        ? "No conservative silence-based splits were found."
                        : "Found \(suggestions.count) suggested split track\(suggestions.count == 1 ? "" : "s")."
                }
            } catch {
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.fail(error)
                }
            }
        }
    }

    func stopCurrentOperation() {
        guard busy else { return }
        OperationCancellation.shared.cancel()
        stopPlayback()
        busy = false
        progress = 0
        status = "Cancelled."
    }

    func setDataFolder(_ id: String, expanded: Bool) {
        if expanded { expandedDataFolders.insert(id) }
        else { expandedDataFolders.remove(id) }
    }

    var hasSelection: Bool {
        (hiddenTrack.map { selected.contains($0.id) } ?? false)
            || tracks.contains { $0.isAudio && selected.contains($0.id) }
            || splitTracks.contains { selected.contains($0.id) }
            || !selectedDataFiles.isEmpty
    }

    func scan() {
        guard !busy else { return }
        let cancellationTicket = OperationCancellation.shared.begin()
        audioPlayer.stop(); playingTrackID = nil
        busy = true; progress = 0; status = "Reading the disc table of contents…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let disc = try DiscScanner.scan()
                try OperationCancellation.shared.check(cancellationTicket)
                var discovered: [CDDataFile] = []
                var scanWarnings: [String] = []
                if disc.tracks.contains(where: { !$0.isAudio }), let reader = try? RawCDReader(device: disc.device) {
                    for track in disc.tracks where !track.isAudio {
                        try OperationCancellation.shared.check(cancellationTicket)
                        do {
                            let iso = try ISO9660Reader(disc: reader, trackStart: track.startLBA)
                            let entries = try iso.entries()
                            discovered.append(contentsOf: entries.map {
                                CDDataFile(trackNumber: track.number, trackStart: track.startLBA, volumeName: iso.volumeName,
                                           path: $0.path, extent: $0.extent, size: $0.size)
                            })
                        } catch {
                            scanWarnings.append("Data track \(track.number): \(error.localizedDescription)")
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.discImageURL = nil
                    self.isDiscImage = false
                    self.snapshot = disc
                    self.tracks = disc.tracks
                    self.hiddenTrack = disc.hiddenTrack
                    self.splitTracks = []
                    self.trackNames = [:]
                    if let hidden = disc.hiddenTrack { self.trackNames[hidden.id] = "Hidden Track" }
                    for track in disc.tracks where track.isAudio { self.trackNames[track.id] = "Track \(track.number)" }
                    if let cdText = disc.cdText {
                        self.artistName = cdText.performer ?? ""
                        self.releaseTitle = cdText.albumTitle ?? ""
                        for track in disc.tracks where track.isAudio {
                            if let title = cdText.trackTitles[track.number] { self.trackNames[track.id] = title }
                        }
                    } else {
                        self.artistName = ""; self.releaseTitle = ""
                    }
                    self.metadataOptions = []; self.showMetadataChoices = false
                    self.selected = []
                    self.selectedDataFiles = []
                    self.filterDataVideos = false
                    self.filterDataAudio = false
                    self.filterDataImages = false
                    self.expandedDataTracks = Set(disc.tracks.filter { !$0.isAudio }.map(\.number))
                    self.dataFiles = discovered
                    self.expandedDataFolders = Set(disc.tracks.filter { !$0.isAudio }.flatMap { track in
                        self.dataTree(for: track).flatMap(\.descendantFolderIDs)
                    })
                    let audioCount = disc.tracks.filter(\.isAudio).count
                    self.status = "Found \(audioCount) audio track\(audioCount == 1 ? "" : "s")"
                        + (disc.hiddenTrack == nil ? "." : " and 1 hidden track.")
                        + (scanWarnings.isEmpty ? "" : " Warning: \(scanWarnings.joined(separator: " "))")
                    self.busy = false
                    self.updateDiscDetails()
                    self.lookupMetadata(for: disc)
                }
            } catch {
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.fail(error)
                }
            }
        }
    }

    func scanImage() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a CD image"
        panel.prompt = "Scan Image"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        let imageTypes: [UTType] = ["iso", "img"].compactMap { extensionName in
            UTType(filenameExtension: extensionName)
        }
        panel.allowedContentTypes = imageTypes
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let owner = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        let begin: (URL) -> Void = { [weak self] url in self?.loadDiscImage(url) }
        if let owner {
            panel.beginSheetModal(for: owner) { response in
                if response == .OK, let url = panel.url { begin(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            begin(url)
        }
    }

    private func loadDiscImage(_ url: URL) {
        let cancellationTicket = OperationCancellation.shared.begin()
        audioPlayer.stop(); playingTrackID = nil
        busy = true; progress = 0; status = "Reading \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let reader = try DiscImageReader(url: url)
                let iso = try ISO9660Reader(disc: reader, trackStart: 0)
                let entries = try iso.entries()
                try OperationCancellation.shared.check(cancellationTicket)
                let track = CDTrack(session: 1, number: 1, startLBA: 0,
                                    endLBA: reader.sectorCount, description: "data track")
                let disc = DiscSnapshot(device: url.path, driveName: "Disc Image",
                                        volumeName: iso.volumeName, tracks: [track],
                                        hiddenTrack: nil, cdText: nil)
                let discovered = entries.map {
                    CDDataFile(trackNumber: 1, trackStart: 0, volumeName: iso.volumeName,
                               path: $0.path, extent: $0.extent, size: $0.size)
                }
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.stopPlayback()
                    self.snapshot = disc
                    self.discImageURL = url
                    self.isDiscImage = true
                    self.tracks = [track]; self.hiddenTrack = nil; self.splitTracks = []
                    self.trackNames = [:]; self.artistName = ""; self.releaseTitle = ""
                    self.metadataOptions = []; self.showMetadataChoices = false
                    self.selected = []; self.selectedDataFiles = []
                    self.filterDataVideos = false; self.filterDataAudio = false; self.filterDataImages = false
                    self.expandedDataTracks = [1]
                    self.dataFiles = discovered
                    self.expandedDataFolders = Set(self.dataTree(for: track).flatMap(\.descendantFolderIDs))
                    self.updateDiscDetails()
                    self.progress = 1; self.busy = false
                    self.status = "Found \(discovered.count) file\(discovered.count == 1 ? "" : "s") in \(url.lastPathComponent)."
                }
            } catch {
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.fail(error)
                }
            }
        }
    }

    func extractAsIs() { extract(convertVideos: false) }
    func extractVideoAndConvert() { extract(convertVideos: true) }

    func loadVideo() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Load a video to convert"
        panel.prompt = "Load Video"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        let extensions = ["mov", "mp4", "m4v", "mpg", "mpeg", "avi", "wmv", "vob", "mkv", "webm"]
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let owner = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        let begin: (URL) -> Void = { [weak self] url in
            self?.prepareLoadedVideo(url, presentationWindow: owner)
        }
        if let owner {
            panel.beginSheetModal(for: owner) { response in
                if response == .OK, let url = panel.url { begin(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            begin(url)
        }
    }

    private func prepareLoadedVideo(_ url: URL, presentationWindow: NSWindow?) {
        let cancellationTicket = OperationCancellation.shared.begin()
        busy = true; progress = 0; status = "Analysing \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let initial = try VideoCompatibility.inspect(url)
                try OperationCancellation.shared.check(cancellationTicket)
                let probe = VideoCompatibility.detectingEmbeddedLetterbox(in: url, probe: initial)
                try OperationCancellation.shared.check(cancellationTicket)
                let request = VideoCompatibility.askUser(fileName: url.lastPathComponent,
                                                         source: url, probe: probe,
                                                         window: presentationWindow,
                                                         canSaveOriginal: false)
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    guard let request else {
                        self.busy = false; self.progress = 0; self.status = "Cancelled."
                        return
                    }
                    guard let destination = request.destination else {
                        self.busy = false; self.progress = 0; self.status = "Cancelled."
                        return
                    }
                    self.performLoadedVideoConversion(source: url, probe: probe, request: request,
                                                      destination: destination)
                }
            } catch {
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.fail(error)
                }
            }
        }
    }

    private func performLoadedVideoConversion(source: URL, probe: VideoProbe,
                                              request: VideoExtractionRequest, destination: URL) {
        let cancellationTicket = OperationCancellation.shared.begin()
        busy = true; progress = 0; status = "Preparing \(source.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var outputCount = 0
                try OperationCancellation.shared.check(cancellationTicket)
                if request.saveOriginal {
                    let target = self.uniqueFile(destination.appendingPathComponent(source.lastPathComponent))
                    try FileManager.default.copyItem(at: source, to: target)
                    outputCount += 1
                }
                let conversionCount = max(1, request.outputSizes.count)
                for (index, outputSize) in request.outputSizes.enumerated() {
                    try OperationCancellation.shared.check(cancellationTicket)
                    let suffix: String
                    switch outputSize {
                    case .source: suffix = " - H264"
                    case .dvdPAL: suffix = " - DVD PAL"
                    case .dvdNTSC: suffix = " - DVD NTSC"
                    case .hd720: suffix = " - 720p"
                    case .hd1080: suffix = " - 1080p"
                    }
                    let output = self.uniqueFile(destination
                        .appendingPathComponent(source.deletingPathExtension().lastPathComponent + suffix)
                        .appendingPathExtension("mp4"))
                    try VideoCompatibility.convertToH264(source: source, destination: output,
                        probe: probe, outputSize: outputSize,
                        aspectCorrection: request.aspectCorrection,
                        forceRec709: request.forceRec709,
                        fitToWidescreen: request.fitToWidescreen,
                        crop: request.crop, colorSettings: request.colorSettings,
                        targetFrameRate: request.targetFrameRate,
                        deinterlace: request.deinterlace, clipRange: request.clipRange) { local in
                            DispatchQueue.main.async {
                                guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                                self.progress = (Double(index) + local) / Double(conversionCount)
                                self.status = "Creating \(outputSize.label)… \(Int(local * 100))%"
                            }
                        }
                    outputCount += 1
                }
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.progress = 1; self.status = "Conversion complete."; self.busy = false
                    self.completionMessage = "Created \(outputCount) file\(outputCount == 1 ? "" : "s")."
                    self.showCompletion = true
                }
            } catch {
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.fail(error)
                }
            }
        }
    }

    var hasSelectedVideo: Bool {
        dataFiles.contains { $0.isVideo && selectedDataFiles.contains($0.id) }
    }

    func eject() {
        guard !busy, let snapshot else { return }
        if isDiscImage {
            stopPlayback()
            self.snapshot = nil; discImageURL = nil; isDiscImage = false
            tracks = []; hiddenTrack = nil; splitTracks = []; trackNames = [:]
            artistName = ""; releaseTitle = ""; metadataOptions = []; showMetadataChoices = false
            selected = []; selectedDataFiles = []; expandedDataTracks = []; expandedDataFolders = []
            dataFiles = []; details = ""; progress = 0; status = "Disc image closed."
            return
        }
        audioPlayer.stop(); playingTrackID = nil
        let cancellationTicket = OperationCancellation.shared.begin()
        busy = true; progress = 0; status = "Ejecting disc…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try CommandRunner.run("/usr/sbin/diskutil", ["eject", snapshot.device])
                try OperationCancellation.shared.check(cancellationTicket)
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.stopPlayback()
                    self.snapshot = nil; self.tracks = []; self.hiddenTrack = nil; self.splitTracks = []
                    self.trackNames = [:]; self.artistName = ""; self.releaseTitle = ""
                    self.metadataOptions = []; self.showMetadataChoices = false
                    self.selected = []; self.selectedDataFiles = []
                    self.expandedDataTracks = []; self.expandedDataFolders = []; self.dataFiles = []
                    self.details = ""; self.status = "Disc ejected."; self.busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.fail(error)
                }
            }
        }
    }

    private func extract(convertVideos: Bool) {
        guard !busy, let snapshot else { return }
        audioPlayer.stop(); playingTrackID = nil
        var audioJobs: [NamedAudioTrack] = []
        if let hiddenTrack, selected.contains(hiddenTrack.id) {
            audioJobs.append(NamedAudioTrack(track: hiddenTrack,
                name: displayName(for: hiddenTrack, fallback: "Hidden Track")))
        }
        audioJobs.append(contentsOf: tracks.filter { $0.isAudio && selected.contains($0.id) }
            .map { NamedAudioTrack(track: $0, name: displayName(for: $0, fallback: "Track \($0.number)")) })
        audioJobs.append(contentsOf: splitTracks.filter { selected.contains($0.id) }
            .map { NamedAudioTrack(track: $0.track, name: displayName(for: $0.track, fallback: $0.name)) })
        let chosenData = dataFiles.filter { selectedDataFiles.contains($0.id) }
        let outputCount = audioJobs.count + chosenData.count
        guard outputCount > 0 else { status = "Select at least one audio track or data file."; return }
        let panel = NSOpenPanel()
        let presentationWindow = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        panel.title = "Choose an extraction folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if let presentationWindow {
            panel.beginSheetModal(for: presentationWindow) { [weak self] response in
                guard response == .OK, let destination = panel.url else { return }
                self?.performExtraction(snapshot: snapshot, audioJobs: audioJobs, chosenData: chosenData,
                                        outputCount: outputCount, destination: destination,
                                        presentationWindow: presentationWindow, convertVideos: convertVideos)
            }
        } else if panel.runModal() == .OK, let destination = panel.url {
            performExtraction(snapshot: snapshot, audioJobs: audioJobs, chosenData: chosenData,
                              outputCount: outputCount, destination: destination,
                              presentationWindow: nil, convertVideos: convertVideos)
        }
    }

    private func performExtraction(snapshot: DiscSnapshot, audioJobs: [NamedAudioTrack],
                                   chosenData: [CDDataFile], outputCount: Int,
                                   destination: URL, presentationWindow: NSWindow?, convertVideos: Bool) {
        let cancellationTicket = OperationCancellation.shared.begin()
        let format = audioFormat
        let imageURL = discImageURL
        busy = true; progress = 0; status = "Opening \(snapshot.device)…"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try OperationCancellation.shared.check(cancellationTicket)
                let reader = try Self.dataReader(imageURL: imageURL, device: snapshot.device)
                let audioDisc = reader as? RawCDReader
                let root: URL
                if outputCount == 1 {
                    root = destination
                } else {
                    let requested = destination.appendingPathComponent("\(self.safeName(snapshot.volumeName)) - Extracted Files")
                    root = self.uniqueDirectory(requested)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                }
                var completedItems = 0
                var convertedVideos = 0
                var actualOutputCount = 0
                var cancelledVideoChoices = 0
                for job in audioJobs {
                    try OperationCancellation.shared.check(cancellationTicket)
                    guard let disc = audioDisc else {
                        throw ExtractorError.commandFailed("Audio tracks cannot be read from this data-only disc image.")
                    }
                    let track = job.track
                    let filename = "\(self.safeName(job.name)).\(format.fileExtension)"
                    let target = self.uniqueFile(root.appendingPathComponent(filename))
                    let base = Double(completedItems) / Double(outputCount)
                    let scale = 1.0 / Double(outputCount)
                    _ = try AudioExtractor.extract(track: track, disc: disc, to: target, format: format,
                                                   cancellationTicket: cancellationTicket) { local in
                        DispatchQueue.main.async {
                            guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                            self.progress = base + local * scale
                            self.status = "Secure-reading \(job.name)…"
                        }
                    }
                    completedItems += 1
                    actualOutputCount += 1
                }

                let dataGroups = Dictionary(grouping: chosenData, by: \.trackNumber)
                for trackNumber in dataGroups.keys.sorted() {
                    try OperationCancellation.shared.check(cancellationTicket)
                    guard let files = dataGroups[trackNumber],
                          let track = snapshot.tracks.first(where: { $0.number == trackNumber }) else { continue }
                    let iso = try ISO9660Reader(disc: reader, trackStart: track.startLBA)
                    for file in files {
                        try OperationCancellation.shared.check(cancellationTicket)
                        let base = Double(completedItems) / Double(outputCount)
                        let scale = 1.0 / Double(outputCount)
                        if file.isVideo && convertVideos {
                            let temporary = FileManager.default.temporaryDirectory
                                .appendingPathComponent("CD Explorer Video \(UUID().uuidString)")
                                .appendingPathExtension(file.fileExtension)
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            let bytes = try iso.fileData(extent: file.extent, size: file.size,
                                                         cancellationTicket: cancellationTicket) { readBytes in
                                DispatchQueue.main.async {
                                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                                    self.progress = base + (Double(readBytes) / Double(max(1, file.size))) * scale * 0.5
                                    self.status = "Extracting \(file.path.last ?? "video")…"
                                }
                            }
                            try bytes.write(to: temporary, options: .atomic)
                            DispatchQueue.main.async {
                                guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                                self.progress = base + scale * 0.52
                                self.status = "Checking \(file.path.last ?? "video")…"
                            }
                            let relativeParts = outputCount == 1 ? [file.path.last ?? "video.\(file.fileExtension)"] : file.path
                            let originalTarget = relativeParts.reduce(root) { $0.appendingPathComponent($1) }
                            try FileManager.default.createDirectory(at: originalTarget.deletingLastPathComponent(),
                                                                    withIntermediateDirectories: true)
                            if let initialProbe = try? VideoCompatibility.inspect(temporary) {
                                let probe = VideoCompatibility.detectingEmbeddedLetterbox(in: temporary, probe: initialProbe)
                                if let request = VideoCompatibility.askUser(fileName: file.path.last ?? "Video",
                                                                           source: temporary, probe: probe,
                                                                           window: presentationWindow) {
                                    if request.saveOriginal {
                                        let target = self.uniqueFile(originalTarget)
                                        try FileManager.default.copyItem(at: temporary, to: target)
                                        actualOutputCount += 1
                                    }
                                    DispatchQueue.main.async { self.progress = base + scale * 0.6 }
                                    let conversionCount = max(1, request.outputSizes.count)
                                    for (conversionIndex, outputSize) in request.outputSizes.enumerated() {
                                        try OperationCancellation.shared.check(cancellationTicket)
                                        let suffix: String
                                        switch outputSize {
                                        case .source: suffix = " - H264"
                                        case .dvdPAL: suffix = " - DVD PAL"
                                        case .dvdNTSC: suffix = " - DVD NTSC"
                                        case .hd720: suffix = " - 720p"
                                        case .hd1080: suffix = " - 1080p"
                                        }
                                        let baseName = originalTarget.deletingPathExtension().lastPathComponent + suffix
                                        let mp4Target = self.uniqueFile(originalTarget.deletingLastPathComponent()
                                            .appendingPathComponent(baseName).appendingPathExtension("mp4"))
                                        let conversionStart = 0.6 + Double(conversionIndex) * 0.4 / Double(conversionCount)
                                        let conversionScale = 0.4 / Double(conversionCount)
                                        try VideoCompatibility.convertToH264(source: temporary, destination: mp4Target,
                                                                           probe: probe, outputSize: outputSize,
                                                                           aspectCorrection: request.aspectCorrection,
                                                                           forceRec709: request.forceRec709,
                                                                           fitToWidescreen: request.fitToWidescreen,
                                                                           crop: request.crop,
                                                                           colorSettings: request.colorSettings,
                                                                           targetFrameRate: request.targetFrameRate,
                                                                           deinterlace: request.deinterlace,
                                                                           clipRange: request.clipRange) { local in
                                            DispatchQueue.main.async {
                                                guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                                                self.status = "Creating \(outputSize.label) for \(file.path.last ?? "video")… \(Int(local * 100))%"
                                                self.progress = base + scale * (conversionStart + local * conversionScale)
                                            }
                                        }
                                        convertedVideos += 1
                                        actualOutputCount += 1
                                    }
                                } else {
                                    // The user cancelled this file's options; leave it unexported.
                                    cancelledVideoChoices += 1
                                }
                            } else {
                                let target = self.uniqueFile(originalTarget)
                                try FileManager.default.moveItem(at: temporary, to: target)
                                actualOutputCount += 1
                            }
                            DispatchQueue.main.async { self.progress = base + scale }
                        } else {
                            let entry = ISOEntry(path: file.path, extent: file.extent, size: file.size)
                            _ = try iso.extract([entry], to: root, flattenSingle: outputCount == 1,
                                                cancellationTicket: cancellationTicket) { local, path in
                                DispatchQueue.main.async {
                                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                                    self.progress = base + local * scale
                                    self.status = "Extracting \(path)…"
                                }
                            }
                            actualOutputCount += 1
                        }
                        completedItems += 1
                    }
                }
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    if actualOutputCount == 0, cancelledVideoChoices > 0 {
                        self.progress = 0
                        self.status = "Cancelled."
                        self.busy = false
                        return
                    }
                    self.progress = 1
                    self.status = "Extraction complete."
                    let extracted = "Extracted \(actualOutputCount) file\(actualOutputCount == 1 ? "" : "s")."
                    var completion = extracted
                    if convertedVideos > 0 {
                        completion += "\nConverted \(convertedVideos) video\(convertedVideos == 1 ? "" : "s") to H.264."
                    }
                    if cancelledVideoChoices > 0 {
                        completion += "\nCancelled \(cancelledVideoChoices) video\(cancelledVideoChoices == 1 ? "" : "s")."
                    }
                    if !audioJobs.isEmpty { completion += "\nAudio verified." }
                    self.completionMessage = completion
                    self.showCompletion = true
                    self.busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard OperationCancellation.shared.isCurrent(cancellationTicket) else { return }
                    self.fail(error)
                }
            }
        }
    }

    private func fail(_ error: Error) {
        busy = false
        status = error.localizedDescription
        progress = 0
        errorMessage = error.localizedDescription
        showError = true
    }

    nonisolated private static func dataReader(imageURL: URL?, device: String) throws -> ISOBlockReader {
        if let imageURL { return try DiscImageReader(url: imageURL) }
        return try RawCDReader(device: device)
    }

    nonisolated private func safeName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let cleaned = value.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        return cleaned.isEmpty ? "CD" : cleaned
    }

    nonisolated private func uniqueFile(_ requested: URL) -> URL {
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let stem = requested.deletingPathExtension().lastPathComponent
        let ext = requested.pathExtension
        for number in 2...999 {
            let name = "\(stem) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = requested.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return requested.deletingLastPathComponent().appendingPathComponent("\(stem) \(UUID().uuidString).\(ext)")
    }

    nonisolated private func uniqueDirectory(_ requested: URL) -> URL {
        uniqueFile(requested)
    }
}

struct EnhancedCDView: View {
    @StateObject private var model = AppModel()

    @ViewBuilder
    private func dataRow(_ node: DataTreeNode) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.dataNodeIsSelected(node) },
                set: { _ in model.toggleDataNode(node) }
            )).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: node.file == nil ? "folder" : "doc")
                .frame(width: 22).foregroundStyle(node.file == nil ? .blue : .secondary)
            Text(node.name).lineLimit(1)
            Spacer()
            if let file = node.file {
                Text(file.sizeLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func dataTreeRows(_ nodes: [DataTreeNode]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            if let children = node.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { model.expandedDataFolders.contains(node.id) },
                    set: { model.setDataFolder(node.id, expanded: $0) }
                )) {
                    dataTreeRows(children)
                } label: {
                    dataRow(node)
                }
            } else {
                dataRow(node)
            }
        })
    }

    @ViewBuilder
    private func audioRow(_ track: CDTrack, name: String) -> some View {
        let displayedName = model.displayName(for: track, fallback: name)
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { model.trackIsSelected(track) },
                set: { _ in model.toggleTrack(track) }
            )).toggleStyle(.checkbox).labelsHidden()
            Button {
                model.togglePlayback(track, name: displayedName)
            } label: {
                Image(systemName: model.playingTrackID == track.id ? "stop.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(model.playingTrackID == track.id ? "Stop" : "Play \(displayedName)")
            .disabled(model.busy)
            Image(systemName: "waveform").frame(width: 22).foregroundStyle(.blue)
            TextField("Track title", text: Binding(
                get: { model.displayName(for: track, fallback: name) },
                set: { model.setName($0, for: track) }
            ))
            .textFieldStyle(.plain)
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .help(displayedName)
            Text(track.startLabel).monospacedDigit().frame(width: 72, alignment: .leading)
            Text(track.durationLabel).monospacedDigit().frame(width: 55, alignment: .leading)
            Group {
                if model.playingTrackID == track.id {
                    HStack(spacing: 6) {
                        Text(model.timeLabel(model.playbackElapsed))
                            .font(.caption.monospacedDigit()).foregroundStyle(.blue)
                            .frame(width: 34, alignment: .trailing)
                        Slider(value: Binding(
                            get: { model.playbackProgress },
                            set: { model.playbackProgress = $0 }
                        ), in: 0...1, onEditingChanged: { editing in
                            if !editing { model.seekPlayback(track, name: displayedName, fraction: model.playbackProgress) }
                        })
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: 160)
            Text(track.sizeLabel).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func audioSectionHeader(_ title: String, tracks: [CDTrack]) -> some View {
        HStack {
            Text(title)
            Toggle(model.sectionIsSelected(tracks) ? "Deselect All" : "Select All", isOn: Binding(
                get: { model.sectionIsSelected(tracks) },
                set: { model.selectSection(tracks, $0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(model.busy || tracks.isEmpty)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.top, 12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 42, height: 42)
                if !model.details.isEmpty {
                    Text(model.details).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Scan CD") { model.scan() }.disabled(model.busy)
                Button("Scan IMG/ISO") { model.scanImage() }.disabled(model.busy)
                Button(model.isDiscImage ? "Close Image" : "Eject") { model.eject() }
                    .disabled(model.busy || model.tracks.isEmpty)
            }

            List {
                if let hiddenTrack = model.hiddenTrack {
                    audioSectionHeader("Hidden Tracks", tracks: [hiddenTrack])
                    audioRow(hiddenTrack, name: "Hidden Track")
                }
                let ordinaryTracks = model.tracks.filter(\.isAudio)
                if !ordinaryTracks.isEmpty {
                    audioSectionHeader("Audio Tracks", tracks: ordinaryTracks)
                    ForEach(ordinaryTracks) { track in
                        audioRow(track, name: "Track \(track.number)")
                    }
                }
                if model.hiddenTrack != nil || (model.tracks.last(where: \.isAudio)?.sectorCount ?? 0) >= 75 * 60 * 8 {
                    audioSectionHeader("Separate Hidden Tracks", tracks: model.splitTracks.map(\.track))
                    Button("Analyse") {
                        model.findSplitTracks()
                    }
                    .disabled(model.busy || !model.splitTracks.isEmpty)
                    ForEach(model.splitTracks) { item in
                        audioRow(item.track, name: item.name)
                    }
                }
                if !model.dataFiles.isEmpty {
                    HStack {
                        Text("Data Files")
                        Toggle(model.allDataSelected ? "Deselect All" : "Select All", isOn: Binding(
                            get: { model.allDataSelected }, set: { model.selectAllData($0) }
                        )).toggleStyle(.checkbox).disabled(model.busy)
                        Toggle("Videos", isOn: $model.filterDataVideos)
                            .toggleStyle(.checkbox).disabled(model.busy)
                        Toggle("Audio", isOn: $model.filterDataAudio)
                            .toggleStyle(.checkbox).disabled(model.busy)
                        Toggle("Images", isOn: $model.filterDataImages)
                            .toggleStyle(.checkbox).disabled(model.busy)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    ForEach(model.tracks.filter { !$0.isAudio && !model.dataTree(for: $0).isEmpty }, id: \.number) { track in
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.expandedDataTracks.contains(track.number) },
                            set: { expanded in
                                if expanded { model.expandedDataTracks.insert(track.number) }
                                else { model.expandedDataTracks.remove(track.number) }
                            }
                        )) {
                            dataTreeRows(model.dataTree(for: track))
                        } label: {
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { model.trackIsSelected(track) },
                                    set: { _ in model.toggleTrack(track) }
                                )).toggleStyle(.checkbox).labelsHidden()
                                Label("Data Track \(track.number)", systemImage: "opticaldisc")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 235)

            if model.busy {
                ProgressView(value: model.progress).progressViewStyle(.linear)
            }
            Text(model.status).font(.callout).foregroundStyle(model.status.localizedCaseInsensitiveContains("error") ? .red : .secondary)

            HStack {
                Button("Extract As Is") { model.extractAsIs() }
                    .disabled(model.busy || !model.hasSelection)
                Button("Extract Video & Convert") { model.extractVideoAndConvert() }
                    .disabled(model.busy || !model.hasSelectedVideo)
                Button("Load Video") { model.loadVideo() }
                    .disabled(model.busy)
                Button("Stop") { model.stopCurrentOperation() }
                    .disabled(!model.busy)
                Spacer(minLength: 28)
                Picker("Audio format", selection: $model.audioFormat) {
                    ForEach(AudioOutputFormat.allCases) { format in Text(format.rawValue).tag(format) }
                }
                .frame(width: 245)
                .disabled(model.busy)
            }
            Text("Audio is read twice and compared. Inconsistent sectors are retried; an unrecoverable sector stops extraction instead of being silently replaced.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 10)
        .alert("Extraction Complete", isPresented: $model.showCompletion) {
            Button("OK", role: .cancel) { }
        } message: { Text(model.completionMessage).multilineTextAlignment(.center) }
        .alert("Extraction Error", isPresented: $model.showError) {
            Button("OK", role: .cancel) { }
        } message: { Text(model.errorMessage) }
        .sheet(isPresented: $model.showMetadataChoices) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose CD Information").font(.title2)
                Text("MusicBrainz found possible editions for this disc layout. Choose the correct one, or leave the existing editable names unchanged.")
                    .foregroundStyle(.secondary)
                List(model.metadataOptions) { option in
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.release).font(.headline)
                            if !option.artist.isEmpty { Text(option.artist) }
                            if !option.edition.isEmpty {
                                Text(option.edition).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(option.trackTitles.prefix(4).joined(separator: " • ")
                                 + (option.trackTitles.count > 4 ? "…" : ""))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Use This") { model.applyMetadata(option) }
                    }
                    .padding(.vertical, 5)
                }
                HStack {
                    Spacer()
                    Button("Don’t Use Metadata") { model.declineMetadata() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(minWidth: 620, minHeight: 430)
            .interactiveDismissDisabled()
        }
    }
}

struct ContentView: View {
    var body: some View {
        EnhancedCDView()
        .padding(14)
        .frame(minWidth: 780, idealWidth: 815, minHeight: 760, idealHeight: 1000)
    }
}

final class CDExplorerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !TESTING
@main
struct CDExplorerApp: App {
    @NSApplicationDelegateAdaptor(CDExplorerAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
            .defaultSize(width: 815, height: 1000)
            .windowResizability(.contentMinSize)
        Settings { EmptyView() }
    }
}
#endif
