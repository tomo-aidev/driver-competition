import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = HighFPSCameraManager()
    @StateObject private var ballDetector = BallDetector()
    @StateObject private var ballTracker = BallTracker()
    @StateObject private var motionManager = DeviceMotionManager()
    @ObservedObject var shotStore: ShotStore
    var switchToHistory: (() -> Void)?

    var body: some View {
        RecordingView(
            cameraManager: cameraManager,
            ballTracker: ballTracker,
            motionManager: motionManager,
            shotStore: shotStore,
            switchToHistory: switchToHistory
        )
        .statusBarHidden(true)
        .onAppear {
            cameraManager.ballDetector = ballDetector
            ballTracker.bind(to: ballDetector)
        }
    }
}
