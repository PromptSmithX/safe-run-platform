import Foundation

public actor PhoneRecoveryCoordinator {
    private let reconciler: PhoneSessionReconciler
    private let worker: GatewayUploadWorker
    private var running = false
    private var rerunRequested = false

    public init(reconciler: PhoneSessionReconciler, worker: GatewayUploadWorker) {
        self.reconciler = reconciler; self.worker = worker
    }

    public func wake() async {
        if running { rerunRequested = true; return }
        running = true
        repeat {
            rerunRequested = false
            try? await reconciler.reconcile()
            await worker.trigger()
        } while rerunRequested
        running = false
    }
}
