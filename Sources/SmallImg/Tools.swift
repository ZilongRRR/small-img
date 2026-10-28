import Foundation

enum Tool: String, CaseIterable {
    case pngquant, jpegoptim, gifsicle, gifski, gs, cjxl, djxl, avifenc, cwebp, ffmpeg, ffprobe

    var brewPackage: String {
        switch self {
        case .gs: return "ghostscript"
        case .cjxl, .djxl: return "jpeg-xl"
        case .avifenc: return "libavif"
        case .cwebp: return "webp"
        case .ffprobe: return "ffmpeg"
        default: return rawValue
        }
    }
}

enum ToolError: LocalizedError {
    case missing(Tool)
    case failed(String, Int32, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missing(let t): return "找不到 \(t.rawValue)，請執行 brew install \(t.brewPackage)"
        case .failed(let name, let code, let err):
            let tail = err.split(separator: "\n").suffix(3).joined(separator: " ")
            return "\(name) 失敗（\(code)）：\(tail)"
        case .message(let m): return m
        }
    }
}

enum Tools {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func path(_ tool: Tool) -> String? {
        for dir in searchDirs {
            let p = "\(dir)/\(tool.rawValue)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var missing: [Tool] { Tool.allCases.filter { path($0) == nil } }
}

struct ProcResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// 執行緒安全的輸出收集器，可逐行回呼。
private final class OutputCollector {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        var lines: [String] = []
        if onLine != nil {
            pending.append(chunk)
            while let idx = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<idx]
                lines.append(String(decoding: line, as: UTF8.self))
                pending.removeSubrange(pending.startIndex...idx)
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

@discardableResult
func runTool(
    _ tool: Tool,
    _ args: [String],
    allowed: Set<Int32> = [0],
    onLine: ((String) -> Void)? = nil
) async throws -> ProcResult {
    guard let exe = Tools.path(tool) else { throw ToolError.missing(tool) }
    let result = try await runProcess(exe, args, onLine: onLine)
    if !allowed.contains(result.status) {
        throw ToolError.failed(tool.rawValue, result.status, result.stderr)
    }
    return result
}

func runProcess(_ exe: String, _ args: [String], env: [String: String]? = nil, onLine: ((String) -> Void)? = nil) async throws -> ProcResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    p.standardInput = FileHandle.nullDevice
    let out = OutputCollector(onLine: onLine)
    let err = OutputCollector(onLine: nil)
    outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
    errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

    let status: Int32 = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    } onCancel: {
        if p.isRunning { p.terminate() }
    }
    if Task.isCancelled { throw CancellationError() }
    return ProcResult(status: status, stdout: out.string, stderr: err.string)
}

/// 限制同時執行的工作數量。
actor Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ n: Int) { available = n }

    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }

    nonisolated func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let r = try await body()
            await release()
            return r
        } catch {
            await release()
            throw error
        }
    }
}
