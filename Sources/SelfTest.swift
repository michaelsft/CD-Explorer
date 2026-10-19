import Foundation

@main
struct SelfTest {
    static func main() throws {
        if (CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5), CommandLine.arguments[1] == "--video-convert" {
            let source = URL(fileURLWithPath: CommandLine.arguments[2])
            let destination = URL(fileURLWithPath: CommandLine.arguments[3])
            let inspected = try VideoCompatibility.inspect(source)
            let before = VideoCompatibility.detectingEmbeddedLetterbox(in: source, probe: inspected)
            precondition(before.needsConversion)
            let size: VideoOutputSize
            switch CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : "source" {
            case "dvd": size = before.usesPALFrameRate ? .dvdPAL : .dvdNTSC
            case "720": size = .hd720
            case "1080": size = .hd1080
            default: size = .source
            }
            try VideoCompatibility.convertToH264(source: source, destination: destination, probe: before,
                                                  outputSize: size, crop: before.detectedCrop)
            let after = try VideoCompatibility.inspect(destination)
            precondition(after.videoCodec == "h264")
            precondition(!after.needsConversion)
            let crop = before.detectedCrop.map { "\($0.width)x\($0.height)+\($0.x)+\($0.y)" } ?? "none"
            print("before=\(before.videoCodec)/\(before.audioCodec ?? "none") \(before.width)x\(before.height) crop=\(crop) after=\(after.videoCodec)/\(after.audioCodec ?? "none") \(after.width)x\(after.height)")
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--analyze-raw" {
            let source = CommandLine.arguments[2]
            let number = Int(CommandLine.arguments[3])!
            let bytes = (try FileManager.default.attributesOfItem(atPath: source)[.size] as? NSNumber)?.intValue ?? 0
            let track = CDTrack(session: 1, number: number, startLBA: 0, endLBA: bytes / 2352,
                                description: "2ch audio")
            let suggestions = try AudioSilenceAnalyzer.suggestions(for: [track], disc: RawCDReader(device: source)) { _ in }
            for item in suggestions {
                print("\(item.name)|\(item.track.startLBA)|\(item.track.endLBA)|\(item.track.durationLabel)")
            }
            return
        }
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--disc-scan" {
            let snapshot = try DiscScanner.scan()
            print("device=\(snapshot.device) tracks=\(snapshot.tracks.count) volume=\(snapshot.volumeName)")
            let disc = try RawCDReader(device: snapshot.device)
            for track in snapshot.tracks {
                print("track=\(track.number) kind=\(track.kindLabel) sectors=\(track.sectorCount)")
                if !track.isAudio {
                    let iso = try ISO9660Reader(disc: disc, trackStart: track.startLBA)
                    let entries = try iso.entries()
                    print("data-volume=\(iso.volumeName) files=\(entries.count)")
                    for entry in entries.prefix(20) { print(entry.path.joined(separator: "/")) }
                }
            }
            return
        }
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--disc-audio" {
            let trackNumber = Int(CommandLine.arguments[2])!
            guard let format = AudioOutputFormat.allCases.first(where: { $0.fileExtension == CommandLine.arguments[3] }) else {
                throw ExtractorError.commandFailed("Unknown audio format")
            }
            let destination = URL(fileURLWithPath: CommandLine.arguments[4])
            let snapshot = try DiscScanner.scan()
            let track = trackNumber == 0
                ? snapshot.hiddenTrack
                : snapshot.tracks.first(where: { $0.number == trackNumber && $0.isAudio })
            guard let track else {
                throw ExtractorError.commandFailed("Audio track not found")
            }
            let report = try AudioExtractor.extract(track: track, disc: RawCDReader(device: snapshot.device),
                                                    to: destination, format: format) { value in
                if Int(value * 100) % 10 == 0 { fputs("\r\(Int(value * 100))%", stderr) }
            }
            print("\nverified track=\(trackNumber) sectors=\(track.sectorCount) retried=\(report.retriedSectors) rereads=\(report.rereadAttempts)")
            return
        }
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--flat" {
            let source = CommandLine.arguments[2]
            let start = Int(CommandLine.arguments[3])!
            let destination = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
            let disc = try RawCDReader(device: source)
            let iso = try ISO9660Reader(disc: disc, trackStart: start)
            let entries = try iso.entries()
            _ = try iso.extract(entries, to: destination, flattenSingle: true) { _, _ in }
            return
        }
        guard CommandLine.arguments.count == 4 else {
            throw ExtractorError.invalidISO("usage: SelfTest raw-image start-lba destination")
        }
        let source = CommandLine.arguments[1]
        let start = Int(CommandLine.arguments[2])!
        let destination = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let disc = try RawCDReader(device: source)
        let iso = try ISO9660Reader(disc: disc, trackStart: start)
        var lastProgress = 0.0
        let count = try iso.extract(to: destination) { value, _ in
            precondition(value >= lastProgress && value >= 0 && value <= 1)
            lastProgress = value
        }
        precondition(lastProgress == 1)
        print("volume=\(iso.volumeName) files=\(count)")
    }
}
