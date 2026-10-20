#if os(macOS)
import SwiftUI

// MARK: - Collapsible activity log card (bottom of the inspector)
struct LogPane: View {
    let lines: [String]
    @Binding var isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    SectionLabel(title: L("Activity"), systemImage: "terminal",
                                 trailing: LibraryPresentation.badge(lines.count))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? L("Hide activity log") : L("Show activity log"))

            if isOpen {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(TranscriptPresentation.logText(lines))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("bottom")
                    }
                    .frame(maxHeight: 180)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: lines.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassCard()
    }
}

#endif
