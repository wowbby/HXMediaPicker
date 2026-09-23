import XCTest
import UIKit
@testable import HXPhotoPicker
@testable import HXMediaPicker

@MainActor
final class PreviewAppearanceLifecycleTests: XCTestCase {
    func testHostDismissRestoresStatusBarBeforeCancelAndPreservesCallbackChanges() throws {
        try withPresentedPicker { _, presenter, picker, grid, asset in
            _ = try self.pushPreview(from: grid, picker: picker, asset: asset)
            XCTAssertEqual(UIApplication.shared.statusBarStyle, .lightContent)
            let cancelled = self.expectation(description: "external dismissal cancellation")
            cancelled.assertForOverFulfill = true
            var cancelCount = 0
            picker.cancelHandler = { _ in
                cancelCount += 1
                XCTAssertEqual(UIApplication.shared.statusBarStyle, .darkContent,
                               "The host style must be restored before HX synchronously invokes cancel")
                // A host can immediately configure its next page from this callback.
                UIApplication.shared.statusBarStyle = .default
                cancelled.fulfill()
            }
            let dismissed = self.expectation(description: "host dismissal complete")
            presenter.dismiss(animated: false) { dismissed.fulfill() }
            self.wait(for: [cancelled, dismissed], timeout: 5)
            self.drainMainQueue()
            XCTAssertNil(presenter.presentedViewController)
            XCTAssertEqual(cancelCount, 1)
            XCTAssertEqual(UIApplication.shared.statusBarStyle, .default,
                           "A later disappearance callback must not overwrite the host's new style")
            // Session delivery uses this same fallback after UIKit dismissal.
            picker.restoreHostStatusBarStyle()
            XCTAssertEqual(UIApplication.shared.statusBarStyle, .default,
                           "Restoring an already-restored picker must be a no-op")
        }
    }

    func testAutomaticTraitsUpdateGridKeepPreviewDarkAndRestoreGridOnReturn() throws {
        try withPresentedPicker { window, _, picker, grid, asset in
            self.assertGrid(grid, picker: picker, style: .light)
            self.changeWindow(window, to: .dark)
            self.assertGrid(grid, picker: picker, style: .dark)

            let preview = try self.pushPreview(from: grid, picker: picker, asset: asset)
            for style: UIUserInterfaceStyle in [.light, .dark] {
                self.changeWindow(window, to: style)
                XCTAssertEqual(preview.traitCollection.userInterfaceStyle, style)
                XCTAssertEqual(preview.view.backgroundColor, .black)
                let appearance = try XCTUnwrap(preview.navigationItem.standardAppearance)
                XCTAssertEqual(appearance.backgroundColor, .black)
                XCTAssertEqual(appearance.titleTextAttributes[.foregroundColor] as? UIColor, .white)
                XCTAssertEqual(UIApplication.shared.statusBarStyle, .lightContent)
                let editTitle = String.textPreview.bottomView.editTitle.text
                let editButton = try XCTUnwrap(self.buttons(in: preview.photoToolbar)
                    .first { $0.currentTitle == editTitle })
                XCTAssertFalse(editButton.isHidden)
                XCTAssertEqual(editButton.titleColor(for: .normal), .white)
            }

            picker.popViewController(animated: false)
            self.drainMainQueue()
            XCTAssertTrue(picker.topViewController === grid)
            XCTAssertNil(grid.navigationItem.standardAppearance,
                         "The preview's page-owned black navigation appearance must not leak")
            self.assertGrid(grid, picker: picker, style: .dark)
            self.changeWindow(window, to: .light)
            self.assertGrid(grid, picker: picker, style: .light)
        }
    }

