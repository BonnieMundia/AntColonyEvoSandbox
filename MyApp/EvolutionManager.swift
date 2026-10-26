import Foundation

nonisolated struct EvolutionConfiguration: Sendable, Equatable {
    var populationSize: Int
    var antsPerColony: Int
    var epochTicks: Int
    var tournamentSize: Int
    var mutationRate: Float
    var mutationStandardDeviation: Float

    static let baseline = EvolutionConfiguration(
        populationSize: 12,
        antsPerColony: 32,
        epochTicks: 120,
        tournamentSize: 3,
        mutationRate: 0.12,
        mutationStandardDeviation: 0.18
    )
}

nonisolated struct EvolutionGenome: Sendable, Equatable {
    var chromosome: AntChromosome

    static func random(using random: inout SplitMix64) -> EvolutionGenome {
        EvolutionGenome(
            chromosome: AntChromosome(
                alpha: 0.5 + random.unitFloat() * 3,
                beta: 1 + random.unitFloat() * 7,
                visionRadius: Int(1 + random.next() % 3),
                stepVelocity: 1,
                maximumLifespan: Int(250 + random.next() % 351)
            )
        )
    }
}

nonisolated struct CandidateEvaluation: Sendable, Equatable {
    let genome: EvolutionGenome
    let fitness: Float
    let foodCollected: Int
    let averagePathLength: Float
    let theoreticalShortestPath: Float
}

nonisolated struct GenerationSummary: Sendable, Equatable {
    let generation: Int
    let bestFitness: Float
    let averageFitness: Float
    let totalFoodCollected: Int
    let averagePathLength: Float
    let theoreticalShortestPath: Float
}

nonisolated struct EvolutionBenchmarkReport: Sendable, Equatable {
    let configuredAnts: Int
    let populationSize: Int
    let epochTicks: Int
    let elapsed: Duration

    var milliseconds: Double {
        Double(elapsed.components.seconds) * 1_000 +
        Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
    }
}

