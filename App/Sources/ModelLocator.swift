import Foundation
import os

/// Finds the GGUF on this device and decides whether it's safe to load.
enum ModelLocator {
    static let fileName = "Qwen3.5-4B-Q4_K_M.gguf"
    /// Weights (2.74 GB) + KV/state + compute buffers, with some headroom.
    static let requiredMemory: UInt64 = 3_600_000_000

    enum Problem: Error, LocalizedError {
        case notFound
        case insufficientMemory(available: UInt64)

        var errorDescription: String? {
            switch self {
            case .notFound:
                "Dee's brain (\(ModelLocator.fileName)) isn't on this device yet."
            case .insufficientMemory(let a):
                "This device only has \(ByteCountFormatter.string(fromByteCount: Int64(a), countStyle: .memory)) available for Dee's brain; it needs about \(ByteCountFormatter.string(fromByteCount: Int64(ModelLocator.requiredMemory), countStyle: .memory)). An iPhone with 8 GB of RAM or more is required."
            }
        }
    }

    /// Search order: app bundle, then Documents (handy for side-loading via Finder).
    static func locate() -> URL? {
        if let bundled = Bundle.main.url(forResource: fileName, withExtension: nil) { return bundled }
        let docs = URL.documentsDirectory.appending(path: fileName)
        if FileManager.default.fileExists(atPath: docs.path(percentEncoded: false)) { return docs }
        return nil
    }

    /// Memory the OS will still let this process allocate (iOS); nil where unknown.
    static func availableMemory() -> UInt64? {
        #if os(iOS) && !targetEnvironment(simulator)
        UInt64(os_proc_available_memory())
        #else
        nil
        #endif
    }

    static func checkMemory() throws {
        if let available = availableMemory(), available < requiredMemory {
            throw Problem.insufficientMemory(available: available)
        }
    }
}
