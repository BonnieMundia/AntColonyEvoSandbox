import Combine
import Foundation

/// Main-actor bridge between the isolated simulation matrix and SwiftUI.
/// Combine provides the paced update stream; the actor owns every matrix write.
@MainActor
final class PheromoneEvaporationController: ObservableObject {
    @Published private(set) var snapshot: PheromoneSnapshot
    @Published private(set) var isRunning = false
    @Published private(set) var verificationReport: PheromoneEvaporationReport?

    let dimensions: GridDimensions

    private let grid: GridSystem
    private var timerSubscription: AnyCancellable?
    private var pendingTick: Task<Void, Never>?

    init(width: Int = 100, height: Int = 100, evaporationRate: Float = 0.05) {
        let dimensions = GridDimensions(width: width, height: height)
        self.dimensions = dimensions
        self.grid = GridSystem(
            width: width,
            height: height,
            evaporationRate: evaporationRate
        )
        self.snapshot = .empty(dimensions: dimensions)
    }

    func start() {
        guard !isRunning else {
            return
        }

        isRunning = true
        timerSubscription = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.requestEvaporationTick()
            }
    }

    func stop() {
        isRunning = false
        timerSubscription?.cancel()
        timerSubscription = nil
    }

    func seedPheromone(at coordinate: GridCoordinate, amount: Float = 1) {
        Task { [weak self] in
            guard let self else {
                return
            }

            await grid.deposit(amount, at: coordinate)
            snapshot = await grid.snapshot()
        }
    }

    func runOneHundredIterationVerification() {
        stop()
        pendingTick?.cancel()

        let verificationCoordinate = GridCoordinate(
            x: dimensions.width / 2,
            y: dimensions.height / 2
        )

        pendingTick = Task { [weak self] in
            guard let self else {
                return
            }

            let report = await PheromoneEvaporationVerification.run(
                on: grid,
                coordinate: verificationCoordinate
            )

            guard !Task.isCancelled else {
                return
            }

            snapshot = await grid.snapshot()
            verificationReport = report
            pendingTick = nil
        }
    }

    private func requestEvaporationTick() {
        guard pendingTick == nil else {
            return
        }

        pendingTick = Task { [weak self] in
            guard let self else {
                return
            }

            snapshot = await grid.evaporate()
            pendingTick = nil
        }
    }

    deinit {
        timerSubscription?.cancel()
        pendingTick?.cancel()
    }
}
