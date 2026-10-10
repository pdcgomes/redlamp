import AVFoundation
import RedlampDesign
import SwiftUI

/// The welcome window's content: the film, then two pages beneath the logo it ends on. The pages
/// keep to the film's wall and its one light, the glow behind the logo, in the system font.
struct WelcomeView: View {
    /// The film's frame in points: it's rendered at 1920 × 1080.
    static let size = CGSize(width: 960, height: 540)
    /// Clear of the logo, which the film's last frame has in its top 120 points.
    static let pageTop: CGFloat = 158

    let model: WelcomeModel

    var body: some View {
        ZStack {
            if let player = model.player {
                FilmView(player: player)
                    .opacity(model.filmOpacity)
                    .animation(.easeInOut(duration: 0.3), value: model.filmOpacity)
                    .accessibilityElement()
                    .accessibilityLabel(
                        "In the darkroom, there's one light you can work by. It shows you everything, and harms nothing. "
                            + "Redlamp: a raw photo editor for the Mac.",
                    )
            }
            Group {
                switch model.step {
                case .film: SkipButton(action: model.skip)
                case .about: AboutPage(onContinue: model.next)
                case .help: HelpPage(onStart: model.next)
                }
            }
            .transition(.asymmetric(insertion: .identity, removal: .developOut))
        }
        .animation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.67), value: model.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.wall.color)
        .foregroundStyle(Brand.paper.color)
        .ignoresSafeArea()
    }
}

private struct AboutPage: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Develop {
                PageTitle("Welcome to Redlamp")
            }
            VStack(alignment: .leading, spacing: 20) {
                Develop(delay: 0.2) {
                    Feature(
                        symbol: "slider.horizontal.3",
                        title: "Everything you know",
                        text: "The Develop panels, sliders and shortcuts, as in Lightroom.",
                    )
                }
                Develop(delay: 0.35) {
                    Feature(
                        symbol: "photo.badge.checkmark",
                        title: "Your originals stay untouched",
                        text: "Each edit is kept in a small file beside its photo. There's nothing to import, and nothing leaves your Mac.",
                    )
                }
                Develop(delay: 0.5) {
                    Feature(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        title: "Free and open source",
                        text: "No subscription and no cloud, and the code is open for anyone to read and improve.",
                    )
                }
            }
            .frame(width: 452, alignment: .leading)
            .padding(.top, 30)
            Spacer(minLength: 0)
            Develop(delay: 0.8) {
                PageButton("Continue", action: onContinue)
            }
        }
        .padding(.top, WelcomeView.pageTop)
        .padding(.bottom, 44)
    }
}

/// Pedro's note: it's early, and what helps most is hearing what breaks.
private struct HelpPage: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Develop(delay: 0.3) {
                PageTitle("It's early, and you can help")
            }
            Develop(delay: 0.5) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("""
                    Redlamp is a pre-alpha, and only a handful of cameras have been checked properly, so your \
                    photos are the best test it can have. Edit them the way you normally would, and tell me what \
                    breaks, what looks wrong and what you miss.
                    """)
                    Text("I read every report. It's how Redlamp gets better.")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thank you for trying it,")
                        Text("Pedro").foregroundStyle(Brand.paper.color)
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Brand.paper.opacity(0.74).color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 476, alignment: .leading)
            }
            .padding(.top, 24)
            Spacer(minLength: 0)
            Develop(delay: 0.9) {
                PageButton("Start Editing", action: onStart)
            }
        }
        .padding(.top, WelcomeView.pageTop)
        .padding(.bottom, 44)
    }
}

/// In the corner while the film plays; Return and Escape skip too.
private struct SkipButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Develop(delay: 1.5) {
            Button("Skip", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Brand.paper.opacity(hovering ? 0.8 : 0.45).color)
                .onHover { hovering = $0 }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 26)
        .padding(.bottom, 20)
    }
}
