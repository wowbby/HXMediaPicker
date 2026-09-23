import XCTest
import UIKit
import Photos
@testable import HXPhotoPicker
@testable import HXMediaPicker

private final class SavedCameraPhoto: PHAsset, @unchecked Sendable {
    private let identifier = UUID().uuidString
    override var localIdentifier: String { identifier }
}

// Exercises the real navigation/editor/session without camera hardware or Photos writes.
private final class CameraCaptureTestRoot: UIViewController, CameraViewControllerProtocol {
    weak var delegate: CameraViewControllerDelegate?
    required init(config: CameraConfiguration, type: CameraController.CaptureType) {
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class LegacyCropEditorTests: XCTestCase {
    private func originalCameraOptions() -> HXMediaPickerOptions {
        let options = HXMediaPickerOptions()
        options.source = .camera
        options.allowsEditing = true
        options.saveToPhotoLibrary = true
        options.saveOriginalPhotoBeforeEditing = true
        return options
    }

    private func presentCamera(_ session: HXMediaPickerSession, options: HXMediaPickerOptions) throws -> CameraController {
        var config = HXMediaPickerConfiguration.camera(options)
        config.cameraViewController = CameraCaptureTestRoot.self
        let camera = HXMediaPickerCameraController(config: config, type: .photo)
        session.configureCamera(camera)
        let window = try XCTUnwrap(UIApplication.shared.windows.first(where: \.isKeyWindow))
        let presenter = try XCTUnwrap(window.rootViewController)
        XCTAssertNil(presenter.presentedViewController)
        presenter.present(camera, animated: false)
        return camera
    }

    private func cameraFixture() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1800), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1200, height: 1800))
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 1200, y: 0, width: 1200, height: 1800))
        }
    }

    private func loadedCameraEditor(_ camera: CameraController) throws -> EditorViewController {
        let editor = try XCTUnwrap(camera.topViewController as? EditorViewController)
        let cropView = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? EditorView }.first)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cropView.image != nil && cropView.state == .edit
        }, object: nil)
        wait(for: [loaded], timeout: 10)
        editor.view.layoutIfNeeded()
        return editor
    }

    func testCameraWithoutOriginalSaveOptInKeepsExistingCompletionBehavior() throws {
        let options = originalCameraOptions()
        options.saveOriginalPhotoBeforeEditing = false
        let original = cameraFixture()
        let completed = expectation(description: "existing camera completion")
        completed.assertForOverFulfill = true
        let session = HXMediaPickerSession(options: options, completion: { result, error in
            XCTAssertNil(error)
            XCTAssertTrue(result?.images.first === original)
            XCTAssertEqual(result?.isOriginal, true)
            completed.fulfill()
        }, cancel: { XCTFail("Existing completion must still succeed") })
        let camera = try presentCamera(session, options: options)
        XCTAssertTrue(camera.config.allowsEditing)
        camera.completion?(.image(original), nil, nil)
        camera.completion?(.image(original), nil, nil)
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(camera.viewControllers.count, 1)
        withExtendedLifetime(session) {}
    }

    func testSavedCameraPhotoEditCancelReturnsToCaptureAndIgnoresDuplicateCaptureCallbacks() throws {
        let options = originalCameraOptions()
        var cancels = 0
        let cancelled = expectation(description: "whole camera cancelled once")
        cancelled.assertForOverFulfill = true
        let session = HXMediaPickerSession(options: options, completion: { _, _ in
            XCTFail("Cancelling the editor must not finish the request")
        }, cancel: { cancels += 1; cancelled.fulfill() })
        let camera = try presentCamera(session, options: options)
        let root = try XCTUnwrap(camera.viewControllers.first)
        let original = cameraFixture()
        let saved = SavedCameraPhoto()
        camera.completion?(.image(original), nil, nil)
        XCTAssertTrue(camera.topViewController === root, "Do not edit without a successful original save")
        camera.cameraViewController(try XCTUnwrap(root as? CameraViewControllerProtocol),
                                    didFinishWithResult: .image(original), phAsset: saved, location: nil)
        let editor = try loadedCameraEditor(camera)
        XCTAssertTrue(editor.config.usesLegacyCropLayout)
        XCTAssertFalse(editor.config.isAutoBack)
        XCTAssertEqual(editor.config.legacyCropFinishTitle, "选择")
        XCTAssertEqual(camera.viewControllers.count, 2)
        camera.completion?(.image(original), saved, nil)
        XCTAssertTrue(camera.topViewController === editor)
        try button("cancel", in: editor).sendActions(for: .touchUpInside)
        XCTAssertTrue(camera.topViewController === root)
        XCTAssertEqual(cancels, 0)
        camera.completion?(.image(original), saved, nil)
        camera.completion?(.image(original), SavedCameraPhoto(), nil)
        XCTAssertTrue(camera.topViewController === root, "A delayed duplicate must not reopen an already-cancelled edit")
        camera.completion?(.image(cameraFixture()), SavedCameraPhoto(), nil)
        let next = try loadedCameraEditor(camera)
        XCTAssertFalse(next === editor)
        try button("cancel", in: next).sendActions(for: .touchUpInside)
        camera.cameraViewController(didCancel: try XCTUnwrap(root as? CameraViewControllerProtocol))
        camera.cancelHandler?(camera)
        wait(for: [cancelled], timeout: 5)
        XCTAssertEqual(cancels, 1)
        withExtendedLifetime(session) {}
    }

    private func assertHostDismissReleasesSavedPhotoSession(afterCancellingEditor: Bool) throws {
        let options = originalCameraOptions()
        var events: [String] = []
        let cancelled = expectation(description: "host dismissal releases camera session")
        cancelled.assertForOverFulfill = true
        let session = HXMediaPickerSession(options: options, completion: { _, _ in
            XCTFail("Host dismissal is cancellation")
        }, cancel: { events.append("cancel"); cancelled.fulfill() })
        // The public entry point installs its active = nil closure here.
        session.release = { events.append("release") }
        let camera = try presentCamera(session, options: options)
        let host = try XCTUnwrap(camera.presentingViewController)
        let root = try XCTUnwrap(camera.viewControllers.first as? CameraViewControllerProtocol)
        camera.cameraViewController(root, didFinishWithResult: .image(cameraFixture()),
                                    phAsset: SavedCameraPhoto(), location: nil)
        XCTAssertTrue(camera.isDismissed, "Reproduce HX's completed flag before continuing our session")
        let editor = try loadedCameraEditor(camera)
        if afterCancellingEditor {
            try button("cancel", in: editor).sendActions(for: .touchUpInside)
            XCTAssertTrue(camera.topViewController === root)
        }
        XCTAssertTrue(events.isEmpty)
        host.dismiss(animated: false) { events.append("hostDismissed") }
        wait(for: [cancelled], timeout: 5)
        XCTAssertEqual(events, ["hostDismissed", "release", "cancel"])
        XCTAssertNil(host.presentedViewController)
        XCTAssertNil(session.release)
        camera.cancelHandler?(camera)
        XCTAssertEqual(events, ["hostDismissed", "release", "cancel"])
        withExtendedLifetime(session) {}
    }

    func testHostDismissDuringSavedPhotoEditingReleasesTheSessionOnce() throws {
        try assertHostDismissReleasesSavedPhotoSession(afterCancellingEditor: false)
    }

    func testHostDismissAfterCancellingSavedPhotoEditingReleasesTheSessionOnce() throws {
        try assertHostDismissReleasesSavedPhotoSession(afterCancellingEditor: true)
    }

    func testFullScreenCoverOfSavedPhotoEditorDoesNotEndTheCameraSession() throws {
        let options = originalCameraOptions()
        var releases = 0
        var cancels = 0
        let cancelled = expectation(description: "only real dismissal cancels")
        cancelled.assertForOverFulfill = true
        let session = HXMediaPickerSession(options: options, completion: { _, _ in
            XCTFail("Covering the editor must not complete")
        }, cancel: { cancels += 1; cancelled.fulfill() })
        session.release = { releases += 1 }
        let camera = try presentCamera(session, options: options)
        let host = try XCTUnwrap(camera.presentingViewController)
        let root = try XCTUnwrap(camera.viewControllers.first as? CameraViewControllerProtocol)
        camera.cameraViewController(root, didFinishWithResult: .image(cameraFixture()),
                                    phAsset: SavedCameraPhoto(), location: nil)
        let editor = try loadedCameraEditor(camera)
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        let covered = expectation(description: "full-screen cover applied")
        camera.present(cover, animated: false) { covered.fulfill() }
        wait(for: [covered], timeout: 5)
        XCTAssertNil(camera.view.window)
        XCTAssertNotNil(camera.presentingViewController)
        XCTAssertTrue(camera.presentedViewController === cover)
        XCTAssertEqual(cancels, 0)
        XCTAssertEqual(releases, 0)
        let uncovered = expectation(description: "full-screen cover dismissed")
        cover.dismiss(animated: false) { uncovered.fulfill() }
        wait(for: [uncovered], timeout: 5)
        XCTAssertTrue(camera.topViewController === editor)
        XCTAssertNotNil(camera.view.window)
        XCTAssertEqual(cancels, 0)
        XCTAssertEqual(releases, 0)
        host.dismiss(animated: false)
        wait(for: [cancelled], timeout: 5)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(releases, 1)
        withExtendedLifetime(session) {}
    }

    func testSavedCameraPhotoRealCropReturnsExportedFileInsteadOfThumbnailOnceAfterDismissal() throws {
        let options = originalCameraOptions()
        var events: [String] = []
        var exportURL: URL?
        var thumbnailWidth = 0
        var returnedImage: UIImage?
        let completed = expectation(description: "real camera crop delivered once")
        completed.assertForOverFulfill = true
        options.didDismiss = { events.append("didDismiss") }
        let session = HXMediaPickerSession(options: options, completion: { result, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(error)
            returnedImage = result?.images.first
            events.append("completion")
            completed.fulfill()
        }, cancel: { XCTFail("Crop completion must not cancel") })
        let camera = try presentCamera(session, options: options)
        session.dismiss = { callback in
            events.append("dismiss")
            camera.dismiss(animated: false, completion: callback)
        }
        let original = cameraFixture()
        let saved = SavedCameraPhoto()
        let root = try XCTUnwrap(camera.viewControllers.first as? CameraViewControllerProtocol)
        camera.cameraViewController(root, didFinishWithResult: .image(original), phAsset: saved, location: nil)
        let editor = try loadedCameraEditor(camera)
        let handler = try XCTUnwrap(editor.finishHandler)
        editor.finishHandler = { asset, controller in
            exportURL = asset.result?.url
            thumbnailWidth = asset.result?.image?.cgImage?.width ?? 0
            handler(asset, controller)
            handler(asset, controller)
            camera.cancelHandler?(camera)
        }
        let cropView = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? EditorView }.first)
        cropView.isFixedRatio = true
        cropView.setAspectRatio(CGSize(width: 1, height: 1), animated: false)
        try button("finish", in: editor).sendActions(for: .touchUpInside)
        wait(for: [completed], timeout: 15)
        let file = try XCTUnwrap(exportURL)
        defer { try? FileManager.default.removeItem(at: file) }
        let exported = try XCTUnwrap(UIImage(contentsOfFile: file.path)?.cgImage)
        let delivered = try XCTUnwrap(returnedImage?.cgImage)
        XCTAssertEqual(delivered.width, exported.width)
        XCTAssertEqual(delivered.height, exported.height)
        XCTAssertEqual(delivered.width, delivered.height)
        XCTAssertGreaterThan(delivered.width, thumbnailWidth)
        XCTAssertGreaterThan(delivered.width, 1000)
        XCTAssertEqual(events, ["dismiss", "didDismiss", "completion"])
        XCTAssertNil(camera.presentingViewController)
        withExtendedLifetime(session) {}
    }

    func testSavedCameraPhotoMissingEditorExportFailsOnceWithoutReturningOriginalOrThumbnail() throws {
        let options = originalCameraOptions()
        let failed = expectation(description: "missing export error once")
        failed.assertForOverFulfill = true
        let session = HXMediaPickerSession(options: options, completion: { result, error in
            XCTAssertNil(result)
            XCTAssertEqual(error?.code, 5)
            failed.fulfill()
        }, cancel: { XCTFail("A missing edit export is an error") })
        let camera = try presentCamera(session, options: options)
        let original = cameraFixture()
        camera.completion?(.image(original), SavedCameraPhoto(), nil)
        let editor = try loadedCameraEditor(camera)
        let missing = ImageEditedResult(image: original,
            urlConfig: EditorURLConfig(fileName: "missing-\(UUID().uuidString).jpg", type: .temp),
            imageType: .normal, data: nil)
        let asset = EditorAsset(type: .image(original), result: .image(missing, .init(cropSize: nil)))
        editor.finishHandler?(asset, editor)
        editor.finishHandler?(asset, editor)
        camera.cancelHandler?(camera)
        wait(for: [failed], timeout: 5)
        withExtendedLifetime(session) {}
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func button(_ name: String, in editor: EditorViewController) throws -> UIButton {
        try XCTUnwrap(descendants(editor.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "hx.legacyCrop.\(name)" })
    }

    private func presentEditor(multiple: Bool,
                               imageSize: CGSize = CGSize(width: 400, height: 200),
                               usesLegacyCropLayout: Bool = true,
                               loadAsJPEG: Bool = false,
                               finish: EditorViewController.FinishHandler? = nil) throws -> EditorViewController {
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = multiple ? 9 : 1
        options.allowsEditing = true
        var config: EditorConfiguration
        if usesLegacyCropLayout {
            config = HXMediaPickerConfiguration.picker(options).editor
        } else {
            // Start from the library defaults to catch accidental changes to
            // other fixed-crop clients that do not opt into the legacy layout.
            config = EditorConfiguration()
            config.isFixedCropSizeState = true
            config.photo.defaultSelectedToolOption = .cropSize
            XCTAssertFalse(config.usesLegacyCropLayout)
        }
        config.modalPresentationStyle = .fullScreen
        config.isAutoBack = false
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: imageSize.width / 2, height: imageSize.height))
            UIColor.blue.setFill()
            $0.fill(CGRect(x: imageSize.width / 2, y: 0,
                           width: imageSize.width / 2, height: imageSize.height))
        }
        let assetType: EditorAsset.AssetType = loadAsJPEG ? .imageData(try XCTUnwrap(image.jpegData(compressionQuality: 0.95))) : .image(image)
        let editor = EditorViewController(EditorAsset(type: assetType), config: config, finish: finish)
        let window = try XCTUnwrap(UIApplication.shared.windows.first(where: \.isKeyWindow))
        let presenter = try XCTUnwrap(window.rootViewController)
        XCTAssertNil(presenter.presentedViewController)
        presenter.present(editor, animated: false)
        let cropView = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? EditorView }.first)
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cropView.image != nil && cropView.state == .edit
        }, object: nil)
        wait(for: [loaded], timeout: 10)
        editor.view.layoutIfNeeded()
        return editor
    }

    private func dismissEditor(_ editor: EditorViewController) {
        let dismissed = expectation(description: "editor dismissed")
        editor.dismiss(animated: false) { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 5)
    }

    private func assertImageGestures(enabled: Bool, in editor: EditorViewController,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let cropView = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? EditorView }.first,
                                    file: file, line: line)
        let adjuster = try XCTUnwrap(cropView.adjusterView, file: file, line: line)
        let imageScrollView = try XCTUnwrap(adjuster.scrollView, file: file, line: line)
        XCTAssertEqual(imageScrollView.isScrollEnabled, enabled,
                       "Photo panning must follow the editor's legacy-layout policy", file: file, line: line)
        XCTAssertEqual(imageScrollView.panGestureRecognizer.isEnabled, enabled, file: file, line: line)
        let pinch = try XCTUnwrap(imageScrollView.pinchGestureRecognizer, file: file, line: line)
        XCTAssertEqual(pinch.isEnabled, enabled,
                       "Photo zooming must follow the editor's legacy-layout policy", file: file, line: line)

        // Lock only the image underneath the crop frame. Its resize handles
        // still need their own enabled gestures and interactive view hierarchy.
        let cropControls = try XCTUnwrap(adjuster.frameView.controlView, file: file, line: line)
        XCTAssertFalse(cropControls.controls.isEmpty, file: file, line: line)
        for gesture in cropControls.controls {
            XCTAssertTrue(gesture is UIPanGestureRecognizer, file: file, line: line)
            XCTAssertTrue(gesture.isEnabled, "Crop handles must remain draggable", file: file, line: line)
            let handle = try XCTUnwrap(gesture.view, file: file, line: line)
            XCTAssertNotNil(handle.window, file: file, line: line)
            var current: UIView? = handle
            while let view = current {
                XCTAssertTrue(view.isUserInteractionEnabled,
                              "A crop handle or its ancestor blocks interaction", file: file, line: line)
                current = view.superview
            }
        }
    }

    private func assertGridRemainsVisibleAfterIdle(in editor: EditorViewController,
                                                   file: StaticString = #filePath,
                                                   line: UInt = #line) throws {
        // The upstream crop overlay hides its grid after one second. Run the
        // main loop past that timer and its fade rather than checking only entry.
        let idle = expectation(description: "crop overlay has passed its automatic hide delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { idle.fulfill() }
        wait(for: [idle], timeout: 5)
        editor.view.layoutIfNeeded()
        let grid = try XCTUnwrap(descendants(editor.view).first {
            $0.accessibilityIdentifier == "hx.editor.cropGrid"
        }, file: file, line: line)
        XCTAssertNotNil(grid.window, file: file, line: line)
        var current: UIView? = grid
        while let view = current {
            XCTAssertFalse(view.isHidden, "The grid or an ancestor is hidden", file: file, line: line)
            XCTAssertGreaterThan(view.alpha, 0.9, "The grid faded after editing", file: file, line: line)
            current = view.superview
        }
        let strokes = try XCTUnwrap(grid.layer.sublayers?.compactMap { $0 as? CAShapeLayer }
            .first { $0.path?.isEmpty == false }, "The visible grid needs a drawn path", file: file, line: line)
        XCTAssertGreaterThan(strokes.opacity, 0.9, file: file, line: line)
        XCTAssertFalse(strokes.isHidden, file: file, line: line)
        try assertImageGestures(enabled: false, in: editor, file: file, line: line)
    }

    private func attachSnapshot(of editor: EditorViewController, name: String) {
        let snapshot = UIGraphicsImageRenderer(bounds: editor.view.bounds).image { _ in
            editor.view.drawHierarchy(in: editor.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLegacyEditorShowsOnlyBasicActionsAboveTheSafeArea() throws {
        let editor = try presentEditor(multiple: false)
        defer { dismissEditor(editor) }
        let names = ["cancel", "ratio", "finish", "rotate", "reset"]
        let controls = try names.map { try button($0, in: editor) }
        for control in controls {
            XCTAssertFalse(control.isHidden)
            XCTAssertGreaterThan(control.alpha, 0.9)
            XCTAssertLessThanOrEqual(control.convert(control.bounds, to: editor.view).maxY,
                                     editor.view.bounds.height - editor.view.safeAreaInsets.bottom + 0.5)
        }
        XCTAssertEqual(controls[0].frame.midY, controls[1].frame.midY, accuracy: 1)
        XCTAssertEqual(controls[1].frame.midY, controls[2].frame.midY, accuracy: 1)
        XCTAssertLessThan(controls[3].frame.maxY, controls[0].frame.minY + 1)
        let visibleButtons = descendants(editor.view).compactMap { $0 as? UIButton }.filter { button in
            guard !button.bounds.isEmpty,
                  !button.convert(button.bounds, to: editor.view).intersection(editor.view.bounds).isEmpty else { return false }
            var current: UIView? = button
            while let view = current {
                if view.isHidden || view.alpha < 0.01 { return false }
                current = view.superview
            }
            return true
        }
        XCTAssertEqual(Set(visibleButtons.compactMap(\.accessibilityIdentifier)),
                       Set(names.map { "hx.legacyCrop.\($0)" }))
        XCTAssertEqual(visibleButtons.count, 5, "No new editing tools: \(visibleButtons.map { String(describing: type(of: $0)) + ":" + ($0.currentTitle ?? "") + ":" + String(describing: $0.frame) })")
        try assertGridRemainsVisibleAfterIdle(in: editor)
        attachSnapshot(of: editor, name: "Legacy crop editor - wide photo after idle")
    }

    func testSingleSelectionCanFinishWithoutChangingTheImage() throws {
        let completed = expectation(description: "original image selected")
        let editor = try presentEditor(multiple: false) { asset, _ in
            XCTAssertNil(asset.result, "Unchanged images should keep their original data")
            XCTAssertEqual(asset.type.image?.size, CGSize(width: 400, height: 200))
            completed.fulfill()
        }
        defer { dismissEditor(editor) }
        let finish = try button("finish", in: editor)
        XCTAssertTrue(finish.isEnabled)
        finish.sendActions(for: .touchUpInside)
        wait(for: [completed], timeout: 10)
    }

    func testDefaultFixedCropEditorStillAllowsPhotoPanAndPinch() throws {
        let editor = try presentEditor(multiple: false, usesLegacyCropLayout: false)
        defer { dismissEditor(editor) }
        let cropView = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? EditorView }.first)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cropView.adjusterView.frameView.controlView.isUserInteractionEnabled
        }, object: nil)
        wait(for: [ready], timeout: 5)
        try assertImageGestures(enabled: true, in: editor)
    }

    func testMultipleSelectionRequiresAnEditAndExportsTheRotatedImage() throws {
        let completed = expectation(description: "rotated image exported")
        let editor = try presentEditor(multiple: true) { asset, _ in
            guard let result = asset.result, let image = result.image else {
                XCTFail("Rotation must produce an edited image")
                completed.fulfill()
                return
            }
            XCTAssertEqual(image.size.width / image.size.height, 0.5, accuracy: 0.01)
            try? FileManager.default.removeItem(at: result.url)
            completed.fulfill()
        }
        defer { dismissEditor(editor) }
        let finish = try button("finish", in: editor)
        XCTAssertFalse(finish.isEnabled, "Old multi-selection crop requires a change")
        let rotate = try button("rotate", in: editor)
        rotate.sendActions(for: .touchUpInside)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in finish.isEnabled }, object: nil)
        wait(for: [changed], timeout: 5)
        try assertGridRemainsVisibleAfterIdle(in: editor)
        let reset = try button("reset", in: editor)
        XCTAssertTrue(reset.isEnabled)
        reset.sendActions(for: .touchUpInside)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !finish.isEnabled }, object: nil)
        wait(for: [restored], timeout: 5)
        try assertGridRemainsVisibleAfterIdle(in: editor)
        rotate.sendActions(for: .touchUpInside)
        let rotatedAgain = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in finish.isEnabled }, object: nil)
        wait(for: [rotatedAgain], timeout: 5)
        try assertGridRemainsVisibleAfterIdle(in: editor)
        finish.sendActions(for: .touchUpInside)
        wait(for: [completed], timeout: 15)
    }

    func testPortraitPhotoKeepsItsGridAfterChangingRatioAndExportsASquare() throws {
        let completed = expectation(description: "square image exported")
        let editor = try presentEditor(multiple: false, imageSize: CGSize(width: 390, height: 844)) { asset, _ in
            guard let result = asset.result, let image = result.image else {
                XCTFail("Changing the crop ratio must produce an edited image")
                completed.fulfill()
                return
            }
            XCTAssertEqual(image.size.width / image.size.height, 1, accuracy: 0.01)
            XCTAssertGreaterThan(image.size.width, 0)
            try? FileManager.default.removeItem(at: result.url)
            completed.fulfill()
        }
        defer { dismissEditor(editor) }
        try assertGridRemainsVisibleAfterIdle(in: editor)
        // A synthetic portrait with the old screenshot's 390:844 aspect ratio
        // lets visual review compare the crop frame and both bottom action rows.
        attachSnapshot(of: editor, name: "Legacy crop editor - portrait 390x844 after idle")
        let cropView = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? EditorView }.first)
        // This is the public crop API used by the ratio action. Avoid invoking
        // UIAlertAction's private handler through KVC in this integration test.
        cropView.isFixedRatio = true
        cropView.setAspectRatio(CGSize(width: 1, height: 1), animated: true)
        try assertGridRemainsVisibleAfterIdle(in: editor)
        XCTAssertEqual(cropView.aspectRatio.width / cropView.aspectRatio.height, 1, accuracy: 0.01)
        attachSnapshot(of: editor, name: "Legacy crop editor - square crop after ratio change")
        try button("finish", in: editor).sendActions(for: .touchUpInside)
        wait(for: [completed], timeout: 15)
    }
    func testLargeJPEGLoadsAsynchronouslyAndExportsSquareCrop() throws {
        let completed = expectation(description: "large JPEG crop exported")
        let maxPixels = UIScreen.main.scale * max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let editor = try presentEditor(multiple: false,
                                      imageSize: CGSize(width: 6000, height: 4000),
                                      loadAsJPEG: true) { asset, _ in
            guard let result = asset.result,
                  let image = UIImage(contentsOfFile: result.url.path),
                  let cgImage = image.cgImage else {
                XCTFail("A large JPEG must produce a decoded edited image")
                completed.fulfill()
                return
            }
            XCTAssertEqual(Double(cgImage.width) / Double(cgImage.height), 1, accuracy: 0.01)
            XCTAssertGreaterThan(cgImage.width, 1000)
            XCTAssertLessThanOrEqual(CGFloat(max(cgImage.width, cgImage.height)), maxPixels + 1)
            try? FileManager.default.removeItem(at: result.url)
            completed.fulfill()
        }
        defer { dismissEditor(editor) }
        let cropView = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? EditorView }.first)
        let loadedImage = try XCTUnwrap(cropView.image?.cgImage)
        XCTAssertLessThanOrEqual(CGFloat(max(loadedImage.width, loadedImage.height)), maxPixels + 1)
        XCTAssertGreaterThan(max(loadedImage.width, loadedImage.height), 2000)
        cropView.isFixedRatio = true
        cropView.setAspectRatio(CGSize(width: 1, height: 1), animated: true)
        try assertGridRemainsVisibleAfterIdle(in: editor)
        try button("finish", in: editor).sendActions(for: .touchUpInside)
        wait(for: [completed], timeout: 15)
    }

}
