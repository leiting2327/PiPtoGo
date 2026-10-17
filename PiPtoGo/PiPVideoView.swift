import UIKit
import AVFoundation
import AVKit

/// 承载 AVPlayerLayer 与 AVPictureInPictureController 的视图。
/// 所有画中画逻辑都收敛在这里。
final class PiPVideoView: UIView {

    let playerLayer = AVPlayerLayer()

    /// 供外部状态回调，SwiftUI 通过它更新 UI
    var onPiPStateChanged: ((Bool) -> Void)?
    var onPossibleChanged: ((Bool) -> Void)?

    private var pipController: AVPictureInPictureController?
    private var possibilityObservation: NSKeyValueObservation?
    private var activeObservation: NSKeyValueObservation?

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
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller.delegate = self
        pipController = controller

        possibilityObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            self?.onPossibleChanged?(controller.isPictureInPicturePossible)
        }
        activeObservation = controller.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] controller, _ in
            self?.onPiPStateChanged?(controller.isPictureInPictureActive)
        }
    }

    func startPIP() {
        guard let pipController, pipController.isPictureInPicturePossible else { return }
        pipController.startPictureInPicture()
    }

    func stopPIP() {
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
