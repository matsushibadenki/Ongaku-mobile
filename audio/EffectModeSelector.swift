import SwiftUI

/// Native buttons keep short taps distinct from the surrounding scroll gesture.
struct EffectModeSelector: View {
    let selection: AudioEffectPageTab
    let accentColor: Color
    let onSelect: (AudioEffectPageTab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AudioEffectPageTab.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Text(mode.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 4)
                        .foregroundStyle(selection == mode ? Theme.onAccent : Theme.textSecondary)
                        .background(selection == mode ? accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("effects.mode.\(mode.rawValue)")
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.secondaryBackground,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("effects.tab.accessibility_label"))
    }
}

private struct EffectModeSelector_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview.previewDevice("iPhone SE (3rd generation)")
            preview.previewDevice("iPhone 16 Pro Max")
        }
    }

    private static var preview: some View {
        ScrollView {
            EffectModeSelector(selection: .basic, accentColor: .orange, onSelect: { _ in })
                .padding(.horizontal, 16)
        }
        .preferredColorScheme(.dark)
    }
}
