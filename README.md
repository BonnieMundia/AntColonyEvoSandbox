# AntColonyEvoSandbox

A macOS SwiftUI sandbox for profiling hybrid **Ant Colony Optimization (ACO)** and **Genetic Algorithm (GA)** pathfinding. Ants find routes between a nest and a food source using pheromone trails. A genetic algorithm evolves the parameters that control how they steer.

All simulation state lives in Swift actors (`GridSystem`, `AntColonyEngine`, `EvolutionManager`). Main-actor controllers pass snapshots to SwiftUI.

## Iterations

| Phase | Focus | Key files |
| --- | --- | --- |
| 1 | Grid topology and pheromone evaporation backed by Accelerate, with a verification dashboard that runs 100 iterations | `GridSystem.swift`, `PheromoneEvaporationController.swift`, `ContentView.swift` |
| 2 | Ant state machine (search / return), probabilistic steering weighted by pheromone (α) and heuristic (β), and a deterministic verification harness | `AntColonyEngine.swift` |
| 3 | Hybrid GA: completed-route metrics, tournament selection, crossover, Gaussian mutation, generation summaries, and a benchmark | `EvolutionManager.swift`, `AntColonyEngine.swift` |
| 4 | Live dashboard controller: timed colony ticks, a GA generation every 120 ticks, obstacle walls you can toggle, and tunable mutation, evaporation and population settings | `DashboardSimulationController.swift`, `GridSystem.swift` |

## Architecture

- **`GridSystem`** (actor): 100×100 cell topology (empty, nest, food, obstacle wall) plus a pheromone matrix. Handles deposits, evaporation and snapshots.
- **`AntColonyEngine`** (actor): moves each `AntAgent` according to its `AntChromosome` (alpha, beta, vision radius, step velocity, lifespan). Tracks food collected and completed round-trip lengths.
- **`EvolutionManager`** (actor): evaluates a population of genomes over fixed epochs, scores fitness against the theoretical shortest path, and breeds the next generation.
- **Controllers** (`@MainActor`): `PheromoneEvaporationController` and `DashboardSimulationController` drive ticks and publish snapshots to the UI.

Randomness comes from a seeded `SplitMix64` generator, so runs are reproducible.

## Requirements

- macOS 27.0 or later
- Xcode with the macOS 27 SDK

## Running

1. Open `Untitled Project 2.xcodeproj` in Xcode.
2. Select the **AntColonyEvoSandbox** scheme.
3. Build and run (⌘R).
