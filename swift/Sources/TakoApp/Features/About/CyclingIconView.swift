import SwiftUI
import TakoKit
import Combine

/// A view that shows the application icon.
struct CyclingIconView: View {
    @EnvironmentObject var viewModel: AboutViewModel

    var body: some View {
        ZStack {
            // Keyed by the picture, not the choice: an icon drawn as the app's
            // own (.official has no asset) cross-faded into itself, dimming
            // it for half a second on the first tap.
            iconView(for: viewModel.currentIcon)
                .id(viewModel.currentIcon?.assetName)
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.currentIcon?.assetName)
        .frame(height: 128)
        .onHover { viewModel.isHovering = $0 }
        .onTapGesture { viewModel.advanceToNextIcon() }
        .contextMenu {
            if viewModel.currentIconConfig != nil {
                Button("Copy Icon Config") { viewModel.copyCurrentIconConfig() }
            }
        }
        .accessibilityLabel("Tako Application Icon")
        .accessibilityHint("Click to cycle through icon variants")
    }

    @ViewBuilder
    private func iconView(for icon: Tako.MacOSIcon?) -> some View {
        let iconImage: Image = switch icon?.assetName {
        case let assetName?: Image(assetName)
        case nil: appIconImage()
        }

        iconImage
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
