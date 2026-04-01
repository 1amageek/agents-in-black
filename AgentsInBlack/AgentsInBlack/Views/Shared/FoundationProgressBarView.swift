import SwiftUI

struct FoundationProgressBarView: View {
    let progress: Progress
    var width: CGFloat? = nil
    var showsPercentage: Bool = false

    @State private var snapshot = Snapshot.initial

    var body: some View {
        HStack(spacing: 8) {
            if snapshot.isIndeterminate {
                ProgressView()
                    .controlSize(.small)
            } else {
                ProgressView(value: snapshot.fractionCompleted, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: width)
            }

            if showsPercentage {
                Text(snapshot.percentageText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: ObjectIdentifier(progress)) {
            await observeProgress()
        }
    }

    @MainActor
    private func observeProgress() async {
        updateSnapshot()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch is CancellationError {
                break
            } catch {
                break
            }
            updateSnapshot()
        }
    }

    @MainActor
    private func updateSnapshot() {
        snapshot = Snapshot(progress: progress)
    }
}

private extension FoundationProgressBarView {
    struct Snapshot {
        static let initial = Snapshot(
            fractionCompleted: 0,
            percentageText: "0%",
            isIndeterminate: true
        )

        let fractionCompleted: Double
        let percentageText: String
        let isIndeterminate: Bool

        init(progress: Progress) {
            let totalUnitCount = progress.totalUnitCount
            let fractionCompleted = progress.fractionCompleted

            self.fractionCompleted = min(max(fractionCompleted, 0), 1)
            self.isIndeterminate = totalUnitCount <= 0
            self.percentageText = "\(Int((self.fractionCompleted * 100).rounded()))%"
        }

        init(fractionCompleted: Double, percentageText: String, isIndeterminate: Bool) {
            self.fractionCompleted = fractionCompleted
            self.percentageText = percentageText
            self.isIndeterminate = isIndeterminate
        }
    }
}
