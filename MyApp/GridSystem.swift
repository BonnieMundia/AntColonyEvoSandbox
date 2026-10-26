import Foundation
import Accelerate

nonisolated enum GridCell: UInt8, Sendable, CaseIterable {
    case empty
    case obstacleWall
    case spawnNest
    case foodMatrix
}

nonisolated struct GridCoordinate: Hashable, Sendable {
    let x: Int
    let y: Int

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

nonisolated struct GridDimensions: Equatable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "Grid dimensions must be positive.")
        self.width = width
        self.height = height
    }

    var cellCount: Int {
        width * height
    }

    func contains(_ coordinate: GridCoordinate) -> Bool {
        coordinate.x >= 0 && coordinate.x < width &&
        coordinate.y >= 0 && coordinate.y < height
    }

    func index(for coordinate: GridCoordinate) -> Int? {
        guard contains(coordinate) else {
            return nil
        }

        return coordinate.y * width + coordinate.x
    }
}

nonisolated struct GridTopology: Sendable {
    let dimensions: GridDimensions
    private(set) var cells: [GridCell]

    init(dimensions: GridDimensions, defaultCell: GridCell = .empty) {
        self.dimensions = dimensions
        self.cells = Array(repeating: defaultCell, count: dimensions.cellCount)
    }

    subscript(_ coordinate: GridCoordinate) -> GridCell? {
        get {
            guard let index = dimensions.index(for: coordinate) else {
                return nil
            }

            return cells[index]
        }
        set {
            guard let index = dimensions.index(for: coordinate),
                  let newValue else {
                return
            }

            cells[index] = newValue
        }
    }
}



nonisolated struct GridSample: Sendable {
    let coordinate: GridCoordinate
    let cell: GridCell
    let pheromone: Float
}

nonisolated struct PheromoneSnapshot: Equatable, Sendable {
    let dimensions: GridDimensions
    let values: [Float]
    let cells: [GridCell]
    let iteration: Int

    static func empty(dimensions: GridDimensions) -> PheromoneSnapshot {
        PheromoneSnapshot(
            dimensions: dimensions,
            values: Array(repeating: 0, count: dimensions.cellCount),
            cells: Array(repeating: .empty, count: dimensions.cellCount),
            iteration: 0
        )
    }

    func value(at coordinate: GridCoordinate) -> Float {
        guard let index = dimensions.index(for: coordinate) else {
            return 0
        }

        return values[index]
    }
}

/// Serializes all matrix mutation while retaining a contiguous Float buffer.
/// This layout is cache-friendly and maps efficiently onto Apple Silicon's
/// unified-memory bandwidth when Accelerate applies an evaporation step.
actor GridSystem {
    let dimensions: GridDimensions
    let evaporationRate: Float

    private var topology: GridTopology
    private var pheromones: [Float]
    private var iteration = 0

    init(
        width: Int = 100,
        height: Int = 100,
        evaporationRate: Float = 0.05
    ) {
        precondition((0 ... 1).contains(evaporationRate), "Evaporation rate must be between zero and one.")

        let dimensions = GridDimensions(width: width, height: height)
        self.dimensions = dimensions
        self.evaporationRate = evaporationRate
        self.topology = GridTopology(dimensions: dimensions)
        self.pheromones = Array(repeating: 0, count: dimensions.cellCount)
    }

    func setCell(_ cell: GridCell, at coordinate: GridCoordinate) {
        topology[coordinate] = cell
    }

    func cell(at coordinate: GridCoordinate) -> GridCell? {
        topology[coordinate]
    }


    func samples(at coordinates: [GridCoordinate]) -> [GridSample] {
        coordinates.compactMap { coordinate in
            guard let index = dimensions.index(for: coordinate) else {
                return nil
            }

            return GridSample(
                coordinate: coordinate,
                cell: topology.cells[index],
                pheromone: pheromones[index]
            )
        }
    }

    func deposit(_ amount: Float, at coordinate: GridCoordinate) {
        guard amount.isFinite, amount > 0,
              let index = dimensions.index(for: coordinate) else {
            return
        }

        pheromones[index] += amount
    }

    /// Applies τ(t + 1) = (1 - ρ)τ(t) to the complete pheromone matrix.
    @discardableResult
    func evaporate() -> PheromoneSnapshot {
        let retention = 1 - evaporationRate

        pheromones.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            var scalar = retention
            vDSP_vsmul(
                baseAddress,
                1,
                &scalar,
                baseAddress,
                1,
                vDSP_Length(buffer.count)
            )
        }

        iteration += 1
        return snapshot()
    }

    func reset() {
        pheromones = Array(repeating: 0, count: dimensions.cellCount)
        iteration = 0
    }

    func snapshot() -> PheromoneSnapshot {
        PheromoneSnapshot(
            dimensions: dimensions,
            values: pheromones,
            cells: topology.cells,
            iteration: iteration
        )
    }
}

nonisolated struct PheromoneEvaporationReport: Equatable, Sendable {
    let initialValue: Float
    let observedValue: Float
    let expectedValue: Float
    let iterations: Int

    var isWithinTolerance: Bool {
        abs(observedValue - expectedValue) < 0.000_001
    }
}

nonisolated enum PheromoneEvaporationVerification {
    static func run(
        on grid: GridSystem,
        coordinate: GridCoordinate,
        initialValue: Float = 1,
        iterations: Int = 100
    ) async -> PheromoneEvaporationReport {
        await grid.reset()
        await grid.deposit(initialValue, at: coordinate)

        for _ in 0 ..< iterations {
            _ = await grid.evaporate()
        }

        let snapshot = await grid.snapshot()
        let evaporationRate = grid.evaporationRate
        let expected = initialValue * powf(1 - evaporationRate, Float(iterations))

        return PheromoneEvaporationReport(
            initialValue: initialValue,
            observedValue: snapshot.value(at: coordinate),
            expectedValue: expected,
            iterations: iterations
        )
    }
}
