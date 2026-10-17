import UIKit
import AVFoundation
import AVKit

/// 承载 AVPlayerLayer 与 AVPictureInPictureController 的视图。
/// 所有画中画逻辑都收敛在这里。
final class PiPVideoView: UIView {

    let playerLayer = AVPlayerLayer()

    /// 供外部状态回调，SwiftUI 通过它更新 UI
    var onPiPActive: ((Bool) -> Void)?
    var onPossibleChanged: ((Bool) -> Void)?
    var onPIPError: ((String) -> Void)?

    private var pipController: AVPictureInPictureController?
    private var possibilityObservation: NSKeyValueObservation?
    private var activeObservation: NSKeyValueObservation?

    private var pendingStart = false
    private var pendingTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    /// 设备是否支持画中画
    static var isPiPSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// 绑定播放器并初始化画中画控制器。
    /// 幂等：传入同一个播放器时直接返回，避免 SwiftUI 刷新反复重建控制器导致画中画中断。
    func attach(player newPlayer: AVPlayer?) {
        if playerLayer.player === newPlayer { return }

        playerLayer.player = newPlayer

        pipController?.stopPictureInPicture()
        pipController = nil
        possibilityObservation = nil
        activeObservation = nil

        guard let newPlayer else { return }

        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            onPIPError?("此设备/内容不支持画中画")
            return
        }
        pipController = controller
        controller.delegate = self

        possibilityObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            self?.onPossibleChanged?(controller.isPictureInPicturePossible)
        }
        activeObservation = controller.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] controller, _ in
            self?.onPiPActive?(controller.isPictureInPictureActive)
        }
    }

    /// 开始画中画：若系统尚未就绪（isPictureInPicturePossible 为 false），
    /// 会短暂等待最多约 4 秒，就绪后自动启动；超时则通过 onPIPError 提示。
    func startPIP() {
        pendingTimer?.invalidate()
        pendingTimer = nil

        guard let controller = pipController else {
            onPIPError?("画中画控制器未就绪")
            return
        }

        // 确保正在播放（PiP 需要播放中的内容）
        if let player = playerLayer.player, player.rate == 0 {
            player.play()
        }

        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }

        pendingStart = true
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollPendingStart()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.pendingStart else { return }
            self.pendingStart = false
            self.pendingTimer?.invalidate()
            self.pendingTimer = nil
            self.onPIPError?("无法启动画中画：系统未就绪（请确认未锁屏、设备设置中允许画中画）")
        }
    }

    private func pollPendingStart() {
        guard pendingStart else { return }
        guard let controller = pipController else {
            pendingStart = false
            pendingTimer?.invalidate()
            pendingTimer = nil
            return
        }
        if controller.isPictureInPicturePossible {
            pendingStart = false
            pendingTimer?.invalidate()
            pendingTimer = nil
            controller.startPictureInPicture()
        }
    }

    func stopPIP() {
        pendingStart = false
        pendingTimer?.invalidate()
        pendingTimer = nil
        pipController?.stopPictureInPicture()
    }

    var isActive: Bool {
        pipController?.isPictureInPictureActive ?? false
    }
}

extension PiPVideoView: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
