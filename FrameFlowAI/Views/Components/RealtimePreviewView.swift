import SwiftUI
import AVFoundation

/// 实时预览视图：把 AVSampleBufferDisplayLayer 包装为 SwiftUI 视图。
///
/// 由 RealtimePipelineService 提供预览层实例；显示区域自适应等比。
struct RealtimePreviewView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.layer.backgroundColor = UIColor.black.cgColor
        view.previewLayer = layer
        layer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer = layer
    }

    /// 容器：把预览层作为 sublayer 加入，并随视图尺寸更新 frame。
    final class PreviewContainerView: UIView {
        var previewLayer: AVSampleBufferDisplayLayer? {
            didSet {
                guard previewLayer !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let previewLayer {
                    layer.addSublayer(previewLayer)
                    previewLayer.frame = bounds
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
}
