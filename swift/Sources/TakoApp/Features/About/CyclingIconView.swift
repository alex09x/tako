import SwiftUI
import TakoKit
import Combine

/// A view that shows the application icon.
struct CyclingIconView: View {
    @EnvironmentObject var viewModel: AboutViewModel

    var body: some View {
        ZStack {
            iconView(for: viewModel.currentIcon)
                .id(viewModel.currentIcon)
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.currentIcon)
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
