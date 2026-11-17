import Foundation
import NidgeKit
import NidgeMock

let usage = """
nidge-cli [--host 192.168.1.1] [--port 15740] <command> [+ <command> ...]

Commands joined with "+" share one session, which the camera seems to prefer.

  summary                      device info and storages
  handles <storage> [parent] [format]
                               raw GetObjectHandles; numbers may be hex (0x...)
  ls [--last N]                files on the card, oldest first (N newest only)
  thumb <handle|name> [dir]    save the camera's thumbnail
  get <handle|name> [dir]      download, resuming <file>.part; reconnects if cut
  hold <seconds>               keep the session open, poll every 5 s
  resize <file> <long-side-px> write a smaller copy next to the file, as the app does
  mock <dir> [port]            serve the files in <dir> as a fake camera on localhost;
                               <file>.thumb.jpg, if present, is that file's thumbnail
"""

struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func number(_ text: String) throws -> UInt32 {
    let value = text.lowercased().hasPrefix("0x") ? UInt32(text.dropFirst(2), radix: 16) : UInt32(text)
    guard let value else { throw Failure("not a number: \(text)") }
    return value
}

func hex(_ value: UInt32) -> String { "0x" + String(value, radix: 16, uppercase: true) }
func hex(_ value: UInt16) -> String { hex(UInt32(value)) }

func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

/// Runs commands against one camera connection, reconnecting when a download is cut.
@MainActor
final class Runner {
    var host = "192.168.1.1"
    var port: UInt16 = 15740
    var camera: Camera?

    func connected() async throws -> Camera {
        if let camera { return camera }
        let fresh = try await Camera.connect(host: host, port: port, guid: Camera.persistentGUID(), name: "Nidge")
        log("connected to \(fresh.session.cameraName.replacing(/\d{5,}/, with: "<digits>"))")
        camera = fresh
        return fresh
    }

    func disconnect() {
        camera?.session.cancel()
        camera = nil
    }

    func firstStorage() async throws -> UInt32 {
        // A storage ID whose low 16 bits are zero has no card (seen for the empty slot 2).
        guard let storage = try await connected().storageIDs().first(where: { $0 & 0xFFFF != 0 }) else {
            throw Failure("no card")
        }
        return storage
    }

    /// Accepts a handle or a file name; names are searched newest first.
    func resolve(_ text: String) async throws -> (handle: UInt32, info: ObjectInfo) {
        let camera = try await connected()
        if let handle = try? number(text) { return (handle, try await camera.objectInfo(handle)) }
        for handle in try await camera.fileHandles(storage: try await firstStorage()).reversed() {
            let info = try await camera.objectInfo(handle)
            if info.filename.caseInsensitiveCompare(text) == .orderedSame { return (handle, info) }
        }
        throw Failure("no file named \(text) on the card")
    }

