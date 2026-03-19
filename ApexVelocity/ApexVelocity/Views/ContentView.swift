import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = HighFPSCameraManager()
    @StateObject private var ballDetector = BallDetector()
    @StateObject private var ballTracker = BallTracker()

    var body: some View {
        RecordingView(cameraManager: cameraManager, ballTracker: ballTracker)
            .statusBarHidden(true)
            .onAppear {
                // Wire ball detector into camera manager
                cameraManager.ballDetector = ballDetector
                // Bind tracker to detector
                ballTracker.bind(to: ballDetector)
            }
    }
}

#Preview {
    ContentView()
}
