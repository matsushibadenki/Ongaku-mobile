import SwiftUI

/// A neutral icon that does not inherit a form control's accent color.
struct SettingsNeutralIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
    }
}

/// Explicit icon styling prevents the surrounding form control from applying its accent color.
struct SettingsNeutralLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let systemImage: String

    private var color: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsNeutralIcon(systemImage: systemImage)
        }
        .foregroundStyle(color)
    }
}

struct AudioOutputSettingsRows: View {
    @Binding var output: AudioOutputOverride
    @Binding var compensationEnabled: Bool
    @State private var showsHelp = false

    var body: some View {
        HStack(spacing: 8) {
            Picker(selection: $output) {
                ForEach(AudioOutputOverride.allCases, id: \.self) { option in
                    Text(L10n.tr("settings.output.kind.\(option.rawValue)")).tag(option)
                }
            } label: {
                SettingsNeutralLabel(title: L10n.tr("settings.output.kind"), systemImage: "hifispeaker")
            }
            .pickerStyle(.menu)
            .tint(.primary)
            Button { showsHelp = true } label: {
                Image(systemName: "info.circle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(L10n.tr("settings.output.help.title"))
            .help(L10n.tr("settings.output.help"))
            .popover(isPresented: $showsHelp) {
                Text(L10n.tr("settings.output.help"))
                    .font(.callout)
                    .padding(16)
                    .frame(maxWidth: 320)
                    .presentationCompactAdaptation(.popover)
            }
        }
        Toggle(isOn: $compensationEnabled) {
            SettingsNeutralLabel(title: L10n.tr("settings.output.compensation"), systemImage: "ear")
        }
    }
}

struct AudioOutputSettingsRows_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview.preferredColorScheme(.light).previewDevice("iPhone SE (3rd generation)")
            preview.preferredColorScheme(.dark).previewDevice("iPhone 16 Pro Max")
        }
    }
    private static var preview: some View {
        Form {
            AudioOutputSettingsRows(output: .constant(.automatic), compensationEnabled: .constant(true))
        }
    }
}
