import UIKit
import AVFoundation
import Photos
import HXPhotoPicker

@objcMembers public final class HXMediaPicker: NSObject {
    // HXPhotoPicker stores appearance/selection resources globally. Serialize presentation
    // so a second bridge request cannot change an already visible picker's configuration.
    private static var active: HXMediaPickerSession?

    @objc(presentFromViewController:options:completion:cancel:)
    public static func present(from viewController: UIViewController,
                               options: HXMediaPickerOptions,
                               completion: @escaping (HXMediaPickerResult?, NSError?) -> Void,
                               cancel: @escaping () -> Void) {
        HXMediaPickerSession.onMain {
            guard active == nil else {
                completion(nil, HXMediaPickerSession.error(1, "图片选择器正在使用中"))
                return
            }
            guard viewController.viewIfLoaded?.window != nil,
                  viewController.presentedViewController == nil,
                  !viewController.isBeingDismissed else {
                completion(nil, HXMediaPickerSession.error(2, "当前页面无法打开图片选择器"))
                return
            }
            let session = HXMediaPickerSession(options: options, completion: completion, cancel: cancel)
            session.release = { active = nil }
            active = session
            session.present(from: viewController)
        }
    }
}

// HX considers a camera complete once it delivers the saved original. Our editor
// can keep that camera session open, so observe its actual presentation lifetime
// independently of HX's internal completion flag.
final class HXMediaPickerCameraController: CameraController {
    private var appearedWhilePresented = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentingViewController != nil { appearedWhilePresented = true }
    }

    override func viewDidDisappear(_ animated: Bool) {
        let wasDismissed = appearedWhilePresented &&
            (isBeingDismissed || presentingViewController == nil)
        super.viewDidDisappear(animated)
        guard wasDismissed else { return }
        appearedWhilePresented = false
        // Let the host's dismissal finish before releasing the session/notifying
        // the caller. A full-screen cover keeps presentingViewController intact.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.presentingViewController == nil else { return }
            self.cancelHandler?(self)
        }
    }
}

// Owns presentation and asynchronous conversion until exactly one terminal callback.
// Internal visibility permits lifecycle/error-path tests without Photo Library permission.
final class HXMediaPickerSession {
    private let options: HXMediaPickerOptions
    private let completion: (HXMediaPickerResult?, NSError?) -> Void
    private let cancel: () -> Void
    private var controller: UIViewController?
    private var processing = false
    private var finished = false
    private var didPresent = false
    private var exportSession: AVAssetExportSession?
    private var loadingView: UIView?
    private var cameraEditor: EditorViewController?
    private var handledCameraAssetIdentifiers: Set<String> = []
    // Weak identity tracking rejects a delayed duplicate without retaining every
    // full-resolution original when the user cancels editing and takes another photo.
    private let handledCameraImages = NSHashTable<UIImage>(options: [.weakMemory, .objectPointerPersonality])
    var release: (() -> Void)?
    // An injectable dismissal operation also verifies callback ordering without UI animation.
    var dismiss: ((@escaping () -> Void) -> Void)?

    init(options: HXMediaPickerOptions,
         completion: @escaping (HXMediaPickerResult?, NSError?) -> Void,
         cancel: @escaping () -> Void) {
        self.options = options
        self.completion = completion
        self.cancel = cancel
    }

    static func onMain(_ operation: @escaping () -> Void) {
        if Thread.isMainThread { operation() } else { DispatchQueue.main.async(execute: operation) }
    }

