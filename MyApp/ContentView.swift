import SwiftUI

struct ContentView: View {
    @StateObject private var controller = PheromoneEvaporationController()

    var body: some View {
        HStack(spacing: 0) {
            PheromoneMatrixView(snapshot: controller.snapshot)
                .frame(minWidth: 560, minHeight: 560)
                .background(Color.black)

            Divider()

            PheromoneControlPanel(
                iteration: controller.snapshot.iteration,
                centerValue: controller.snapshot.value(
                    at: GridCoordinate(
                        x: controller.dimensions.width / 2,
                        y: controller.dimensions.height / 2
                    )
                ),
                isRunning: controller.isRunning,
                report: controller.verificationReport,
                start: controller.start,
                stop: controller.stop,
                seed: {
                    controller.seedPheromone(
                        at: GridCoordinate(
                            x: controller.dimensions.width / 2,
                            y: controller.dimensions.height / 2
                        )
                    )
                },
                verify: controller.runOneHundredIterationVerification
            )
            .frame(width: 310)
            .padding()
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

struct PheromoneMatrixView: View {
    let snapshot: PheromoneSnapshot

    var body: some View {
        Canvas(opaque: true, colorMode: .linear, rendersAsynchronously: true) { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black)
            )

            let cellWidth = size.width / CGFloat(snapshot.dimensions.width)
            let cellHeight = size.height / CGFloat(snapshot.dimensions.height)

            for row in 0 ..< snapshot.dimensions.height {
                for column in 0 ..< snapshot.dimensions.width {
                    let coordinate = GridCoordinate(x: column, y: row)
                    let pheromone = snapshot.value(at: coordinate)

                    guard pheromone > 0.000_01 else {
                        continue
                    }

                    let rect = CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    )

                    context.fill(
                        Path(rect),
                        with: .color(.cyan.opacity(Double(min(pheromone, 1))))
                    )
                }
            }
        }
        .accessibilityLabel("Pheromone matrix visualization")
    }
}

struct PheromoneControlPanel: View {
    let iteration: Int
    let centerValue: Float
    let isRunning: Bool
    let report: PheromoneEvaporationReport?
    let start: () -> Void
    let stop: () -> Void
    let seed: () -> Void
    let verify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PheromoneHeader()
            PheromoneReadout(iteration: iteration, centerValue: centerValue)
            PheromoneActions(
                isRunning: isRunning,
                start: start,
                stop: stop,
                seed: seed,
                verify: verify
            )
            PheromoneVerificationResult(report: report)
            Spacer()
        }
    }
}

struct PheromoneHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ant Colony Evo Sandbox")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Phase 1 · Matrix and evaporation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct PheromoneReadout: View {
    let iteration: Int
    let centerValue: Float

    var body: some View {
        LabeledContent("Iterations") {
            Text(iteration, format: .number)
                .monospacedDigit()
        }

        LabeledContent("Center pheromone") {
            Text(centerValue, format: .number.precision(.fractionLength(6)))
                .monospacedDigit()
        }
    }
}

struct PheromoneActions: View {
    let isRunning: Bool
    let start: () -> Void
    let stop: () -> Void
    let seed: () -> Void
    let verify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Inject center pheromone", action: seed)

            Button(isRunning ? "Pause evaporation" : "Start evaporation") {
                if isRunning {
                    stop()
                } else {
                    start()
                }
            }

            Button("Verify 100 iterations", action: verify)
        }
        .buttonStyle(.borderedProminent)
    }
}

struct PheromoneVerificationResult: View {
    let report: PheromoneEvaporationReport?

    var body: some View {
        Group {
            if let report {
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.isWithinTolerance ? "Verification passed" : "Verification failed")
                        .font(.headline)
                        .foregroundStyle(report.isWithinTolerance ? .green : .red)

                    Text("Expected: \(report.expectedValue, format: .number.precision(.fractionLength(6)))")
                    Text("Observed: \(report.observedValue, format: .number.precision(.fractionLength(6)))")
                }
                .font(.caption)
            } else {
                Text("Run the 100-iteration verification to compare the matrix against the analytical decay result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
