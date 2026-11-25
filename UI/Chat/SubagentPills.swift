import SwiftUI

/// S4: one pill per running child. A fact, not a control panel: no click, no popover,
/// no steps. If the user wants details they ask, and `subagent_status` answers.
struct SubagentPills: View {
    let agents: [SubagentInfo]
    let palette: Palette

    static let visibleLimit = 3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(agents.prefix(Self.visibleLimit)) { agent in
                pill(agent)
            }
            if agents.count > Self.visibleLimit {
                Text("+\(agents.count - Self.visibleLimit)")
                    .font(AppFont.mono(11))
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.panel)
                    .overlay(Capsule().stroke(palette.border, lineWidth: 1))
                    .clipShape(Capsule())
                    .accessibilityLabel("Ещё \(agents.count - Self.visibleLimit) подагентов")
            }
        }
        .animation(.default, value: agents)
    }

    private func pill(_ agent: SubagentInfo) -> some View {
        HStack(spacing: 5) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
            Text(agent.id)
                .font(AppFont.mono(11))
                .foregroundStyle(palette.dim)
            Text(agent.title)
                .font(AppFont.mono(11))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(SubagentStatus.duration(context.date.timeIntervalSince(agent.startedAt)))
                    .font(AppFont.mono(11))
                    .foregroundStyle(palette.faint)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(palette.panel)
        .overlay(Capsule().stroke(palette.border, lineWidth: 1))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.id), \(agent.title), работает")
    }
}
