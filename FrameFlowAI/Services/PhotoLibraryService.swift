import Foundation
import Photos

/// 相册服务：保存离线处理完成的视频到系统相册。
///
/// 权限：Info.plist 已声明
/// - NSPhotoLibraryUsageDescription（读，用于从相册选择导入视频）
/// - NSPhotoLibraryAddUsageDescription（写，保存输出）
final class PhotoLibraryService {
    static let shared = PhotoLibraryService()

    /// 相册写权限状态
    static var addAuthorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// 请求「仅添加」权限；返回是否授权。
    func requestAddPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        default:
            return false
        }
    }

    /// 保存本地视频文件到相册。
    func saveVideo(from url: URL) async throws {
        guard await requestAddPermission() else {
            throw AppError.permissionDenied(reason: "请在系统设置中允许「添加照片」权限后再试。")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: AppError.photoLibrarySaveFailed(underlying: error ?? NSError(domain: "Photos", code: -1, userInfo: [NSLocalizedDescriptionKey: "保存到相册失败。"])))
                }
            }
        }
    }
}
