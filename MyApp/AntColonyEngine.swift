import Foundation

nonisolated enum AntState: Sendable, Equatable {
    case searchingForFood
    case returningToNest
    case dead
}

nonisolated struct AntChromosome: Sendable, Equatable {
    var alpha: Float
    var beta: Float
    var visionRadius: Int
    var stepVelocity: Float
    var maximumLifespan: Int

    static let baseline = AntChromosome(
        alpha: 1.2,
        beta: 5.0,
        visionRadius: 1,
        stepVelocity: 1,
        maximumLifespan: 500
    )
}

nonisolated struct AntAgent: Sendable, Equatable, Identifiable {
    let id: Int
    var coordinate: GridCoordinate
    var state: AntState
    var pathMemory: [GridCoordinate]
    var lifespan: Int
    var collectedFood: Int
    let chromosome: AntChromosome

    init(id: Int, at coordinate: GridCoordinate, chromosome: AntChromosome) {
        self.id = id
        self.coordinate = coordinate
        self.state = .searchingForFood
        self.pathMemory = [coordinate]
        self.lifespan = 0
        self.collectedFood = 0
        self.chromosome = chromosome
    }
}

nonisolated struct AntColonySnapshot: Sendable, Equatable {
    let ants: [AntAgent]
    let totalFoodCollected: Int
    let completedTrips: Int
    let totalCompletedPathLength: Float
    let tick: Int
}

nonisolated struct AntBehaviorVerificationReport: Sendable, Equatable {
    let uniqueExplorationCells: Int
    let foodCollected: Int
    let returningAnts: Int

    var passed: Bool {
        uniqueExplorationCells > 1 && foodCollected > 0
    }
}

/// A deterministic, low-overhead PRNG makes steering tests repeatable.
nonisolated struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func unitFloat() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}

