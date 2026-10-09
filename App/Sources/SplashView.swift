import AVFoundation
import SwiftUI
import UIKit

/// The opening splash: plays the Forensic Intelligence block reveal once, centred on
/// black, then calls `onFinished`. The launch screen is black too, so launch → splash
/// → Dee's eyes is one continuous dark stage.
struct SplashView: View {
    var onFinished: () -> Void

    static let resource = "Fi Block Bounce Reveal"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = Bundle.main.url(forResource: Self.resource, withExtension: "mp4") {
                SplashPlayer(url: url, onFinished: onFinished)
                    .ignoresSafeArea()
            }
        }
        .task {
            // Missing or unplayable video must never trap her behind the splash.
            if Bundle.main.url(forResource: Self.resource, withExtension: "mp4") == nil {
                onFinished()
                return
            }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { onFinished() }
        }
        .accessibilityHidden(true)
    }
}

private struct SplashPlayer: UIViewRepresentable {
    let url: URL
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // The sting is short; it respects the silent switch and mixes politely.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.observe(item)
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: Coordinator) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        private let onFinished: () -> Void
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        init(onFinished: @escaping () -> Void) { self.onFinished = onFinished }

        func observe(_ item: AVPlayerItem) {
            for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onFinished() }
                })
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
