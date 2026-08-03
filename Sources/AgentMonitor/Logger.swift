import Foundation
import ApplicationServices
import CoreGraphics

/// A comprehensive logging system for AgentMonitor.
///
/// Writes log entries to `~/Library/Logs/AgentMonitor/AgentMonitor.log`
/// and also mirrors output to stdout for debugging convenience.
/// The log file is automatically rotated (renamed to `.old`) when it
/// exceeds 5 MB.
final class Logger {

    // MARK: - Singleton

    static let shared = Logger()

    // MARK: - Log Levels

    enum Level: Int, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        var label: String {
            switch self {
            case .debug:   return "DEBUG"
            case .info:    return "INFO"
            case .warning: return "WARN"
            case .error:   return "ERROR"
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Constants

    private static let appName = "AgentMonitor"
    private static let appVersion = "1.0.0"
    private static let maxFileSize: UInt64 = 5 * 1024 * 1024 // 5 MB

    // MARK: - Properties

    private let queue = DispatchQueue(label: "cn.qwenwork.AgentMonitor.Logger", qos: .utility)
    private var fileHandle: FileHandle?
    private let logURL: URL
    private let oldLogURL: URL
    private let logDirURL: URL

    // MARK: - Initialization

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        logDirURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AgentMonitor", isDirectory: true)

        logURL = logDirURL.appendingPathComponent("AgentMonitor.log")
        oldLogURL = logDirURL.appendingPathComponent("AgentMonitor.log.old")

        createLogDirectoryIfNeeded()
        openLogFile()
    }

    // MARK: - Setup

    private func createLogDirectoryIfNeeded() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDirURL.path) {
            do {
                try fm.createDirectory(at: logDirURL,
                                       withIntermediateDirectories: true)
            } catch {
                print("[Logger] Failed to create log directory: \(error)")
            }
        }
    }

    private func openLogFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            // Create an empty file so we can obtain a handle for appending.
            fm.createFile(atPath: logURL.path, contents: nil, attributes: nil)
        }

        guard let handle = FileHandle(forWritingAtPath: logURL.path) else {
            print("[Logger] Failed to open log file handle at \(logURL.path)")
            return
        }

        // Seek to end so we append rather than overwrite.
        do {
            try handle.seekToEnd()
        } catch {
            // seekToEnd() throwing is not fatal; continue from current offset.
            print("[Logger] seekToEnd failed: \(error)")
        }

        self.fileHandle = handle
    }

    private func rotateLogFileIfNeeded() {
        guard let handle = fileHandle else { return }

        let offset: UInt64
        do {
            offset = try handle.offset()
        } catch {
            return
        }

        guard offset > Logger.maxFileSize else { return }

        // Close current handle, move file to .old, start fresh.
        try? handle.close()

        let fm = FileManager.default
        if fm.fileExists(atPath: oldLogURL.path) {
            try? fm.removeItem(at: oldLogURL)
        }
        do {
            try fm.moveItem(at: logURL, to: oldLogURL)
        } catch {
            print("[Logger] Failed to rotate log file: \(error)")
        }

        // Create fresh file and reopen.
        fm.createFile(atPath: logURL.path, contents: nil, attributes: nil)
        self.fileHandle = FileHandle(forWritingAtPath: logURL.path)
    }

    // MARK: - Core Logging

    func log(_ level: Level, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level.label)] \(message)\n"
        let data = line.data(using: .utf8) ?? Data()

        // Mirror to stdout.
        print(line, terminator: "")

        // Persist to file on serial queue.
        queue.async { [weak self] in
            guard let self = self else { return }
            self.rotateLogFileIfNeeded()
            guard let handle = self.fileHandle else { return }
            do {
                // Use the throwing API: the legacy `write(_:)` raises an
                // NSFileHandleOperationException when the underlying file was
                // deleted/moved/rotated underneath us, and an uncaught NSException
                // aborts the whole app. The throwing variant surfaces the same
                // failure as a Swift error we can recover from.
                try handle.write(contentsOf: data)
                try? handle.synchronize()
            } catch {
                // Stale handle (file replaced externally). Reopen once; if that
                // fails too, drop file logging — never crash the app over logs.
                self.reopenAfterWriteFailure()
                if let fresh = self.fileHandle {
                    try? fresh.write(contentsOf: data)
                }
            }
        }
    }

    /// Best-effort recovery for a stale log file handle: close the broken
    /// handle and reopen the log file from scratch. Runs on the logger queue.
    private func reopenAfterWriteFailure() {
        try? fileHandle?.close()
        fileHandle = nil
        openLogFile()
    }

    // MARK: - Convenience

    func logDebug(_ message: String)   { log(.debug, message) }
    func logInfo(_ message: String)    { log(.info, message) }
    func logWarning(_ message: String) { log(.warning, message) }
    func logError(_ message: String)   { log(.error, message) }

    // MARK: - Startup Diagnostics

    /// Logs a banner of useful diagnostic information at application startup.
    func logStartupDiagnostics(accessibilityGranted: Bool,
                               screenRecordingGranted: Bool) {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        logInfo("==================================================")
        logInfo("AgentMonitor v\(Logger.appVersion) starting up")
        logInfo("OS: \(osString)")
        logInfo("Accessibility permission: \(accessibilityGranted ? "granted" : "NOT granted")")
        logInfo("Screen recording permission: \(screenRecordingGranted ? "granted" : "NOT granted")")
        logInfo("Log file: \(logURL.path)")
        logInfo("==================================================")
    }

    // MARK: - Diagnostics

    /// Returns a compact diagnostics summary suitable for copying to the clipboard.
    func copyDiagnostics() -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let timestamp = ISO8601DateFormatter().string(from: Date())

        var lines: [String] = []
        lines.append("AgentMonitor Diagnostics")
        lines.append("Generated: \(timestamp)")
        lines.append("Version: \(Logger.appVersion)")
        lines.append("OS: \(osString)")
        lines.append("Accessibility: \(PermissionManager.shared.currentAccessibilityState)")
        lines.append("Screen Recording: \(PermissionManager.shared.currentScreenRecordingState)")
        lines.append("Log file: \(logURL.path)")

        // Append the last ~200 lines of the log file for context.
        if let data = try? Data(contentsOf: logURL),
           let fullText = String(data: data, encoding: .utf8) {
            let allLines = fullText.components(separatedBy: "\n")
            let tailCount = min(200, allLines.count)
            let tail = allLines.suffix(tailCount)
            lines.append("")
            lines.append("--- Last \(tailCount) log lines ---")
            lines.append(contentsOf: tail)
        }

        return lines.joined(separator: "\n")
    }
}
