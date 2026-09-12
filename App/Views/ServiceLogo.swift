import SwiftUI
import AILimitsCore

/// Оригинальные знаки сервисов; источники в docs/service-logo-sources.md.
struct ServiceLogo: View {
    let provider: ProviderID
    var size: CGFloat = 14

    var body: some View {
        Image("service-" + provider.rawValue)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