/// Owns ant state independently of the grid actor. Each advance call evaluates
/// adjacent samples using the ACO probability rule before mutating an agent.
actor AntColonyEngine {
    private let grid: GridSystem
    private let nest: GridCoordinate
    private let food: GridCoordinate
    private let memoryCapacity: Int
    private var random: SplitMix64
    private var ants: [AntAgent]
    private var totalFoodCollected = 0
    private var completedTrips = 0
    private var totalCompletedPathLength: Float = 0
    private var tick = 0

    init(
        grid: GridSystem,
        nest: GridCoordinate,
        food: GridCoordinate,
        population: Int,
        chromosome: AntChromosome = .baseline,
        memoryCapacity: Int = 512,
        randomSeed: UInt64 = 0xAC0_2026
    ) {
        precondition(population > 0, "Population must be positive.")
        self.grid = grid
        self.nest = nest
        self.food = food
        self.memoryCapacity = memoryCapacity
        self.random = SplitMix64(seed: randomSeed)
        self.ants = (0 ..< population).map {
            AntAgent(id: $0, at: nest, chromosome: chromosome)
        }
    }

    func configureTopology() async {
        await grid.setCell(.spawnNest, at: nest)
        await grid.setCell(.foodMatrix, at: food)
    }

    func advance() async -> AntColonySnapshot {
        for index in ants.indices {
            await advanceAnt(at: index)
        }

        tick += 1
        return snapshot()
    }

    func snapshot() -> AntColonySnapshot {
        AntColonySnapshot(
            ants: ants,
            totalFoodCollected: totalFoodCollected,
            completedTrips: completedTrips,
            totalCompletedPathLength: totalCompletedPathLength,
            tick: tick
        )
    }

    private func advanceAnt(at index: Int) async {
        let speed = max(1, Int(ants[index].chromosome.stepVelocity.rounded()))

        for _ in 0 ..< speed {
            guard ants[index].state != .dead else {
                return
            }

            ants[index].lifespan += 1
            if ants[index].lifespan > ants[index].chromosome.maximumLifespan {
                ants[index].state = .dead
                return
            }

            switch ants[index].state {
            case .searchingForFood:
                await searchForFood(at: index)
            case .returningToNest:
                await returnToNest(at: index)
            case .dead:
                return
            }
        }
    }

    private func searchForFood(at index: Int) async {
        let current = ants[index].coordinate
        let candidates = neighboringCoordinates(
            around: current,
            radius: ants[index].chromosome.visionRadius
        )
        let samples = await grid.samples(at: candidates)
            .filter { $0.cell != .obstacleWall }

        guard let next = selectCandidate(
            from: samples,
            target: food,
            chromosome: ants[index].chromosome,
            excluding: ants[index].pathMemory
        ) else {
            ants[index].state = .dead
            return
        }

        ants[index].coordinate = next
        ants[index].pathMemory.append(next)
        trimMemory(at: index)

        if next == food {
            ants[index].state = .returningToNest
        }
    }

    private func returnToNest(at index: Int) async {
        let trailStrength = 1 / Float(max(1, ants[index].pathMemory.count))
        await grid.deposit(trailStrength, at: ants[index].coordinate)

        if ants[index].coordinate == nest {
            let roundTripLength = Float(max(0, ants[index].pathMemory.count - 1) * 2)
            ants[index].collectedFood += 1
            totalFoodCollected += 1
            completedTrips += 1
            totalCompletedPathLength += roundTripLength
            ants[index].state = .searchingForFood
            ants[index].pathMemory = [nest]
            return
        }

        if ants[index].pathMemory.count > 1 {
            ants[index].pathMemory.removeLast()
            ants[index].coordinate = ants[index].pathMemory.last ?? nest
        } else {
            ants[index].coordinate = nest
        }
    }

    private func selectCandidate(
        from samples: [GridSample],
        target: GridCoordinate,
        chromosome: AntChromosome,
        excluding memory: [GridCoordinate]
    ) -> GridCoordinate? {
        let unvisited = samples.filter { !memory.contains($0.coordinate) }
        let candidates = unvisited.isEmpty ? samples : unvisited

        let weighted = candidates.map { sample -> (GridCoordinate, Float) in
            let trail = max(sample.pheromone, 0.000_1)
            let distance = max(1, euclideanDistance(sample.coordinate, target))
            let visibility = 1 / distance
            let weight = powf(trail, chromosome.alpha) * powf(visibility, chromosome.beta)
            return (sample.coordinate, weight.isFinite ? weight : 0)
        }

        let totalWeight = weighted.reduce(0) { $0 + $1.1 }
        guard totalWeight > 0 else {
            return weighted.randomElement(using: &random)?.0
        }

        let threshold = random.unitFloat() * totalWeight
        var accumulated: Float = 0

        for (coordinate, weight) in weighted {
            accumulated += weight
            if accumulated >= threshold {
                return coordinate
            }
        }

        return weighted.last?.0
    }

    private func neighboringCoordinates(
        around origin: GridCoordinate,
        radius: Int
    ) -> [GridCoordinate] {
        let effectiveRadius = max(1, radius)
        var coordinates: [GridCoordinate] = []
        coordinates.reserveCapacity((effectiveRadius * 2 + 1) * (effectiveRadius * 2 + 1) - 1)

        for yOffset in -effectiveRadius ... effectiveRadius {
            for xOffset in -effectiveRadius ... effectiveRadius
            where xOffset != 0 || yOffset != 0 {
                coordinates.append(
                    GridCoordinate(x: origin.x + xOffset, y: origin.y + yOffset)
                )
            }
        }

        return coordinates
    }

    private func trimMemory(at index: Int) {
        let overflow = ants[index].pathMemory.count - memoryCapacity
        guard overflow > 0 else {
            return
        }

        ants[index].pathMemory.removeFirst(overflow)
    }

    private func euclideanDistance(
        _ source: GridCoordinate,
        _ destination: GridCoordinate
    ) -> Float {
        let deltaX = Float(destination.x - source.x)
        let deltaY = Float(destination.y - source.y)
        return sqrtf(deltaX * deltaX + deltaY * deltaY)
    }
}

nonisolated enum AntBehaviorVerification {
    static func run() async -> AntBehaviorVerificationReport {
        let grid = GridSystem(width: 25, height: 25, evaporationRate: 0.05)
        let nest = GridCoordinate(x: 3, y: 12)
        let food = GridCoordinate(x: 21, y: 12)
        let colony = AntColonyEngine(
            grid: grid,
            nest: nest,
            food: food,
            population: 24,
            chromosome: .baseline,
            randomSeed: 42
        )

        await colony.configureTopology()

        for _ in 0 ..< 80 {
            _ = await colony.advance()
        }

        let finalSnapshot = await colony.snapshot()
        return AntBehaviorVerificationReport(
            uniqueExplorationCells: Set(finalSnapshot.ants.map(\.coordinate)).count,
            foodCollected: finalSnapshot.totalFoodCollected,
            returningAnts: finalSnapshot.ants.filter {
                $0.state == .returningToNest
            }.count
        )
    }
}
