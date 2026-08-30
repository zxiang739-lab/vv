import Foundation
import AVFoundation
import CoreMedia
import UIKit

/// 摄像头采集服务（AVCaptureSession）。
///
/// 职责：
/// - 权限检查（摄像头）；
/// - 配置 AVCaptureSession + AVCaptureVideoDataOutput；
/// - 输出 BGRA（`kCVPixelFormatType_32BGRA`），与 CoreML 图像输入直接兼容；
/// - 通过 `onSampleBuffer` 回调把 CMSampleBuffer 交给上层（实时链路）。
final class CameraService: NSObject {

    // MARK: - 输出

    /// 帧回调（在 cameraQueue 上串行回调）
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: - 内部

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    /// 会话配置队列（AVCaptureSession 的配置必须在专用串行队列）
    private let sessionQueue = DispatchQueue(label: "camera.session", qos: .userInitiated)

    /// 帧回调队列
    private let cameraQueue = DispatchQueue(label: "camera.capture", qos: .userInitiated)

    private(set) var isRunning = false

    // MARK: - 权限

    /// 摄像头授权状态
    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// 请求摄像头权限；返回是否已授权。
    func requestAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    // MARK: - 启动 / 停止

    /// 启动采集会话。
    func start(position: AVCaptureDevice.Position = .back, preset: AVCaptureSession.Preset = .hd1280x720) async throws {
        // 权限
        guard await requestAuthorization() else {
            throw AppError.permissionDenied(reason: "请在系统设置中允许「相机」权限后再试。")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureSession(position: position, preset: preset)
                    self.session.startRunning()
                    self.isRunning = self.session.isRunning
                    if self.isRunning {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: AppError.cameraUnavailable(reason: "AVCaptureSession 未能启动。"))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 停止采集会话。
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.isRunning = false
        }
    }

    // MARK: - 会话配置

    private func configureSession(position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = preset

        // 输入设备
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw AppError.cameraUnavailable(reason: "找不到可用摄像头。")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AppError.cameraUnavailable(reason: "无法添加摄像头输入。")
        }
        session.addInput(input)

        // 输出
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // 丢弃迟到帧：实时链路优先低延迟，不做帧缓冲堆积
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)

        guard session.canAddOutput(videoOutput) else {
            throw AppError.cameraUnavailable(reason: "无法添加视频数据输出。")
        }
        session.addOutput(videoOutput)

        // 竖屏方向（按需可通过 connection.videoRotationAngle 调整）
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = (position == .front)
            }
        }
    }
}

// MARK: - 帧输出回调

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 迟到帧被丢弃（alwaysDiscardsLateVideoFrames 生效），无需处理
    }
}
