import XCTest
import UIKit
@testable import HXPhotoPicker
@testable import HXMediaPicker

@MainActor
final class PickerCancelNavigationTests: XCTestCase {
    func testLivePhotoMarkHonorsClassicAppearanceAcrossReuse() throws {
        guard #available(iOS 26.0, *), !PhotoManager.isIos26Compatibility else {
            throw XCTSkip("Requires the iOS 26 glass appearance path")
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).image {
            UIColor.systemGreen.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        let asset = PhotoAsset(image: image)
        asset.mediaSubType = .livePhoto
        let cell = PreviewLivePhotoViewCell(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        var config = PreviewViewConfiguration.LivePhotoMark()
        config.allowShow = true
        config.allowMutedShow = true
        cell.liveMarkConfig = config
        cell.photoAsset = asset
        cell.layoutIfNeeded()
        XCTAssertFalse(try XCTUnwrap(cell.contentView.subviews.first { $0 is UIToolbar }).isHidden)

        cell.usesClassicAppearance = true
        cell.layoutIfNeeded()
        XCTAssertFalse(cell.contentView.subviews.contains { $0 is UIToolbar },
                       "Classic preview must not retain a Liquid Glass toolbar")
        let classicMark = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIControl }.first)
        XCTAssertFalse(classicMark.isHidden)
        XCTAssertGreaterThan(classicMark.bounds.width, 0)
        let mutedContainer = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        XCTAssertFalse(mutedContainer.isHidden)

        cell.usesClassicAppearance = false
        cell.layoutIfNeeded()
        XCTAssertTrue(classicMark.isHidden)
        XCTAssertTrue(mutedContainer.isHidden)
        let glassMark = try XCTUnwrap(cell.contentView.subviews.first { $0 is UIToolbar })
        XCTAssertFalse(glassMark.isHidden)
        config.allowShow = false
        config.allowMutedShow = false
        cell.liveMarkConfig = config
        XCTAssertTrue(glassMark.isHidden)
        config.allowShow = true
        config.allowMutedShow = true
        cell.liveMarkConfig = config
        XCTAssertFalse(glassMark.isHidden, "Reused Live Photo cells must restore the enabled mark")

