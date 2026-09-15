import SwiftUI

@main
struct XiangqiCoachApp: App {
    @StateObject private var model: CoachViewModel

    init() {
        let pipController = PiPCoachController()
        _model = StateObject(wrappedValue: CoachViewModel(pipController: pipController))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.light)
        }
    }
}

