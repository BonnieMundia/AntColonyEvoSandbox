import Combine
import Foundation

@MainActor
final class DashboardSimulationController: ObservableObject {
    @Published private(set) var gridSnapshot: PheromoneSnapshot
    @Published private(set) var ants: [AntAgent] = []
    @Published private(set) var history: [GenerationSummary] = []
    @Published private(set) var isRunning = false

    @Published var mutationRate: Double = 0.12
    @Published var evaporationRate: Double = 0.04
    @Published var populationLimit: Double = 48

    let dimensions = GridDimensions(width: 100, height: 100)

    private var grid: GridSystem?
    private var colony: AntColonyEngine?
    private var evolution: EvolutionManager?
    private var timer: AnyCancellable?
    private var pendingTick: Task<Void, Never>?
    private var pendingEvolution: Task<Void, Never>?
    private var tickCount = 0
    private var obstacleCoordinates: Set<GridCoordinate> = []

    init() {
        gridSnapshot = .empty(dimensions: GridDimensions(width: 100, height: 100))
        restart()
    }

    func start() {
        guard !isRunning else {
            return
        }

        isRunning = true
        timer = Timer.publish(every: 1.0 / 24.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.requestTick()
            }
    }

    func pause() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    func restart() {
        pause()
        pendingTick?.cancel()
        pendingEvolution?.cancel()
        tickCount = 0
        history = []

        let grid = GridSystem(
            width: dimensions.width,
            height: dimensions.height,
            evaporationRate: Float(evaporationRate)
        )
        let nest = GridCoordinate(x: 8, y: dimensions.height / 2)
        let food = GridCoordinate(x: dimensions.width - 9, y: dimensions.height / 2)
        let colony = AntColonyEngine(
            grid: grid,
            nest: nest,
            food: food,
            population: Int(populationLimit.rounded()),
            chromosome: .baseline
        )
        let configuration = EvolutionConfiguration(
            populationSize: 8,
            antsPerColony: max(8, Int(populationLimit.rounded() / 2)),
            epochTicks: 80,
            tournamentSize: 3,
            mutationRate: Float(mutationRate),
            mutationStandardDeviation: 0.18
        )

        self.grid = grid
        self.colony = colony
        evolution = EvolutionManager(configuration: configuration)

        Task { [weak self] in
            guard let self else {
                return
            }

            await colony.configureTopology()
            for obstacle in obstacleCoordinates {
                await grid.setCell(.obstacleWall, at: obstacle)
            }

            gridSnapshot = await grid.snapshot()
            ants = (await colony.snapshot()).ants
        }
    }

    func toggleObstacle(at coordinate: GridCoordinate) {
        guard dimensions.contains(coordinate),
              coordinate.x > 10,
              coordinate.x < dimensions.width - 10 else {
            return
        }

        if obstacleCoordinates.contains(coordinate) {
            obstacleCoordinates.remove(coordinate)
        } else {
            obstacleCoordinates.insert(coordinate)
        }

        restart()
    }

    private func requestTick() {
        guard pendingTick == nil,
              let grid,
              let colony else {
            return
        }

        pendingTick = Task { [weak self] in
            guard let self else {
                return
            }

            _ = await colony.advance()
            gridSnapshot = await grid.evaporate()
            ants = (await colony.snapshot()).ants
            tickCount += 1
            pendingTick = nil

            if tickCount.isMultiple(of: 120) {
                requestEvolution()
            }
        }
    }

    private func requestEvolution() {
        guard pendingEvolution == nil,
              let evolution else {
            return
        }

        pendingEvolution = Task { [weak self] in
            guard let self else {
                return
            }

            _ = await evolution.runGeneration()
            history = await evolution.latestHistory()
            pendingEvolution = nil
        }
    }

    deinit {
        timer?.cancel()
        pendingTick?.cancel()
        pendingEvolution?.cancel()
    }
}