/// Evolves ant behavior profiles. Independent colony evaluations run as child
/// tasks, so a generation never blocks the SwiftUI main actor.
actor EvolutionManager {
    private var configuration: EvolutionConfiguration
    private var genomes: [EvolutionGenome]
    private var generation = 0
    private var history: [GenerationSummary] = []
    private var random: SplitMix64

    init(
        configuration: EvolutionConfiguration = .baseline,
        seed: UInt64 = 0xE70_2026
    ) {
        precondition(configuration.populationSize >= 2, "At least two genomes are required.")
        precondition(configuration.tournamentSize > 0, "Tournament size must be positive.")

        self.configuration = configuration
        self.random = SplitMix64(seed: seed)

        var initializationRandom = SplitMix64(seed: seed)
        self.genomes = (0 ..< configuration.populationSize).map { _ in
            EvolutionGenome.random(using: &initializationRandom)
        }
    }

    func updateConfiguration(_ configuration: EvolutionConfiguration) {
        self.configuration = configuration
    }

    func latestHistory() -> [GenerationSummary] {
        history
    }

    func runGeneration() async -> GenerationSummary {
        let evaluationConfiguration = configuration
        let generationSeed = random.next()
        let candidates = genomes

        let evaluations = await withTaskGroup(
            of: CandidateEvaluation.self,
            returning: [CandidateEvaluation].self
        ) { group in
            for (index, genome) in candidates.enumerated() {
                group.addTask {
                    await Self.evaluate(
                        genome: genome,
                        configuration: evaluationConfiguration,
                        seed: generationSeed &+ UInt64(index)
                    )
                }
            }

            var results: [CandidateEvaluation] = []
            results.reserveCapacity(candidates.count)

            for await result in group {
                results.append(result)
            }

            return results
        }

        let ordered = evaluations.sorted { $0.fitness > $1.fitness }
        let summary = Self.makeSummary(generation: generation, evaluations: ordered)
        history.append(summary)
        genomes = breedNextGeneration(from: ordered)
        generation += 1

        return summary
    }

    private nonisolated static func evaluate(
        genome: EvolutionGenome,
        configuration: EvolutionConfiguration,
        seed: UInt64
    ) async -> CandidateEvaluation {
        let grid = GridSystem(width: 40, height: 40, evaporationRate: 0.04)
        let nest = GridCoordinate(x: 4, y: 20)
        let food = GridCoordinate(x: 35, y: 20)
        let colony = AntColonyEngine(
            grid: grid,
            nest: nest,
            food: food,
            population: configuration.antsPerColony,
            chromosome: genome.chromosome,
            randomSeed: seed
        )

        await colony.configureTopology()

        for _ in 0 ..< configuration.epochTicks {
            _ = await colony.advance()
            _ = await grid.evaporate()
        }

        let snapshot = await colony.snapshot()
        let theoreticalShortestPath = Float((food.x - nest.x) * 2)
        let averagePathLength = snapshot.completedTrips > 0
            ? snapshot.totalCompletedPathLength / Float(snapshot.completedTrips)
            : theoreticalShortestPath * 4

        let convergenceRatio = theoreticalShortestPath / max(theoreticalShortestPath, averagePathLength)
        let fitness = Float(snapshot.totalFoodCollected) * 1_000 +
            convergenceRatio * 100 -
            max(0, averagePathLength - theoreticalShortestPath) * 2

        return CandidateEvaluation(
            genome: genome,
            fitness: fitness,
            foodCollected: snapshot.totalFoodCollected,
            averagePathLength: averagePathLength,
            theoreticalShortestPath: theoreticalShortestPath
        )
    }

    private nonisolated static func makeSummary(
        generation: Int,
        evaluations: [CandidateEvaluation]
    ) -> GenerationSummary {
        let count = Float(max(1, evaluations.count))
        let averageFitness = evaluations.reduce(0) { $0 + $1.fitness } / count
        let totalFood = evaluations.reduce(0) { $0 + $1.foodCollected }
        let averagePath = evaluations.reduce(0) { $0 + $1.averagePathLength } / count
        let best = evaluations.first?.fitness ?? 0
        let theoretical = evaluations.first?.theoreticalShortestPath ?? 0

        return GenerationSummary(
            generation: generation,
            bestFitness: best,
            averageFitness: averageFitness,
            totalFoodCollected: totalFood,
            averagePathLength: averagePath,
            theoreticalShortestPath: theoretical
        )
    }

    private func breedNextGeneration(
        from evaluations: [CandidateEvaluation]
    ) -> [EvolutionGenome] {
        guard let elite = evaluations.first else {
            return genomes
        }

        var nextGeneration = [elite.genome]
        nextGeneration.reserveCapacity(configuration.populationSize)

        while nextGeneration.count < configuration.populationSize {
            let firstParent = tournamentSelect(from: evaluations)
            let secondParent = tournamentSelect(from: evaluations)
            var child = crossover(firstParent, secondParent)
            mutate(&child)
            nextGeneration.append(child)
        }

        return nextGeneration
    }

    private func tournamentSelect(
        from evaluations: [CandidateEvaluation]
    ) -> EvolutionGenome {
        var best = evaluations[randomIndex(upperBound: evaluations.count)]

        for _ in 1 ..< min(configuration.tournamentSize, evaluations.count) {
            let candidate = evaluations[randomIndex(upperBound: evaluations.count)]
            if candidate.fitness > best.fitness {
                best = candidate
            }
        }

        return best.genome
    }

    private func crossover(
        _ first: EvolutionGenome,
        _ second: EvolutionGenome
    ) -> EvolutionGenome {
        let cutPoint = randomIndex(upperBound: 5)
        let firstGenes: [Float] = [
            first.chromosome.alpha,
            first.chromosome.beta,
            Float(first.chromosome.visionRadius),
            first.chromosome.stepVelocity,
            Float(first.chromosome.maximumLifespan)
        ]
        let secondGenes: [Float] = [
            second.chromosome.alpha,
            second.chromosome.beta,
            Float(second.chromosome.visionRadius),
            second.chromosome.stepVelocity,
            Float(second.chromosome.maximumLifespan)
        ]
        let genes = (0 ..< firstGenes.count).map {
            $0 < cutPoint ? firstGenes[$0] : secondGenes[$0]
        }

        return EvolutionGenome(
            chromosome: AntChromosome(
                alpha: genes[0],
                beta: genes[1],
                visionRadius: Int(genes[2].rounded()),
                stepVelocity: genes[3],
                maximumLifespan: Int(genes[4].rounded())
            )
        )
    }

    private func mutate(_ genome: inout EvolutionGenome) {
        if random.unitFloat() < configuration.mutationRate {
            genome.chromosome.alpha = (genome.chromosome.alpha + gaussianNoise())
                .clamped(to: 0.1 ... 6)
        }
        if random.unitFloat() < configuration.mutationRate {
            genome.chromosome.beta = (genome.chromosome.beta + gaussianNoise())
                .clamped(to: 0.1 ... 10)
        }
        if random.unitFloat() < configuration.mutationRate {
            genome.chromosome.visionRadius = Int(
                (Float(genome.chromosome.visionRadius) + gaussianNoise())
                    .clamped(to: 1 ... 4)
                    .rounded()
            )
        }
        if random.unitFloat() < configuration.mutationRate {
            genome.chromosome.stepVelocity = (genome.chromosome.stepVelocity + gaussianNoise())
                .clamped(to: 1 ... 3)
        }
        if random.unitFloat() < configuration.mutationRate {
            genome.chromosome.maximumLifespan = Int(
                (Float(genome.chromosome.maximumLifespan) + gaussianNoise() * 100)
                    .clamped(to: 100 ... 1_000)
                    .rounded()
            )
        }
    }

    private func gaussianNoise() -> Float {
        let first = max(random.unitFloat(), 0.000_001)
        let second = random.unitFloat()
        let unitGaussian = sqrtf(-2 * logf(first)) * cosf(2 * .pi * second)
        return unitGaussian * configuration.mutationStandardDeviation
    }

    private func randomIndex(upperBound: Int) -> Int {
        Int(random.next() % UInt64(upperBound))
    }
}

nonisolated enum EvolutionBenchmark {
    static func run() async -> EvolutionBenchmarkReport {
        let configuration = EvolutionConfiguration(
            populationSize: 8,
            antsPerColony: 64,
            epochTicks: 80,
            tournamentSize: 3,
            mutationRate: 0.12,
            mutationStandardDeviation: 0.18
        )
        let manager = EvolutionManager(configuration: configuration)
        let clock = ContinuousClock()
        let start = clock.now
        _ = await manager.runGeneration()
        let elapsed = start.duration(to: clock.now)

        return EvolutionBenchmarkReport(
            configuredAnts: configuration.populationSize * configuration.antsPerColony,
            populationSize: configuration.populationSize,
            epochTicks: configuration.epochTicks,
            elapsed: elapsed
        )
    }
}

private extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
