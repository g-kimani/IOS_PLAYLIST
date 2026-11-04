import AVFoundation
import MediaPlayer
import UIKit

/// iOS has no public call for setting the system volume. The standard workaround is to keep a
/// (hidden) MPVolumeView in the window and drive its slider, which gives continuous 0...1 control.
final class SystemVolume {
    static let shared = SystemVolume()

    private let volumeView = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 10, height: 10))

    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    var current: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    func attach() {
        guard volumeView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        volumeView.alpha = 0.01
        window?.addSubview(volumeView)
        volumeView.layoutIfNeeded()
    }

    func set(_ value: Float) {
        attach()
        let v = min(max(value, 0), 1)
        DispatchQueue.main.async { [weak self] in
            self?.slider?.value = v
        }
    }
}
