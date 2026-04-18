import Charts
import SwiftUI

struct StatisticsTab: View {
    private var stats = StatisticsService.shared
    @State private var chartRange = 7
    @State private var showingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCards
                transcriptionsOverTimeChart
                HStack(alignment: .top, spacing: 16) {
                    providerUsageChart
                    latencyByProviderChart
                }
                topAppsChart
                detailsSection
                resetButton
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            StatCard(title: "Total", value: "\(stats.totalCount)", icon: "number")
            StatCard(title: "Today", value: "\(stats.todayCount)", icon: "calendar")
            StatCard(title: "Words", value: formatNumber(stats.totalWords), icon: "text.word.spacing")
            StatCard(title: "Streak", value: "\(stats.currentStreak)d", icon: "flame")
        }
    }

    // MARK: - Transcriptions Over Time

    private var transcriptionsOverTimeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcriptions Over Time")
                    .font(.headline)
                Spacer()
                Picker("Range", selection: $chartRange) {
                    Text("7 Days").tag(7)
                    Text("30 Days").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            let data = stats.transcriptionsPerDay(last: chartRange)
            if data.contains(where: { $0.count > 0 }) {
                Chart(data, id: \.date) { item in
                    BarMark(
                        x: .value("Date", item.date, unit: .day),
                        y: .value("Count", item.count)
                    )
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: chartRange <= 7 ? 1 : 5)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 150)
            } else {
                noDataPlaceholder(height: 150)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Provider Usage (Donut)

    private var providerUsageChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider Usage")
                .font(.headline)

            let breakdown = stats.providerBreakdown
            if breakdown.isEmpty {
                noDataPlaceholder(height: 120)
            } else {
                Chart(breakdown.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                    SectorMark(
                        angle: .value("Count", item.value),
                        innerRadius: .ratio(0.5),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Provider", providerDisplayName(item.key)))
                    .cornerRadius(3)
                }
                .frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Avg Latency by Provider

    private var latencyByProviderChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Avg Latency")
                .font(.headline)

            let latencies = stats.averageLatencyByProvider
            if latencies.isEmpty {
                noDataPlaceholder(height: 120)
            } else {
                Chart(latencies.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                    BarMark(
                        x: .value("Latency", item.value),
                        y: .value("Provider", providerDisplayName(item.key))
                    )
                    .foregroundStyle(.orange.gradient)
                    .cornerRadius(3)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(String(format: "%.1fs", item.value))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Top Apps

    private var topAppsChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Most Used Apps")
                .font(.headline)

            let topApps = stats.topTargetApps
            if topApps.isEmpty {
                noDataPlaceholder(height: 100)
            } else {
                Chart(topApps, id: \.bundleID) { item in
                    BarMark(
                        x: .value("Count", item.count),
                        y: .value("App", appName(for: item.bundleID))
                    )
                    .foregroundStyle(.green.gradient)
                    .cornerRadius(3)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("\(item.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(topApps.count) * 28)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Details

    private var detailsSection: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "Avg Duration",
                value: String(format: "%.1fs", stats.averageAudioDuration),
                icon: "waveform"
            )
            StatCard(
                title: "Characters",
                value: formatNumber(stats.totalCharacters),
                icon: "character.cursor.ibeam"
            )
        }
    }

    // MARK: - Reset

    private var resetButton: some View {
        Button("Reset Statistics", role: .destructive) {
            showingResetConfirmation = true
        }
        .confirmationDialog("Reset all statistics?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) {
                stats.reset()
            }
        } message: {
            Text("This will permanently delete all recorded transcription events.")
        }
    }

    // MARK: - Helpers

    private func noDataPlaceholder(height: CGFloat) -> some View {
        Text("No data yet")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height)
    }

    private func providerDisplayName(_ rawValue: String) -> String {
        ProviderType(rawValue: rawValue)?.displayName ?? rawValue
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
