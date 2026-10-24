import SwiftUI

/// "Change Measurement" — wheel pickers (feet · inches · fraction, or meters · cm) + Apply.
/// Presented when the user taps a dimension on the plan or a value tile in a panel.
struct MeasurementSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let meters: Double
    var onApply: (Double) -> Void

    @AppStorage("measure.unit") private var metric = false
    @State private var feet = 0
    @State private var inches = 0
    @State private var quarter = 0        // 0, 1/4, 1/2, 3/4
    @State private var m = 0
    @State private var cm = 0

    private var value: Double {
        metric ? Double(m) + Double(cm) / 100
               : (Double(feet) * 12 + Double(inches) + Double(quarter) * 0.25) * 0.0254
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(metric ? "Metric" : "Feet").foregroundStyle(.secondary)
                        Text("•").foregroundStyle(.tertiary)
                        Button(metric ? "Use feet" : "Use metric") { metric.toggle(); load() }
                            .font(.subheadline)
                    }
                    .font(.subheadline)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                }
            }
            .padding(.horizontal, 20).padding(.top, 18)

            Text(metric ? Measure.metric(value) : Measure.ftIn(value))
                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .padding(.top, 18)
            Text(metric ? Measure.ftIn(value) : Measure.metric(value))
                .font(.footnote).foregroundStyle(.secondary)

            Group {
                if metric {
                    HStack(spacing: 0) {
                        wheel($m, 0...60, suffix: "m")
                        wheel($cm, 0...99, suffix: "cm")
                    }
                } else {
                    HStack(spacing: 0) {
                        wheel($feet, 0...99, suffix: "'")
                        wheel($inches, 0...11, suffix: "\"")
                        Picker("", selection: $quarter) {
                            Text("0").tag(0); Text("1/4\"").tag(1); Text("1/2\"").tag(2); Text("3/4\"").tag(3)
                        }
                        .pickerStyle(.wheel).frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 180)
            .padding(.horizontal, 12)

            Button {
                onApply(max(0, value)); dismiss()
            } label: {
                Text("Apply").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .foregroundStyle(Color(.systemBackground))
            .padding(.horizontal, 20).padding(.bottom, 10)
        }
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onAppear(perform: load)
    }

    private func wheel(_ sel: Binding<Int>, _ range: ClosedRange<Int>, suffix: String) -> some View {
        Picker("", selection: sel) {
            ForEach(Array(range), id: \.self) { Text("\($0)\(suffix)").tag($0) }
        }
        .pickerStyle(.wheel).frame(maxWidth: .infinity)
    }

    private func load() {
        let q = max(0, (meters * 39.3700787 * 4).rounded())
        feet = Int(q / 48); inches = (Int(q) % 48) / 4; quarter = Int(q) % 4
        let c = max(0, (meters * 100).rounded())
        m = Int(c / 100); cm = Int(c) % 100
    }
}

/// Value tile used in the editor panels: label on top, value below; tap → MeasurementSheet.
struct MeasureTile: View {
    let title: String
    let meters: Double
    var tint: Color = .primary
    var onCommit: (Double) -> Void
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Text(Measure.ftIn(meters)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(minWidth: 84, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editing) {
            MeasurementSheet(title: title, meters: meters) { m in if abs(m - meters) > 0.001 { onCommit(m) } }
        }
    }
}
