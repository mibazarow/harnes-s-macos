import SwiftUI

/// One pill per running child. A fact, not a control panel: no click, no popover, no
/// steps. Details come from `subagent_status` if the user asks.
struct SubagentPills: View {
    let agents: [SubagentInfo]

    @Environment(\.theme) private var theme

    static let visibleLimit = 3

    var body: some View {
        HStack(spacing: Spacing.offGrid6) {
            ForEach(agents.prefix(Self.visibleLimit)) { agent in
                pill(agent)
            }
            if agents.count > Self.visibleLimit {
                Text("+\(agents.count - Self.visibleLimit)")
                    .font(.caption2)
                    .foregroundStyle(theme.labelSecondary)
                    .padding(.horizontal, Spacing.small)
                    .padding(.vertical, Spacing.offGrid2)
                    .background(theme.labelQuaternary.opacity(0.15), in: Capsule())
                    .accessibilityLabel("Ещё \(agents.count - Self.visibleLimit) подагентов")
            }
        }
        .animation(.default, value: agents)
    }

    private func pill(_ agent: SubagentInfo) -> some View {
        HStack(spacing: Spacing.offGrid5) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.5)
                .frame(width: Spacing.offGrid10, height: Spacing.offGrid10)
            Text(agent.id)
                .font(AppFont.mono(max(Size.iconSmall - 1, FontSize.minReadable)))
                .foregroundStyle(theme.labelSecondary)
            Text(agent.title)
                .font(.caption2)
                .foregroundStyle(theme.labelPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: Spacing.offGrid32 * 5, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(SubagentStatus.duration(context.date.timeIntervalSince(agent.startedAt)))
                    .font(.caption2)
                    .foregroundStyle(theme.labelTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.offGrid3)
        .background(theme.labelQuaternary.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.id), \(agent.title), работает")
    }
}
