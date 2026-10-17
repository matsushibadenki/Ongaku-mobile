import SwiftUI

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
                Label(L10n.tr("settings.output.kind"), systemImage: "hifispeaker")
            }
            .pickerStyle(.menu)
            Button { showsHelp = true } label: {
                Image(systemName: "info.circle")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
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
            Label(L10n.tr("settings.output.compensation"), systemImage: "ear")
        }
    }
}

struct AudioOutputSettingsRows_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview.previewDevice("iPhone SE (3rd generation)")
            preview.previewDevice("iPhone 16 Pro Max")
        }
    }
    private static var preview: some View {
        Form {
            AudioOutputSettingsRows(output: .constant(.automatic), compensationEnabled: .constant(true))
        }
    }
}
