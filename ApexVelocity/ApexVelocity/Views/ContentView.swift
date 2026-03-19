import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = HighFPSCameraManager()

    var body: some View {
        RecordingView(cameraManager: cameraManager)
            .statusBarHidden(true)
    }
}

#Preview {
    ContentView()
}
