import SwiftUI
import AVFoundation

@main
struct PiPtoGoApp: App {

    init() {
        // iPhone 上画中画可用性的硬前提：激活播放类音频会话。
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            // 会话配置失败时画中画可能不可用，界面会给出提示
        }
    }
}
