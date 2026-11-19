import Foundation
import SwiftUI

struct TransferSize: Sendable {
    var bytes: UInt64 = 0
    var files = 0

    mutating func add(_ other: TransferSize) {
        bytes += other.bytes
        files += other.files
    }
}

enum TransferEvent: Sendable {
    case bytes(Int)
    case file(String)
    case finishedFile
}

/// USB callbacks update counters directly. The UI samples them at four frames per
/// second, avoiding a main-thread task for every USB packet.
final class TransferProgress: Identifiable, @unchecked Sendable {
    enum Phase { case preparing, copying, complete, failed(String) }

    struct Snapshot {
        var phase: Phase = .preparing
        var total = TransferSize()
        var bytes: UInt64 = 0
        var files = 0
        var filename = ""
        var started: TimeInterval = 0
        var samples: [(time: TimeInterval, bytes: UInt64)] = []

        var speed: Double {
            guard let first = samples.first, let last = samples.last else { return 0 }
            let elapsed = last.time - first.time
            return elapsed > 0 ? Double(last.bytes - first.bytes) / elapsed : 0
        }

        var remaining: UInt64 { total.bytes > bytes ? total.bytes - bytes : 0 }
        var fraction: Double {
            if case .complete = phase { return 1 }
            guard total.bytes > 0 else { return 0 }
            return min(1, Double(bytes) / Double(total.bytes))
        }
    }

    let id = UUID()
    let title: String
    private let lock = NSLock()
    private var state = Snapshot()

    init(title: String) { self.title = title }

    func begin(_ total: TransferSize) {
        lock.lock()
        defer { lock.unlock() }
        state.total = total
        state.phase = .copying
        state.started = ProcessInfo.processInfo.systemUptime
        state.samples = [(state.started, 0)]
    }

    func update(_ event: TransferEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard case .copying = state.phase else { return }
        switch event {
        case .bytes(let count):
            state.bytes += UInt64(max(0, count))
        case .file(let name):
            state.filename = name
        case .finishedFile:
            state.files += 1
        }
    }

    func finish(error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if case .copying = state.phase {
            state.samples.append((now, state.bytes))
        }
        state.phase = error.map { .failed($0.localizedDescription) } ?? .complete
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        if case .copying = state.phase {
            let now = ProcessInfo.processInfo.systemUptime
            if now - (state.samples.last?.time ?? 0) >= 0.2 {
                state.samples.append((now, state.bytes))
                while state.samples.count > 2 && state.samples[1].time < now - 3 {
                    state.samples.removeFirst()
                }
            }
        }
        return state
    }
}

struct TransferProgressView: View {
    let transfer: TransferProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let progress = transfer.snapshot()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(transfer.title).fontWeight(.medium)
                    Spacer()
                    Text(phaseLabel(progress)).foregroundStyle(.secondary)
                }
                switch progress.phase {
                case .preparing:
                    ProgressView().progressViewStyle(.linear)
                    Text("Counting files and calculating total size…").foregroundStyle(.secondary)
                default:
                    ProgressView(value: progress.fraction)
                        .accessibilityLabel(transfer.title)
                        .accessibilityValue("\(Int(progress.fraction * 100)) percent")
                    HStack {
                        Text("\(megabytes(progress.bytes)) of \(megabytes(progress.total.bytes)) MB")
                        Text("· \(megabytes(progress.remaining)) MB remaining")
                        Spacer()
                        Text(String(format: "%.1f MB/s", progress.speed / 1_000_000))
                            .monospacedDigit()
                    }.foregroundStyle(.secondary)
                    HStack {
                        Text("\(progress.files) of \(progress.total.files) files completed")
                        Text("· \(max(0, progress.total.files - progress.files)) remaining")
                        if !progress.filename.isEmpty {
                            Text("· \(progress.filename)").lineLimit(1).truncationMode(.middle)
                        }
                    }.foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000)
    }

    private func phaseLabel(_ progress: TransferProgress.Snapshot) -> String {
        switch progress.phase {
        case .preparing: "Preparing"
        case .copying: "\(Int(progress.fraction * 100))%"
        case .complete: "Completed"
        case .failed(let message): "Failed · \(message)"
        }
    }
}