    private func withPresentedPicker(
        _ body: (UIWindow, UIViewController, HXMediaPickerController, PhotoPickerViewController, PhotoAsset) throws -> Void
    ) throws {
        guard Bundle.main.object(forInfoDictionaryKey: "UIViewControllerBasedStatusBarAppearance") as? Bool == false else {
            throw XCTSkip("Requires UIViewControllerBasedStatusBarAppearance=false in the host Info.plist")
        }
        let window = try XCTUnwrap(UIApplication.shared.windows.first(where: \.isKeyWindow))
        let presenter = try XCTUnwrap(window.rootViewController)
        XCTAssertNil(presenter.presentedViewController)
        let savedDefault = HXMediaPicker.defaultAppearance
        let savedPhotoAppearance = PhotoManager.shared.appearanceStyle
        let savedWindowStyle = window.overrideUserInterfaceStyle
        let savedStatusBarStyle = UIApplication.shared.statusBarStyle
        defer {
            HXMediaPicker.defaultAppearance = savedDefault
            changeWindow(window, to: savedWindowStyle)
            PhotoManager.shared.appearanceStyle = savedPhotoAppearance
            UIApplication.shared.statusBarStyle = savedStatusBarStyle
        }
        HXMediaPicker.defaultAppearance = .automatic
        changeWindow(window, to: .light)
        UIApplication.shared.statusBarStyle = .darkContent
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 9
        options.allowsEditing = true
        var config = HXMediaPickerConfiguration.picker(options)
        config.allowLoadPhotoLibrary = false
        config.photoList.bottomView.isShowPrompt = false
        XCTAssertEqual(config.appearanceStyle, .varied)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).image {
            UIColor.systemGreen.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        let asset = PhotoAsset(image: image)
        asset.isSelected = true
        let picker = HXMediaPickerController(config: config)
        picker.localAssetArray = [asset]
        picker.selectedAssetArray = [asset]
        picker.autoDismiss = false
        picker.finishHandler = { _, _ in XCTFail("Appearance changes must not complete selection") }
        picker.cancelHandler = { _ in XCTFail("Appearance changes must not cancel selection") }
        defer {
            picker.cancelHandler = nil
            if picker.presentingViewController != nil {
                let dismissed = expectation(description: "fixture dismissal")
                presenter.dismiss(animated: false) { dismissed.fulfill() }
                wait(for: [dismissed], timeout: 5)
            }
            drainMainQueue()
        }
        let presented = expectation(description: "permission-free picker presented")
        presenter.present(picker, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)
        drainMainQueue()
        let grid = try XCTUnwrap(picker.topViewController as? PhotoPickerViewController)
        try body(window, presenter, picker, grid, asset)
    }

    private func pushPreview(from grid: PhotoPickerViewController, picker: HXMediaPickerController,
                             asset: PhotoAsset) throws -> PhotoPreviewViewController {
        grid.pushPreviewViewController(previewAssets: [asset], currentPreviewIndex: 0,
                                       isPreviewSelect: true, animated: false)
        let preview = try XCTUnwrap(picker.topViewController as? PhotoPreviewViewController)
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            preview.viewDidAppear && preview.view.window != nil
        }, object: nil)
        wait(for: [appeared], timeout: 5)
        drainMainQueue()
        XCTAssertTrue(preview.previewAssets.first === asset)
        return preview
    }

    private func assertGrid(_ grid: PhotoPickerViewController, picker: HXMediaPickerController,
                            style: UIUserInterfaceStyle, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(grid.traitCollection.userInterfaceStyle, style, file: file, line: line)
        XCTAssertEqual(grid.view.backgroundColor, style == .dark ? .black : .white, file: file, line: line)
        XCTAssertEqual(picker.navigationBar.standardAppearance.backgroundColor,
                       style == .dark ? picker.config.navigationViewBackgroudDarkColor : picker.config.navigationViewBackgroundColor,
                       file: file, line: line)
        XCTAssertEqual(UIApplication.shared.statusBarStyle, style == .dark ? .lightContent : .default,
                       file: file, line: line)
    }

    private func changeWindow(_ window: UIWindow, to style: UIUserInterfaceStyle) {
        window.overrideUserInterfaceStyle = style
        window.setNeedsLayout()
        window.layoutIfNeeded()
        drainMainQueue()
    }

    private func drainMainQueue() {
        let settled = expectation(description: "appearance callbacks settled")
        DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        wait(for: [settled], timeout: 5)
    }

    private func buttons(in view: UIView) -> [UIButton] {
        view.subviews.flatMap { child in
            (child as? UIButton).map { [$0] } ?? buttons(in: child)
        }
    }
}
