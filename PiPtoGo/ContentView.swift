import SwiftUI
import AVFoundation

struct ContentView: View {

    @State private var pipView = PiPVideoView(frame: .zero)
    @State private var liveView = LiveImageView(frame: .zero)

    @State private var player: AVPlayer?
    @State private var loopPlayer: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var liveEngine: LiveImageEngine?

    @State private var showImagePicker = false
    @State private var showVideoPicker = false

    @State private var piPSupported = PiPVideoView.isPiPSupported
    @State private var isPiPActive = false
    @State private var pipPossible = false
    @State private var statusText = "请选择一张图片或一个视频"

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                previewArea
                controls
                statusView
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("PiPtoGo")
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showImagePicker) {
            MediaPicker(kind: .image) { url in handleImage(url) }
        }
        .sheet(isPresented: $showVideoPicker) {
            MediaPicker(kind: .video) { url in handleVideo(url) }
        }
    }

    private var previewArea: some View {
        ZStack {
            if let engine = liveEngine {
                LiveImageContainer(
                    engine: engine,
                    view: liveView,
                    onPiPActive: { active in
                        isPiPActive = active
                        statusText = active ? "正在画中画播放中…" : (hasContent ? "画中画已停止" : "请选择媒体")
                    },
                    onPossible: { possible in
                        pipPossible = possible
                    }
                )
            } else {
                PiPVideoContainer(
                    player: $player,
                    view: pipView,
                    onPiPActive: { active in
                        isPiPActive = active
                        statusText = active ? "正在画中画播放中…" : (hasContent ? "画中画已停止" : "请选择媒体")
                    },
                    onPossible: { possible in
                        pipPossible = possible
                    }
                )
            }
        }
        .frame(height: 220)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            if !hasContent {
                VStack(spacing: 8) {
                    Image(systemName: "pip")
                        .font(.largeTitle)
                    Text("图片 / 视频画中画")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }

    private var hasContent: Bool {
        player != nil || liveEngine != nil
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                pickButton("相册图片", icon: "photo") { showImagePicker = true }
                pickButton("相册视频", icon: "film") { showVideoPicker = true }
            }
            HStack(spacing: 12) {
                pipButton(
                    "开始画中画",
                    icon: "pip.enter",
                    disabled: !hasContent || isPiPActive
                ) { startPIP() }
                pipButton(
                    "停止",
                    icon: "pip.exit",
                    disabled: !hasContent
                ) { stopPIP() }
            }
        }
    }

    private var statusView: some View {
        VStack(spacing: 4) {
            Text(statusText)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Text(piPSupported ? "此设备支持画中画" : "此设备不支持画中画")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pickButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private func pipButton(_ title: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
    }

    private func startPIP() {
        if let engine = liveEngine {
            engine.startPIP()
        } else {
            pipView.startPIP()
        }
    }

    private func stopPIP() {
        liveEngine?.stopPIP()
        pipView.stopPIP()
    }

    // MARK: - 处理选择的媒体

    private func handleImage(_ url: URL?) {
        guard let url else {
            statusText = "未选择图片"
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            statusText = "读取图片失败"
            return
        }

        // 切走旧的视频/画中画
        player?.pause()
        player = nil
        loopPlayer = nil
        looper = nil
        liveEngine?.stopPIP()
        pipView.stopPIP()

        // 直播式：直接把图片帧喂给渲染器，无需重编码
        let engine = LiveImageEngine()
        do {
            try engine.attach(imageData: data)
            liveEngine = engine
            statusText = "图片已就绪（直播式，无需编码），可开始画中画"
        } catch {
            statusText = "图片处理失败：\(error.localizedDescription)"
        }
    }

    private func handleVideo(_ url: URL?) {
        guard let url else {
            statusText = "未选择视频"
            return
        }

        // 切走旧的图片直播
        liveEngine?.stopPIP()
        liveEngine = nil

        let newPlayer = AVPlayer(playerItem: AVPlayerItem(url: url))
        player = newPlayer
        loopPlayer = nil
        looper = nil
        newPlayer.play()
        statusText = "视频已就绪，可开始画中画"
    }
}

/// 把 PiPVideoView 包进 SwiftUI，并暴露开始/停止画中画的能力。
struct PiPVideoContainer: UIViewRepresentable {

    @Binding var player: AVPlayer?
    let view: PiPVideoView
    let onPiPActive: (Bool) -> Void
    let onPossible: (Bool) -> Void

    func makeUIView(context: Context) -> PiPVideoView {
        view.onPiPActive = { active in onPiPActive(active) }
        view.onPossibleChanged = { possible in onPossible(possible) }
        view.attach(player: player)
        return view
    }

    func updateUIView(_ uiView: PiPVideoView, context: Context) {
        uiView.onPiPActive = { active in onPiPActive(active) }
        uiView.onPossibleChanged = { possible in onPossible(possible) }
        uiView.attach(player: player)
    }
}
