import XCTest
import UIKit
@testable import HXPhotoPicker
@testable import HXMediaPicker

@MainActor
final class LegacyCropEditorTests: XCTestCase {
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
