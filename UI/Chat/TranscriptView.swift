import SwiftUI

struct TranscriptView: View {
    let palette: Palette
    let fontSize: CGFloat
    let showTimestamps: Bool

    @Environment(ChatStore.self) private var chat

    private let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        MessageRow(
                            message: message,
                            palette: palette,
                            fontSize: fontSize,
                            showTimestamp: showTimestamps
                        )
                        .id(message.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 0)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(palette.background)
            .onChange(of: chat.messages.count) {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: chat.messages.last?.text) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}