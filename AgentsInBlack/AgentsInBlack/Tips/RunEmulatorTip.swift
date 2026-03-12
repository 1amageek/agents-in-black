import TipKit

/// Tip shown on first launch to guide the user to start the emulator.
struct RunEmulatorTip: Tip {

    @Parameter
    static var hasStartedEmulator: Bool = false

    var title: Text {
        Text("Run the Emulator")
    }

    var message: Text? {
        Text("Press play to start all services in the local emulator.")
    }

    var image: Image? {
        Image(systemName: "play.fill")
    }

    var rules: [Rule] {
        [
            #Rule(Self.$hasStartedEmulator) { $0 == false }
        ]
    }
}
