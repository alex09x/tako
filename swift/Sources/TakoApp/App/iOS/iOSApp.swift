import SwiftUI
import TakoKit

@main
struct Tako_iOSApp: App {
    @StateObject private var tako_app: Tako.App

    init() {
        if tako_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != TAKO_SUCCESS {
            preconditionFailure("Initialize tako backend failed")
        }
        _tako_app = StateObject(wrappedValue: Tako.App())
    }

    var body: some Scene {
        WindowGroup {
            iOS_TakoTerminal()
                .environmentObject(tako_app)
        }
    }
}

struct iOS_TakoTerminal: View {
    @EnvironmentObject private var tako_app: Tako.App

    var body: some View {
        ZStack {
            // Make sure that our background color extends to all parts of the screen
            Color(tako_app.config.backgroundColor).ignoresSafeArea()

            Tako.Terminal()
        }
    }
}

struct iOS_TakoInitView: View {
    @EnvironmentObject private var tako_app: Tako.App

    var body: some View {
        VStack {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 96)
            Text("Tako")
            Text("State: \(tako_app.readiness.rawValue)")
        }
        .padding()
    }
}
