import RedlampDesign
import RedlampUI
import SwiftUI

/// The theme controls under the scene list. They sit there rather than in the toolbar,
/// where scene subtitles push extra items into overflow.
struct SidebarThemeControls: View {
    @Binding var theme: ThemeSelection

    var body: some View {
        ThemeControls(theme: $theme)
            .padding(12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}

extension EnvironmentValues {
    @Entry var themeSelection = ThemeSelection()
}
