// Pieces several screens share: captioned fields, the LLM and speech forms' pickers, sheet
// headers, card backgrounds and small controls.

#if os(macOS)
import SwiftUI

/// A caption above a control.
struct CaptionedField<Content: View>: View {
    let label: String
    /// The caption's style.
    var style = HierarchicalShapeStyle.primary
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(style)
            content
        }
    }
}

/// Where an API key comes from, and that source's field: the same for the LLM and the speech server.
struct KeySourceSection<Form: KeySourceEditing>: View {
    @Binding var form: Form

    var body: some View {
        CaptionedField(label: L("API key source")) {
            Picker("", selection: $form.keySource) {
                ForEach(LLMKeySource.allCases) { s in Text(s.label).tag(s) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        KeySourceFields(form: $form)
    }
}

/// The LLM's models once listed, else a text field.
struct LLMModelPicker: View {
    @Binding var model: String
    let models: [String]
    let loading: Bool
    /// The menu takes the whole row.
    var fillsWidth = false

    var body: some View {
        if loading {
            ProgressView().controlSize(.small)
        } else if models.isEmpty {
            TextField(L("llama3.1:70b (manual)"), text: $model).textFieldStyle(.roundedBorder)
        } else {
            Picker("", selection: $model) {
                ForEach(models, id: \.self) { m in Text(m).tag(m) }
            }
            .labelsHidden()
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        }
    }
}

/// A switch with its explanation under it.
struct ExplainedSwitch: View {
    let title: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout.weight(.medium))
            Text(help)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }
}

/// A sheet's heading: an icon tile, the title and what's under it.
struct SheetHeader<Subtitle: View>: View {
    let icon: String
    let iconSize: CGFloat
    let title: String
    @ViewBuilder let subtitle: Subtitle

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.appAccent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                subtitle
            }
        }
    }
}

/// A sheet's Close, in its top corner.
struct SheetCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: { Label(L("Close"), systemImage: "xmark") }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
    }
}

/// The chevron at the end of a row, shown while the pointer is on it.
struct HoverChevron: View {
    let visible: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .opacity(visible ? 1 : 0)
    }
}

/// A row in a map's side panel that selects what it names.
struct MapPanelRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                content
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// A small round glass icon button's face.
    func glassCircle(size: CGFloat = 28) -> some View {
        frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: Circle())
    }

    /// The outlined card of the cast sheet.
    func outlinedCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return padding(12)
            .background(shape.fill(Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// A small cover: rounded, with a soft shadow.
    func smallCover(shadow opacity: Double, radius: CGFloat = 3) -> some View {
        clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .shadow(color: .black.opacity(opacity), radius: radius, y: 1)
    }

    /// The border of a prompt's editor.
    func editorBorder() -> some View {
        overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))
    }

    /// The pointer over a divider that resizes what's beside it.
    func resizeCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }
}

extension Binding where Value == Bool {
    /// True for a moment: "Copied".
    @MainActor
    func flash(animation: Animation? = .snappy) {
        withAnimation(animation) { wrappedValue = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation(animation) { wrappedValue = false }
        }
    }
}
#endif
