import Foundation

/// Debug-build timing of list work against the targets in design.md §8.2. Writes to stderr.
enum Perf {
    @discardableResult
    static func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        #if DEBUG || PERF_LOG
        let start = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
            FileHandle.standardError.write(Data(String(format: "[perf] %@: %.1f ms\n", label, ms).utf8))
        }
        #endif
        return try work()
    }
}