        cell.usesClassicAppearance = true
        cell.layoutIfNeeded()
        XCTAssertFalse(cell.contentView.subviews.contains { $0 is UIToolbar })
        XCTAssertFalse(classicMark.isHidden)
        XCTAssertFalse(mutedContainer.isHidden)
    }

    private func dismissAndWait(_ controller: UIViewController) {
        guard controller.presentingViewController != nil else { return }
        let dismissed = expectation(description: "test modal dismissal completed")
        controller.dismiss(animated: false) {
            DispatchQueue.main.async { dismissed.fulfill() }
        }
        wait(for: [dismissed], timeout: 5)
    }

    func testAssetUpdateBeforePreviewLoadsKeepsLatestAssetsAndClampsPageWithoutLoadingTheView() {
        let config = HXMediaPickerConfiguration.picker(HXMediaPickerOptions())
        let preview = PhotoPreviewViewController(config: config)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image {
            UIColor.systemGreen.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let first = PhotoAsset(image: image)
        let second = PhotoAsset(image: image)
        XCTAssertFalse(preview.isViewLoaded)
        XCTAssertNil(preview.collectionView)

        // Call exactly the callback entry point that previously dereferenced the
        // collection view before UIKit had created the pushed preview's view.
        preview.currentPreviewIndex = 12
        preview.updateAsstes(for: [first, second])
        XCTAssertFalse(preview.isViewLoaded, "Fetching data must not eagerly load preview UI")
        XCTAssertNil(preview.collectionView)
        XCTAssertEqual(preview.currentPreviewIndex, 1)
        XCTAssertTrue(preview.previewAssets.first === first)
        XCTAssertTrue(preview.previewAssets.last === second)

        preview.currentPreviewIndex = -2
        preview.updateAsstes(for: [second])
        XCTAssertFalse(preview.isViewLoaded)
        XCTAssertNil(preview.collectionView)
        XCTAssertEqual(preview.currentPreviewIndex, 0)
        XCTAssertEqual(preview.previewAssets.count, 1)
        XCTAssertTrue(preview.previewAssets.first === second)
    }

    func testEmptyAssetUpdateBeforePreviewLoadsPopsOnlyAfterItsFirstAppearance() throws {
        for usesSystemNavigationTransition in [false, true] {
            try exercisePendingEmptyPreviewUpdate(replacesEmptyUpdate: false,
                                                  usesSystemNavigationTransition: usesSystemNavigationTransition)
        }
    }

    func testNonemptyAssetUpdateCancelsPendingEmptyPreviewExitBeforeFirstAppearance() throws {
        try exercisePendingEmptyPreviewUpdate(replacesEmptyUpdate: true)
    }

    private func exercisePendingEmptyPreviewUpdate(replacesEmptyUpdate: Bool,
                                                   usesSystemNavigationTransition: Bool = true) throws {
        let window = try XCTUnwrap(UIApplication.shared.windows.first(where: \.isKeyWindow))
        let presenter = try XCTUnwrap(window.rootViewController)
        XCTAssertNil(presenter.presentedViewController)
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 9
        var config = HXMediaPickerConfiguration.picker(options)
        config.allowLoadPhotoLibrary = false
        config.previewView.usesSystemNavigationTransition = usesSystemNavigationTransition
        let picker = PhotoPickerController(config: config)
        // Feed the exact update callback synchronously instead of depending on
        // Photos/local-asset fetch timing to hit the uninitialized-view window.
        picker.fetchData.delegate = nil
        let root = UIViewController()
        picker.setViewControllers([root], animated: false)
        let preview = PhotoPreviewViewController(config: config)
        preview.currentPreviewIndex = 4
        preview.updateAsstes(for: [])
        XCTAssertFalse(preview.isViewLoaded)
        XCTAssertNil(preview.collectionView)
        XCTAssertEqual(preview.currentPreviewIndex, 0)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).image {
            UIColor.systemGreen.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        let asset = PhotoAsset(image: image)
        if replacesEmptyUpdate {
            preview.updateAsstes(for: [asset])
            XCTAssertFalse(preview.isViewLoaded)
            XCTAssertNil(preview.collectionView)
        }
        var finishCount = 0
        var cancelCount = 0
        picker.finishHandler = { _, _ in finishCount += 1 }
        picker.cancelHandler = { _ in cancelCount += 1 }
        let presented = expectation(description: "picker presented before pending preview update")
        presenter.present(picker, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)
        defer { dismissAndWait(picker) }
        XCTAssertTrue(picker.topViewController === root)

        picker.delegate = preview
        picker.pushViewController(preview, animated: false)
        XCTAssertTrue(picker.topViewController === preview,
                      "An empty fetch must not pop during the preview's initial appearance")
        if replacesEmptyUpdate {
            // Even a nonanimated push may enter the navigation stack before
            // UIKit loads and displays the new controller's view.
            let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                preview.viewDidAppear
            }, object: nil)
            wait(for: [appeared], timeout: 5)
            XCTAssertTrue(preview.isViewLoaded)
            // Cross the queued empty-exit check and another main-loop turn.
            // This catches a stale deferred closure closing a now-valid page.
            let settled = expectation(description: "pending preview exit check drained")
            DispatchQueue.main.async {
                DispatchQueue.main.async { settled.fulfill() }
            }
            wait(for: [settled], timeout: 5)
            XCTAssertTrue(picker.topViewController === preview)
            XCTAssertEqual(picker.viewControllers.count, 2)
            XCTAssertTrue(preview.previewAssets.first === asset)
            XCTAssertEqual(preview.currentPreviewIndex, 0)
        } else {
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                picker.topViewController === root && picker.transitionCoordinator == nil
            }, object: nil)
            wait(for: [returned], timeout: 5)
            XCTAssertEqual(picker.viewControllers.count, 1)
            XCTAssertTrue(preview.isViewLoaded)
            XCTAssertTrue(preview.viewDidAppear, "An empty preview must finish its first appearance before exiting")
        }
        XCTAssertTrue(presenter.presentedViewController === picker)
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(cancelCount, 0)
    }

    func testPreviewPopKeepsSelectionWhenOnlyPreviewHasASelectedThumbnailStrip() throws {
        // Keep covering the upstream zoom transition's offset-copy crash even
        // though the app now opts into UIKit page navigation by default.
        try exercisePreviewRoundTrip(usesSystemNavigationTransition: false)
    }

    func testStandardPreviewPagePushAndPopKeepsSelectionAndRestoresNavigationBar() throws {
        try exercisePreviewRoundTrip(usesSystemNavigationTransition: true)
    }

    func testStandardPreviewPageStillUsesSystemPopAfterCancellingLegacyCropEditor() throws {
        try exercisePreviewRoundTrip(usesSystemNavigationTransition: true, visitsEditor: true)
    }

    func testStandardPreviewBackTransitionKeepsNavigationControlsAndDoesNotCancelSelection() throws {
        try exercisePreviewRoundTrip(usesSystemNavigationTransition: true, capturesNavigationTransition: true)
    }

    func testClassicNavigationAlsoSupportsDarkAppearance() throws {
        try exercisePreviewRoundTrip(usesSystemNavigationTransition: true,
                                     capturesNavigationTransition: true, appearance: .dark)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func attachWindowSnapshot(_ window: UIWindow, name: String, afterScreenUpdates: Bool,
                                      rect: CGRect? = nil) {
        // The navigation bar belongs to the navigation controller, outside
        // preview.view. Capture the whole window so its back/cancel controls
        // and their transition are visible in the test attachment.
        let region = rect ?? window.bounds
        let snapshot = UIGraphicsImageRenderer(size: region.size).image { context in
            context.cgContext.translateBy(x: -region.minX, y: -region.minY)
            context.cgContext.clip(to: region)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: afterScreenUpdates)
        }
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settleNavigationLayout(_ picker: PhotoPickerController, in window: UIWindow) {
        window.layoutIfNeeded()
        picker.view.layoutIfNeeded()
        picker.navigationBar.layoutIfNeeded()
        // UIKit can keep updating its glass/button layout after the navigation
        // transition coordinator completes. Only label idle frames as stable.
        let settled = expectation(description: "navigation bar idle layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        window.layoutIfNeeded()
        picker.navigationBar.layoutIfNeeded()
    }

    private func navigationSnapshotRect(_ picker: PhotoPickerController, in window: UIWindow) -> CGRect {
        let bar = picker.navigationBar.convert(picker.navigationBar.bounds, to: window)
        let height = min(window.bounds.height, max(200, bar.maxY + 16))
        return CGRect(x: window.bounds.minX, y: window.bounds.minY, width: window.bounds.width, height: height)
    }

    private func activatePreviewBack(_ preview: PhotoPreviewViewController, picker: PhotoPickerController) {
        let item = preview.navigationItem.leftBarButtonItems?.first ?? preview.navigationItem.leftBarButtonItem
        if let customView = item?.customView,
           let button = descendants(customView).compactMap({ $0 as? UIButton }).first {
            button.sendActions(for: .touchUpInside)
        } else if let item = item, let action = item.action {
            XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
        } else {
            // UIKit's implicit back button has no public UIBarButtonItem action.
            // Exercise its navigation operation without private selectors/KVC.
            XCTAssertTrue(picker.popViewController(animated: true) === preview)
        }
    }

    private func assertSystemPageNavigation(_ preview: PhotoPreviewViewController,
                                            grid: PhotoPickerViewController,
                                            picker: PhotoPickerController) throws {
        XCTAssertTrue(picker.delegate === preview, "The preview must own navigation again after cancelling the editor")
        if #available(iOS 26.0, *) {
            XCTAssertTrue(try XCTUnwrap(preview.navigationItem.leftBarButtonItem).hidesSharedBackground)
            XCTAssertTrue(try XCTUnwrap(preview.navigationItem.rightBarButtonItem).hidesSharedBackground)
        }
        let popGesture = try XCTUnwrap(picker.interactivePopGestureRecognizer)
        XCTAssertTrue(popGesture.isEnabled)
        XCTAssertEqual(popGesture.delegate?.gestureRecognizerShouldBegin?(popGesture), true,
                       "Plain Back must retain UIKit edge-swipe navigation")
        XCTAssertNil(preview.navigationController(picker, animationControllerFor: .push,
                                                 from: grid, to: preview))
        XCTAssertNil(preview.navigationController(picker, animationControllerFor: .pop,
                                                 from: preview, to: grid))
        let background = try XCTUnwrap(preview.view.backgroundColor,
                                       "UIKit page navigation cannot rely on the custom zoom animator to set a background")
        XCTAssertEqual(background.resolvedColor(with: preview.traitCollection).cgColor.alpha, 1, accuracy: 0.01)
        XCTAssertEqual(background, .black)
        XCTAssertEqual(preview.navigationItem.standardAppearance?.backgroundColor, .black)
        XCTAssertNil(preview.navigationItem.standardAppearance?.backgroundEffect)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(preview.navigationItem.leftBarButtonItem?.tintColor, .white)
        }
        XCTAssertEqual(preview.preferredStatusBarStyle, .lightContent)
        XCTAssertEqual(picker.preferredStatusBarStyle, .lightContent)
        XCTAssertEqual(preview.view.alpha, 1, accuracy: 0.01)
        XCTAssertFalse(preview.view.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer } ?? false,
                       "The old full-screen drag-to-shrink gesture must not compete with UIKit navigation")
    }

    private func exercisePreviewRoundTrip(usesSystemNavigationTransition: Bool,
                                          visitsEditor: Bool = false,
                                          capturesNavigationTransition: Bool = false,
                                          appearance: HXMediaPickerAppearance = .light) throws {
        let window = try XCTUnwrap(UIApplication.shared.windows.first(where: \.isKeyWindow))
        let presenter = try XCTUnwrap(window.rootViewController)
        XCTAssertNil(presenter.presentedViewController)
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 9
        options.allowsEditing = visitsEditor
        options.appearance = appearance
        var config = HXMediaPickerConfiguration.picker(options)
        XCTAssertTrue(config.previewView.usesSystemNavigationTransition,
                      "The app bridge must opt into standard page navigation")
        config.previewView.usesSystemNavigationTransition = usesSystemNavigationTransition
        config.allowLoadPhotoLibrary = false
        config.photoList.bottomView.isShowPrompt = false
        XCTAssertFalse(config.photoList.bottomView.isShowSelectedView)
        XCTAssertFalse(config.previewView.bottomView.isShowPreviewList)
        XCTAssertTrue(config.previewView.bottomView.isShowSelectedView)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        let selectedAsset = PhotoAsset(image: image)
        selectedAsset.isSelected = true
        let picker = HXMediaPickerController(config: config)
        // Disabled system-library loading still asynchronously refreshes local assets.
        // Register the fixture in both lists, as a real selected local photo would be.
        picker.localAssetArray = [selectedAsset]
        picker.selectedAssetArray = [selectedAsset]
        picker.autoDismiss = false
        var finishCount = 0
        var cancelCount = 0
        picker.finishHandler = { _, _ in finishCount += 1 }
        picker.cancelHandler = { _ in cancelCount += 1 }
        func navigationState() -> String {
            "selected=\(picker.selectedAssetArray.count), finish=\(finishCount), cancel=\(cancelCount), " +
            "stack=\(picker.viewControllers), presented=\(String(describing: presenter.presentedViewController))"
        }
        let presented = expectation(description: "picker presented for preview round trip")
        presenter.present(picker, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)
        defer { dismissAndWait(picker) }
        let grid = try XCTUnwrap(picker.topViewController as? PhotoPickerViewController)
        // Permission-free asset fixtures may skip the asynchronous registration
        // path. Install the real Cancel item before inspecting bar transitions.
        grid.initNavItems()

        // Without Photos permission the library substitutes an empty grid toolbar.
        // Mount its actual configured toolbar so the real pop transition exercises
        // offset synchronization into a toolbar with no selected-view instance.
        grid.photoToolbar.removeFromSuperview()
        let gridToolbar = PhotoToolBarView(config, type: .picker)
        gridToolbar.toolbarDelegate = grid
        grid.photoToolbar = gridToolbar
        if capturesNavigationTransition {
            // On iOS 26 layoutToolbar uses coordinates in bottomContainerView.
            // Mount the visual fixture there exactly as initToolbar does.
            grid.isShowToolbar = true
            if let container = grid.bottomContainerView {
                container.addSubview(gridToolbar)
            } else {
                grid.view.addSubview(gridToolbar)
            }
            grid.listView.assetResult = PhotoFetchAssetResult(assets: [selectedAsset],
                                                              selectedAsset: selectedAsset,
                                                              normalAssets: [selectedAsset], photoCount: 1)
            grid.view.setNeedsLayout()
            grid.view.layoutIfNeeded()
            grid.layoutToolbar()
            grid.listView.scrollTo(selectedAsset, animated: false)
        } else {
            // Preserve the existing transition-crash fixture unchanged.
            grid.view.addSubview(gridToolbar)
            gridToolbar.frame = CGRect(x: 0, y: grid.view.bounds.height - gridToolbar.viewHeight,
                                       width: grid.view.bounds.width, height: gridToolbar.viewHeight)
        }
        gridToolbar.updateSelectedAssets(picker.selectedAssetArray)
        gridToolbar.selectedAssetDidChanged(picker.selectedAssetArray)
        gridToolbar.layoutIfNeeded()
        XCTAssertNil(gridToolbar.selectViewOffset)
        if capturesNavigationTransition {
            let resourceVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                grid.listView.getCell(for: selectedAsset)?.photoView.imageView.image != nil
            }, object: nil)
            wait(for: [resourceVisible], timeout: 5)
            settleNavigationLayout(picker, in: window)
            let toolbarRect = gridToolbar.convert(gridToolbar.bounds, to: grid.view)
            XCTAssertGreaterThan(toolbarRect.minY, grid.view.bounds.midY,
                                 "The visual fixture's toolbar must be at the bottom, outside the navigation bar")
            XCTAssertNil(picker.navigationBar.standardAppearance.backgroundEffect)
            XCTAssertNil(grid.topContainerView)
            XCTAssertNil(grid.bottomContainerView)
            let title = try XCTUnwrap(grid.titleView as? AlbumTitleView)
            // Exercise the actual title control after replacing the iOS 26 menu.
            grid.albumView.assetCollections = [PhotoAssetCollection(albumName: "Test Album", coverImage: image)]
            grid.albumView.reloadData()
            title.sendActions(for: .touchUpInside)
            XCTAssertTrue(title.isSelected)
            XCTAssertFalse(grid.albumBackgroudView.isHidden)
            XCTAssertFalse(grid.listView.view.isUserInteractionEnabled)
            title.sendActions(for: .touchUpInside)
            XCTAssertFalse(title.isSelected)
            XCTAssertTrue(grid.listView.view.isUserInteractionEnabled)
            settleNavigationLayout(picker, in: window)
            XCTAssertTrue(grid.albumBackgroudView.isHidden)
            let cancel = try XCTUnwrap(grid.navigationItem.leftBarButtonItems?.first?.customView as? PhotoTextCancelItemView)
            if #available(iOS 15.0, *) { XCTAssertNil(cancel.button.configuration) }
            attachWindowSnapshot(window, name: "Classic grid - full window", afterScreenUpdates: true)
            attachWindowSnapshot(window, name: "Navigation baseline - grid before preview", afterScreenUpdates: true,
                                 rect: navigationSnapshotRect(picker, in: window))
        }

        let pushed = expectation(description: "preview push animation completed")
        DispatchQueue.main.async {
            XCTAssertEqual(picker.selectedAssetArray.count, 1, "The selected fixture must survive modal presentation")
            XCTAssertTrue(picker.topViewController === grid,
                          "Before preview push, top is \(String(describing: picker.topViewController))")
            grid.photoToolbar(didPreviewClick: gridToolbar)
            guard let pushTransition = picker.transitionCoordinator else {
                XCTFail("A real animated preview push is required; top is \(String(describing: picker.topViewController))")
                pushed.fulfill()
                return
            }
            pushTransition.animate(alongsideTransition: nil) { context in
                XCTAssertFalse(context.isCancelled)
                // UIKit clears its transition coordinator after completion handlers.
                DispatchQueue.main.async { pushed.fulfill() }
            }
        }
        wait(for: [pushed], timeout: 5)
        let preview = try XCTUnwrap(picker.topViewController as? PhotoPreviewViewController,
                                    "After push: \(navigationState())")
        let previewToolbar = try XCTUnwrap(preview.photoToolbar as? PhotoToolBarView)
        XCTAssertNotNil(previewToolbar.selectViewOffset)
        XCTAssertEqual(picker.viewControllers.count, 2)
        let editTitle = String.textPreview.bottomView.editTitle.text
        let editButton = try XCTUnwrap(descendants(previewToolbar).compactMap { $0 as? UIButton }
            .first { $0.currentTitle == editTitle })
        XCTAssertEqual(editButton.isHidden, !visitsEditor,
                       "The preview Edit button must follow the app's editing permission")
        XCTAssertEqual(editButton.titleColor(for: .normal), .white)

        if usesSystemNavigationTransition {
            try assertSystemPageNavigation(preview, grid: grid, picker: picker)
            if capturesNavigationTransition {
                settleNavigationLayout(picker, in: window)
            }
            attachWindowSnapshot(window,
                                 name: capturesNavigationTransition ? "Navigation stable - preview before back" :
                                    (visitsEditor ? "Preview with editing allowed - full window" :
                                        "Preview with editing disabled - full window"),
                                 afterScreenUpdates: true,
                                 rect: capturesNavigationTransition ? navigationSnapshotRect(picker, in: window) : nil)
        }
        if visitsEditor {
            let editorPushed = expectation(description: "legacy crop editor push completed")
            DispatchQueue.main.async {
                preview.photoToolbar(didEditClick: previewToolbar)
                guard let transition = picker.transitionCoordinator else {
                    XCTFail("The real preview Edit action must animate into the crop editor")
                    editorPushed.fulfill()
                    return
                }
                transition.animate(alongsideTransition: nil) { context in
                    XCTAssertFalse(context.isCancelled)
                    DispatchQueue.main.async { editorPushed.fulfill() }
                }
            }
            wait(for: [editorPushed], timeout: 10)
            let editor = try XCTUnwrap(picker.topViewController as? EditorViewController)
            XCTAssertEqual(picker.viewControllers.count, 3)
            let cropView = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? EditorView }.first)
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                cropView.image != nil && cropView.state == .edit
            }, object: nil)
            wait(for: [loaded], timeout: 10)
            let cancelButton = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? UIButton }
                .first { $0.accessibilityIdentifier == "hx.legacyCrop.cancel" })
            let editorReturned = expectation(description: "legacy crop cancellation returned to preview")
            DispatchQueue.main.async {
                cancelButton.sendActions(for: .touchUpInside)
                guard let transition = picker.transitionCoordinator else {
                    XCTFail("The real crop Cancel button must animate back to the preview")
                    editorReturned.fulfill()
                    return
                }
                transition.animate(alongsideTransition: nil) { context in
                    XCTAssertFalse(context.isCancelled)
                    DispatchQueue.main.async { editorReturned.fulfill() }
                }
            }
            wait(for: [editorReturned], timeout: 10)
            XCTAssertTrue(picker.topViewController === preview)
            XCTAssertEqual(picker.viewControllers.count, 2)
            XCTAssertNil(selectedAsset.editedResult, "Cancelling crop must preserve the selected original")
            try assertSystemPageNavigation(preview, grid: grid, picker: picker)
        }
        if usesSystemNavigationTransition && !capturesNavigationTransition {
            // Simulate the public full-screen preview state without invoking a
            // private tap selector. Popping this page must reveal the grid bar.
            preview.statusBarShouldBeHidden = true
            picker.setNavigationBarHidden(true, animated: false)
            XCTAssertTrue(picker.isNavigationBarHidden)
        }

        let returned = expectation(description: "preview pop animation completed")
        let sampled = capturesNavigationTransition ? expectation(description: "navigation pop frames sampled") : nil
        sampled?.expectedFulfillmentCount = 3
        let sampleRect = capturesNavigationTransition ? navigationSnapshotRect(picker, in: window) : nil
        DispatchQueue.main.async {
            if capturesNavigationTransition {
                let started = ProcessInfo.processInfo.systemUptime
                for delay in [0.1, 0.25, 0.4] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        let elapsed = ProcessInfo.processInfo.systemUptime - started
                        self.attachWindowSnapshot(window,
                                                  name: String(format: "Preview back at %.2fs (target %.2fs)", elapsed, delay),
                                                  afterScreenUpdates: false, rect: sampleRect)
                        sampled?.fulfill()
                    }
                }
                self.activatePreviewBack(preview, picker: picker)
            } else {
                let popped = picker.popViewController(animated: true)
                XCTAssertTrue(popped === preview)
            }
            guard let popTransition = picker.transitionCoordinator else {
                XCTFail("A real animated preview pop is required")
                returned.fulfill()
                return
            }
            popTransition.animate(alongsideTransition: nil) { context in
                XCTAssertFalse(context.isCancelled)
                DispatchQueue.main.async { returned.fulfill() }
            }
        }
        wait(for: [returned] + (sampled.map { [$0] } ?? []), timeout: 5)
        if capturesNavigationTransition {
            settleNavigationLayout(picker, in: window)
            attachWindowSnapshot(window, name: "Navigation stable - grid after preview back", afterScreenUpdates: true,
                                 rect: navigationSnapshotRect(picker, in: window))
        }
        XCTAssertTrue(presenter.presentedViewController === picker)
        XCTAssertTrue(picker.topViewController === grid)
        XCTAssertNil(grid.navigationItem.standardAppearance,
                     "The preview's black navigation appearance must not leak into the grid")
        XCTAssertEqual(picker.config.statusBarStyle, config.statusBarStyle)
        XCTAssertEqual(picker.navigationBar.standardAppearance.backgroundColor,
                       appearance == .dark ? config.navigationViewBackgroudDarkColor : config.navigationViewBackgroundColor)
        XCTAssertEqual(picker.viewControllers.count, 1)
        XCTAssertEqual(picker.selectedAssetArray.count, 1)
        XCTAssertTrue(picker.selectedAssetArray.first === selectedAsset)
        XCTAssertNil(gridToolbar.selectViewOffset)
        if usesSystemNavigationTransition {
            XCTAssertFalse(picker.isNavigationBarHidden, "Returning from full-screen preview must restore the grid navigation bar")
        }
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(cancelCount, 0)
    }

    func testLeftCancelClosesTheWholePickerBeforeNotifyingTheCaller() throws {
        let window = try XCTUnwrap(UIApplication.shared.windows.first(where: \.isKeyWindow))
        let presenter = try XCTUnwrap(window.rootViewController)
        XCTAssertNil(presenter.presentedViewController)

        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 9
        var config = HXMediaPickerConfiguration.picker(options)
        // Exercise real navigation/presentation without prompting for photo permission.
        config.allowLoadPhotoLibrary = false
        let picker = PhotoPickerController(config: config)
        let grid = try XCTUnwrap(picker.viewControllers.first as? PhotoPickerViewController)
        XCTAssertEqual(picker.viewControllers.count, 1, "The grid must be the root, without an album page underneath")

        var events: [String] = []
        options.didDismiss = { events.append("didDismiss") }
        let cancelled = expectation(description: "picker dismissed before cancellation callback")
        cancelled.assertForOverFulfill = true
        let session = HXMediaPickerSession(options: options, completion: { _, _ in
            XCTFail("Cancel must not return a selected result")
        }, cancel: {
            XCTAssertNil(presenter.presentedViewController)
            events.append("cancel")
            cancelled.fulfill()
        })
        session.dismiss = { completion in
            events.append("dismiss")
            picker.dismiss(animated: false, completion: completion)
        }
        picker.autoDismiss = false
        picker.cancelHandler = { _ in session.cancelSelection() }
        let presented = expectation(description: "picker presented")
        presenter.present(picker, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)
        defer { dismissAndWait(picker) }
        XCTAssertTrue(presenter.presentedViewController === picker)

        // Even with navigation history, the explicit Cancel control must dismiss
        // the modal picker rather than act as the navigation controller's Back item.
        let previousPage = UIViewController()
        picker.setViewControllers([previousPage, grid], animated: false)
        XCTAssertTrue(picker.topViewController === grid)

        // The library normally registers navigation items after assets load. A rotation
        // refresh uses that same registration path, allowing a permission-free test.
        grid.deviceOrientationDidChanged(notify: Notification(name: UIDevice.orientationDidChangeNotification))
        let leftItems = try XCTUnwrap(grid.navigationItem.leftBarButtonItems)
        XCTAssertEqual(leftItems.count, 1)
        XCTAssertTrue(grid.navigationItem.rightBarButtonItems?.isEmpty ?? true)
        let cancelView = try XCTUnwrap(leftItems.first?.customView as? PhotoTextCancelItemView)
        let button = try XCTUnwrap(cancelView.subviews.compactMap { $0 as? UIButton }.first)
        button.sendActions(for: .touchUpInside)
        wait(for: [cancelled], timeout: 5)
        XCTAssertEqual(events, ["dismiss", "didDismiss", "cancel"])
        XCTAssertEqual(picker.viewControllers.count, 2, "Cancellation must dismiss, not pop the navigation stack")
        XCTAssertTrue(picker.topViewController === grid)
        withExtendedLifetime(session) {}
    }
}
