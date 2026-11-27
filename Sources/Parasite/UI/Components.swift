import SwiftUI

extension Severity {
    var color: Color {
        switch self {
        case .info: .secondary
        case .elevated: .orange
        case .high: .red
        case .critical: .purple
        }
    }
}

/// A horizontal bar showing how much of one ceiling is in use. Colour is keyed to
/// the fraction, so the whole panel can be read at a glance without labels.
struct HeadroomBar: View {
    let label: String
    let fraction: Double?
    var caption: String?

    private var clamped: Double { min(1, max(0, fraction ?? 0)) }

    private var color: Color {
        guard let f = fraction else { return .secondary.opacity(0.3) }
        if f > 0.92 { return .red }
        if f > 0.78 { return .orange }
        if f > 0.6 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(fraction.map { Fmt.pct(min(1.5, $0)) } ?? "not measured")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(fraction == nil ? .secondary : .primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: max(2, geo.size.width * clamped))
                }
            }
            .frame(height: 6)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SeverityBadge: View {
    let severity: Severity

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: severity.symbol)
            Text(severity.label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(severity.color.opacity(0.16), in: Capsule())
        .foregroundStyle(severity.color)
    }
}

struct FindingRow: View {
    let finding: Finding
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    SeverityBadge(severity: finding.severity)
                    Text(finding.title).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Text(finding.category.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·").foregroundStyle(.secondary)
                            Text(e).font(.caption).textSelection(.enabled)
                        }
                    }
                    if let remedy = finding.remedy {
                        Text(remedy)
                            .font(.caption)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.leading, 18)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A command the user may want to run. Copy rather than execute, deliberately:
/// Parasite diagnoses, it does not take actions on the machine by itself.
struct CommandBlock: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