    static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "HXMediaPicker", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func present(from presenter: UIViewController) {
        if options.source == .camera {
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                finish(error: Self.error(3, "当前设备无法使用相机"))
                return
            }
            let camera = HXMediaPickerCameraController(config: HXMediaPickerConfiguration.camera(options),
                                                       type: options.mediaType == .photo ? .photo : .video)
            configureCamera(camera)
        } else {
            let picker = PhotoPickerController(config: HXMediaPickerConfiguration.picker(options))
            picker.autoDismiss = false
            picker.finishHandler = { [weak self] result, _ in
                Self.onMain { self?.resolve(assets: result.photoAssets, isOriginal: result.isOriginal) }
            }
            picker.cancelHandler = { [weak self] _ in self?.cancelSelection() }
            controller = picker
        }
        guard let controller = controller else { return }
        if #available(iOS 13.0, *) {
            switch options.appearance {
            case .automatic: controller.overrideUserInterfaceStyle = .unspecified
            case .light: controller.overrideUserInterfaceStyle = .light
            case .dark: controller.overrideUserInterfaceStyle = .dark
            }
        }
        options.willPresent?()
        didPresent = true
        presenter.present(controller, animated: true)
    }

    // Internal so tests can supply a camera root without starting hardware capture.
    func configureCamera(_ camera: CameraController) {
        controller = camera
        let editsSavedOriginal = HXMediaPickerConfiguration.savesOriginalPhotoBeforeEditing(options)
        camera.completion = { [weak self, weak camera] result, asset, _ in
            Self.onMain {
                guard let self = self, let camera = camera,
                      self.controller === camera, !self.finished else { return }
                if case .image(let image) = result, editsSavedOriginal {
                    self.editSavedCameraPhoto(image, asset: asset, camera: camera)
                    return
                }
                guard self.beginProcessing() else { return }
                switch result {
                case .image(let image):
                    self.finish(result: .init(images: [image], isOriginal: true))
                case .video(let url):
                    self.exportVideo(url) { result in
                        // This URL is the bridge-owned camera recording, never a PHAsset URL.
                        try? FileManager.default.removeItem(at: url)
                        self.finishVideo(result)
                    }
                }
            }
        }
        camera.cancelHandler = { [weak self] _ in self?.cancelSelection() }
    }

    private func editSavedCameraPhoto(_ image: UIImage, asset: PHAsset?, camera: CameraController) {
        // HX calls completion only after its save succeeds. Keep its existing save
        // failure UI/retry behavior, and never edit or save a second time here.
        guard let asset = asset, !processing, cameraEditor == nil,
              !handledCameraAssetIdentifiers.contains(asset.localIdentifier),
              !handledCameraImages.contains(image),
              let cameraRoot = camera.viewControllers.first else { return }
        handledCameraAssetIdentifiers.insert(asset.localIdentifier)
        handledCameraImages.add(image)
        var config = camera.config.editor
        config.isAutoBack = false
        let editor = EditorViewController(EditorAsset(type: .image(image)), config: config)
        cameraEditor = editor
        editor.finishHandler = { [weak self] asset, editor in
            Self.onMain {
                guard let self = self, self.cameraEditor === editor,
                      self.beginProcessing() else { return }
                let image: UIImage?
                switch asset.result {
                case .image(let result, _):
                    // The editor's image field is only a preview. Deliver the actual
                    // export, preserving the caller's existing compression policy.
                    image = UIImage(contentsOfFile: result.url.path)
                case nil:
                    image = asset.type.image
                default:
                    image = nil
                }
                guard let image = image else {
                    self.finish(error: Self.error(5, "图片读取失败，请重试"))
                    return
                }
                self.finish(result: .init(images: [image], isOriginal: true))
            }
        }
        editor.cancelHandler = { [weak self, weak camera] editor in
            Self.onMain {
                guard let self = self, let camera = camera, !self.finished,
                      !self.processing, self.cameraEditor === editor else { return }
                self.cameraEditor = nil
                camera.popToRootViewController(animated: false)
            }
        }
        // Remove the already-confirmed capture preview. Editor cancellation must
        // return to a fresh capture, not offer a second save of this same photo.
        camera.setViewControllers([cameraRoot, editor], animated: false)
    }

    private func beginProcessing() -> Bool {
        guard !processing, !finished else { return false }
        processing = true
        if let view = controller?.view {
            view.isUserInteractionEnabled = false
            let panel = UIStackView()
            panel.axis = .vertical
            panel.alignment = .center
            panel.spacing = 12
            panel.isLayoutMarginsRelativeArrangement = true
            panel.layoutMargins = UIEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
            let background = UIView()
            background.backgroundColor = UIColor.black.withAlphaComponent(0.8)
            background.layer.cornerRadius = 12
            background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            panel.insertSubview(background, at: 0)
            let indicator = UIActivityIndicatorView(style: .whiteLarge)
            indicator.startAnimating()
            let label = UILabel()
            label.text = options.mediaType == .video ? "正在导出视频…" : "正在读取图片…"
            label.textColor = .white
            label.font = .systemFont(ofSize: 15)
            panel.addArrangedSubview(indicator)
            panel.addArrangedSubview(label)
            panel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                panel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            loadingView = panel
            UIAccessibility.post(notification: .announcement, argument: label.text)
        }
        return true
    }

    func resolve(assets: [PhotoAsset], isOriginal: Bool) {
        guard beginProcessing() else { return }
        guard !assets.isEmpty else {
            finish(error: Self.error(4, "没有读取到所选资源"))
            return
        }
        if options.mediaType == .video {
            // Video selection is limited to one asset per request.
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("HXMediaPicker-\(UUID().uuidString).mov")
            assets[0].getVideoURL(toFile: staging) { [weak self] result in
                Self.onMain {
                    guard let self = self else { return }
                    switch result {
                    case .success(let value):
                        self.exportVideo(value.url) {
                            try? FileManager.default.removeItem(at: staging)
                            self.finishVideo($0, isOriginal: isOriginal)
                        }
                    case .failure(let error):
                        try? FileManager.default.removeItem(at: staging)
                        self.finish(error: error as NSError)
                    }
                }
            }
            return
        }
        // Sequential requests preserve the user's selection order and avoid concurrent
        // full-resolution decoding spikes. A failed image fails the whole request.
        resolveImages(assets, index: 0, images: [], isOriginal: isOriginal)
    }

    private func resolveImages(_ assets: [PhotoAsset], index: Int, images: [UIImage], isOriginal: Bool) {
        guard index < assets.count else {
            finish(result: .init(images: images, isOriginal: isOriginal))
            return
        }
        var received = false
        let receive: (UIImage?) -> Void = { [weak self] image in
            Self.onMain {
                guard let self = self, !self.finished, !received else { return }
                received = true
                guard let image = image else {
                    self.finish(error: Self.error(5, "图片读取失败，请重试"))
                    return
                }
                self.resolveImages(assets, index: index + 1, images: images + [image], isOriginal: isOriginal)
            }
        }
        if options.imageTargetSize.width > 0 && options.imageTargetSize.height > 0 {
            let asset = assets[index]
            if let phAsset = asset.phAsset, !asset.isEdited {
                let request = PHImageRequestOptions()
                request.isNetworkAccessAllowed = true
                request.deliveryMode = .highQualityFormat
                request.resizeMode = .fast
                // HX's target-size iCloud fallback can emit a degraded image first.
                // Request directly and ignore degraded callbacks to return the final image.
                PHImageManager.default().requestImage(for: phAsset, targetSize: options.imageTargetSize,
                    contentMode: .aspectFit, options: request) { image, info in
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    receive(image)
                }
            } else {
                let target = options.imageTargetSize
                asset.getImage { image in
                    DispatchQueue.global(qos: .userInitiated).async {
                        receive(image.map { Self.fit($0, within: target) })
                    }
                }
            }
        } else {
            // nil compressionQuality loads edited output first, otherwise original image data.
            // Callers remain responsible for any additional JPEG or byte-size compression.
            assets[index].getImage(completion: receive)
        }
    }

    private static func fit(_ image: UIImage, within target: CGSize) -> UIImage {
        guard image.size.width > 0, image.size.height > 0 else { return image }
        let ratio = min(1, min(target.width / (image.size.width * image.scale),
                               target.height / (image.size.height * image.scale)))
        let size = CGSize(width: max(1, floor(image.size.width * image.scale * ratio)),
                          height: max(1, floor(image.size.height * image.scale * ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func exportVideo(_ url: URL, completion: @escaping (Result<URL, NSError>) -> Void) {
        let asset = AVURLAsset(url: url)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            completion(.failure(Self.error(6, "视频导出失败")))
            return
        }
        let fileType: AVFileType = exporter.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        guard exporter.supportedFileTypes.contains(fileType) else {
            completion(.failure(Self.error(7, "不支持的视频格式")))
            return
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileType == .mp4 ? "mp4" : "mov")
        exporter.outputURL = output
        exporter.outputFileType = fileType
        exporter.shouldOptimizeForNetworkUse = true
        exportSession = exporter
        exporter.exportAsynchronously { [weak self] in
            Self.onMain {
                self?.exportSession = nil
                if exporter.status == .completed {
                    completion(.success(output))
                } else {
                    try? FileManager.default.removeItem(at: output)
                    completion(.failure(exporter.error as NSError? ?? Self.error(6, "视频导出失败")))
                }
            }
        }
    }

    private func finishVideo(_ result: Result<URL, NSError>, isOriginal: Bool = true) {
        switch result {
        case .success(let url): finish(result: .init(videoURLs: [url], isOriginal: isOriginal))
        case .failure(let error): finish(error: error)
        }
    }

    func cancelSelection() {
        Self.onMain {
            // HX can emit a disappearance callback while a finish/export is in progress.
            guard !self.processing else { return }
            self.finish()
        }
    }

    func finish(result: HXMediaPickerResult? = nil, error: NSError? = nil) {
        guard !finished else { return }
        finished = true
        cameraEditor = nil
        loadingView?.removeFromSuperview()
        loadingView = nil
        let deliver = {
            self.controller = nil
            self.release?()
            self.release = nil
            if self.didPresent || self.dismiss != nil { self.options.didDismiss?() }
            if result != nil || error != nil { self.completion(result, error) } else { self.cancel() }
        }
        if let dismiss = dismiss {
            dismiss(deliver)
        } else if let controller = controller, controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: deliver)
        } else {
            deliver()
        }
    }
}