    func run(_ args: [String]) async throws {
        guard let command = args.first else { throw Failure(usage) }
        let rest = Array(args.dropFirst())
        switch command {
        case "summary":
            let camera = try await connected()
            let info = try await camera.deviceInfo()
            print("\(info.manufacturer) \(info.model) \(info.deviceVersion)")
            print("vendor extension \(hex(info.vendorExtensionID)) \"\(info.vendorExtensionDescription)\"")
            print("operations (\(info.operations.count)): \(info.operations.map { hex($0) }.joined(separator: " "))")
            print("image formats: \(info.imageFormats.map { hex($0) }.joined(separator: " "))")
            print("storages: \(try await camera.storageIDs().map { hex($0) }.joined(separator: " "))")

        case "handles":
            guard let storage = rest.first else { throw Failure(usage) }
            let parent = rest.count > 1 ? try number(rest[1]) : 0xFFFF_FFFF
            let format = rest.count > 2 ? UInt16(truncatingIfNeeded: try number(rest[2])) : 0
            let started = Date()
            let handles = try await connected().objectHandles(storage: try number(storage), format: format, parent: parent)
            print("\(handles.count) handles in \(String(format: "%.3f", Date().timeIntervalSince(started))) s")
            print((handles.prefix(4) + (handles.count > 8 ? handles.suffix(4) : [])).map { hex($0) }.joined(separator: " "))

        case "ls":
            let camera = try await connected()
            var handles = try await camera.fileHandles(storage: try await firstStorage())
            if rest.first == "--last", rest.count > 1, let count = Int(rest[1]) { handles = handles.suffix(count) }
            let started = Date()
            for handle in handles {
                let info = try await camera.objectInfo(handle)
                print("\(hex(handle))\t\(info.filename)\t\(hex(info.format))\t\(info.size)\t\(info.captureDate)")
            }
            log("\(handles.count) objects in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")

        case "thumb":
            guard let target = rest.first else { throw Failure(usage) }
            let (handle, info) = try await resolve(target)
            let data = try await connected().thumbnail(handle)
            let url = URL(fileURLWithPath: rest.count > 1 ? rest[1] : ".").appendingPathComponent(info.filename + ".thumb.jpg")
            try data.write(to: url)
            print("\(url.path)\t\(data.count) bytes")

        case "get":
            guard let target = rest.first else { throw Failure(usage) }
            var resolved: (handle: UInt32, info: ObjectInfo)?
            var failures = 0
            while true {
                do {
                    if resolved == nil { resolved = try await resolve(target) }
                    let (handle, info) = resolved!
                    let url = URL(fileURLWithPath: rest.count > 1 ? rest[1] : ".").appendingPathComponent(info.filename)
                    let started = Date()
                    let before = (try? FileManager.default.attributesOfItem(atPath: url.path + ".part")[.size] as? Int) ?? 0
                    if before > 0 { log("resuming \(info.filename) at \(before) bytes") }
                    try await connected().download(handle, size: info.size, to: url)
                    let seconds = Date().timeIntervalSince(started)
                    let megabytes = Double(Int(info.size) - before) / 1_048_576
                    print("\(url.path)\t\(info.size) bytes\t\(String(format: "%.2f s\t%.2f MB/s", seconds, megabytes / seconds))")
                    return
                } catch let error as Failure {
                    throw error
                } catch {
                    failures += 1
                    disconnect()
                    guard failures < 10 else { throw error }
                    log("connection problem (\(error)); retry \(failures) in 2 s")
                    try await Task.sleep(for: .seconds(2))
                }
            }

        case "hold":
            guard let seconds = rest.first.flatMap(Double.init) else { throw Failure(usage) }
            let camera = try await connected()
            let started = Date()
            while Date().timeIntervalSince(started) < seconds {
                try await Task.sleep(for: .seconds(5))
                do {
                    _ = try await camera.storageIDs()
                    log("alive after \(Int(Date().timeIntervalSince(started))) s")
                } catch {
                    throw Failure("session died after \(Int(Date().timeIntervalSince(started))) s: \(error)")
                }
            }
            print("held the session for \(Int(seconds)) s")

        case "resize":
            guard rest.count == 2, let longSide = Int(rest[1]) else { throw Failure(usage) }
            print(try ImageResizer.resize(URL(fileURLWithPath: rest[0]), longSide: longSide).path)

        case "mock":
            guard let directory = rest.first else { throw Failure(usage) }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
            let files: [MockCamera.File] = try names.compactMap { name in
                let format: UInt16
                switch (name as NSString).pathExtension.uppercased() {
                case "JPG", "JPEG": format = PTPObjectFormat.jpeg
                case "HIF": format = PTPObjectFormat.nikonHEIF
                case "NEF": format = 0x3000
                default: return nil
                }
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
                let stamp = DateFormatter()
                stamp.dateFormat = "yyyyMMdd'T'HHmmss"
                return MockCamera.File(name: name, format: format, data: try Data(contentsOf: url),
                                       thumbnail: (try? Data(contentsOf: url.appendingPathExtension("thumb.jpg"))) ?? Data(),
                                       captureDate: stamp.string(from: modified))
            }
            let mock = MockCamera(files: files)
            let port = try await mock.start(port: rest.count > 1 ? UInt16(rest[1]) ?? 0 : 0)
            print("mock camera with \(files.count) files on 127.0.0.1:\(port); Ctrl-C to stop")
            try await Task.sleep(for: .seconds(86_400))

        default:
            throw Failure(usage)
        }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let runner = Runner()
while let flag = arguments.first, flag == "--host" || flag == "--port", arguments.count > 1 {
    if flag == "--host" { runner.host = arguments[1] } else { runner.port = UInt16(arguments[1]) ?? runner.port }
    arguments.removeFirst(2)
}
var status: Int32 = 0
for command in arguments.split(separator: "+", omittingEmptySubsequences: false) {
    do {
        try await runner.run(Array(command))
    } catch {
        // Keep going: later commands in the chain may still be worth running.
        log("error in \(command.joined(separator: " ")): \(error)")
        // A refused command or a usage error leaves the session usable; anything else does not.
        if case .response? = error as? PTPError {} else if !(error is Failure) { runner.disconnect() }
        status = 1
    }
}
await runner.camera?.close()
exit(status)
