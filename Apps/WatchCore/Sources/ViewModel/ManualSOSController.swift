import Combine
import Foundation

public enum ManualSOSState: Equatable, Sendable {
    case idle
    case queueing
    case queued(ManualSOSReceipt)
    case cancelling(ManualSOSReceipt)
    case cancellationQueued(ManualSOSReceipt)
    case failed(String)
}

@MainActor
public final class ManualSOSController: ObservableObject {
    @Published public private(set) var state: ManualSOSState = .idle
    private let dispatcher: any ManualSOSDispatching
    public var onQueued: ((ManualSOSReceipt) -> Void)?

    public init(dispatcher: any ManualSOSDispatching) {
        self.dispatcher = dispatcher
    }

    public func trigger() async {
        guard case .idle = state else { return }
        state = .queueing
        do {
            let receipt = try await dispatcher.queueManualSOS()
            state = .queued(receipt)
            onQueued?(receipt)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    public func cancel() async {
        guard case .queued(let original) = state else { return }
        state = .cancelling(original)
        do {
            state = .cancellationQueued(
                try await dispatcher.queueManualSOSCancellation(incidentID: original.incidentID)
            )
        } catch {
            state = .queued(original)
        }
    }

    public func resetAfterCancellation() {
        guard case .cancellationQueued = state else { return }
        state = .idle
    }

    public func resetForRun() {
        state = .idle
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Không thể xếp hàng SOS. Hãy thử lại."
    }
}
