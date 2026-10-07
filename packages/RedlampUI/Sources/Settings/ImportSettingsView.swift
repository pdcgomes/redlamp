import SwiftUI

/// Settings › Import (LIB-27): what the app does around a card. The import window opens on a card as
/// it's inserted, as in Lightroom Classic, and cards can be ejected once an import is over and every
/// photo copied from them verified, which the import window also offers.
struct ImportSettingsView: View {
    @Bindable var preferences: ImportPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Show the import window when a card is inserted", isOn: $preferences.showsWindowWhenCardInserted)
                    .accessibilityIdentifier("settings.import.card-inserted")
                Toggle("Eject cards after importing", isOn: $preferences.ejectsAfterImport)
                    .accessibilityIdentifier("settings.import.eject-after")
            } header: {
                Text("Cards")
            } footer: {
                Text("""
                A card is a camera's: a volume that comes out of its reader or ejects, with a DCIM folder. \
                A card is ejected only once every photo copied from it is verified at the destination \
                and the backup.
                """)
                .formFooter()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
