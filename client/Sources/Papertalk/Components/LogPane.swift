import SwiftUI

// MARK: - Collapsible raw activity log pane (bottom of detail view)
struct LogPane: View {
    let lines: [String]
    @Binding var isOpen: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack {
                    Image(systemName: "terminal").font(.caption)
                    Text("Activity log").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text("\(lines.count) lines").font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.up").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            if isOpen {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(lines.isEmpty ? "No activity yet." : lines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottom")
                    }
                    .frame(maxHeight: 150)
                    .padding(10)
                    .onChange(of: lines.count) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}