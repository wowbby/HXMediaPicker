import XCTest
import UIKit
import AVFoundation
import HXPhotoPicker
@testable import HXMediaPicker

@MainActor
final class MediaPickerTests: XCTestCase {
    func testOriginalCameraPhotoSaveOptInOnlyChangesEditableSavedStandalonePhotos() {
        XCTAssertFalse(HXMediaPickerOptions().saveOriginalPhotoBeforeEditing)
        for source: HXMediaPickerSource in [.library, .camera] {
            for media: HXMediaPickerMediaType in [.photo, .video] {
                for editing in [false, true] {
                    for saving in [false, true] {
                        for optIn in [false, true] {
                            let options = HXMediaPickerOptions()
                            options.source = source
                            options.mediaType = media
                            options.allowsEditing = editing
                            options.saveToPhotoLibrary = saving
                            options.saveOriginalPhotoBeforeEditing = optIn
                            let camera = HXMediaPickerConfiguration.camera(options)
                            let savesOriginal = source == .camera && media == .photo && editing && saving && optIn
                            XCTAssertEqual(camera.allowsEditing, editing && media == .photo && !savesOriginal)
                            XCTAssertEqual(camera.isSaveSystemAlbum, saving)
                            XCTAssertTrue(camera.editor.usesLegacyCropLayout)
                            XCTAssertFalse(camera.isAutoBack)
                        }
                    }
                }
            }
        }
    }

    private func image(_ size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func writeOneSecondVideo(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 240
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "FixtureWriter", code: 1) }
        writer.startSession(atSourceTime: .zero)
        let written = expectation(description: "generated video fixture")
        var frame = 0
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "io.github.wowbby.hxmediapicker.tests.video")) {
            while input.isReadyForMoreMediaData && frame < 5 {
                var pixelBuffer: CVPixelBuffer?
                let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
                    kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
                guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                    XCTFail("Cannot create generated video frame")
                    writer.cancelWriting()
                    frame = 5
                    written.fulfill()
                    return
                }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let address = CVPixelBufferGetBaseAddress(buffer) {
                    memset(address, 0x55, CVPixelBufferGetDataSize(buffer))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 5)) else {
                    XCTFail("Generated video append failed: \(String(describing: writer.error))")
                    writer.cancelWriting()
                    frame = 5
                    written.fulfill()
                    return
                }
                frame += 1
                if frame == 5 {
                    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
                    input.markAsFinished()
                    writer.finishWriting { written.fulfill() }
                }
            }
        }
        wait(for: [written], timeout: 15)
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }

    func testRealVideoExportPreservesSourceAndCleansBridgeStagingBeforeCompletion() throws {
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory
        let fixtureDirectory = temp.appendingPathComponent("PickerTest-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureDirectory) }
        let source = fixtureDirectory.appendingPathComponent("input.mov")
        try writeOneSecondVideo(to: source)
        let stagingBefore = Set(try fileManager.contentsOfDirectory(atPath: temp.path)
            .filter { $0.hasPrefix("HXMediaPicker-") })
        let options = HXMediaPickerOptions()
        options.mediaType = .video
        var events: [String] = []
        options.didDismiss = { events.append("didDismiss") }
        let done = expectation(description: "real medium-quality video export")
        done.assertForOverFulfill = true
        var output: URL?
        let session = HXMediaPickerSession(options: options, completion: { result, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(error)
            XCTAssertEqual(result?.videoURLs.count, 1)
            XCTAssertEqual(result?.images.count, 0)
            output = result?.videoURLs.first
            events.append("completion")
            done.fulfill()
        }, cancel: { XCTFail("Video export must complete") })
        session.dismiss = { callback in
            events.append("dismiss")
            DispatchQueue.main.async { callback() }
        }
        session.resolve(assets: [PhotoAsset(localVideoAsset: LocalVideoAsset(videoURL: source))], isOriginal: false)
        wait(for: [done], timeout: 30)
        let outputURL = try XCTUnwrap(output)
        defer { try? fileManager.removeItem(at: outputURL) }
        XCTAssertNotEqual(outputURL, source)
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
        XCTAssertTrue(fileManager.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(AVURLAsset(url: outputURL).duration.seconds, 0)
        let stagingAfter = Set(try fileManager.contentsOfDirectory(atPath: temp.path)
            .filter { $0.hasPrefix("HXMediaPicker-") })
        XCTAssertEqual(stagingAfter, stagingBefore)
        XCTAssertEqual(events, ["dismiss", "didDismiss", "completion"])
        withExtendedLifetime(session) {}
    }

    func testOriginalResolutionAndSelectionOrderUsingRealPhotoAssets() {
        let done = expectation(description: "two original photos")
        done.assertForOverFulfill = true
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 2
        let first = image(CGSize(width: 2048, height: 1024), color: .red)
        let second = image(CGSize(width: 1200, height: 1600), color: .blue)
        let session = HXMediaPickerSession(options: options, completion: { result, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(error)
            XCTAssertEqual(result?.images.count, 2)
            XCTAssertEqual(result?.images.map(\.size), [first.size, second.size])
            XCTAssertEqual(result?.images.map { $0.cgImage?.width }, [2048, 1200])
            XCTAssertEqual(result?.images.map { $0.cgImage?.height }, [1024, 1600])
            XCTAssertEqual(result?.videoURLs.count, 0)
            XCTAssertEqual(result?.isOriginal, false)
            done.fulfill()
        }, cancel: { XCTFail("Selection must complete") })
        session.resolve(assets: [PhotoAsset(image: first), PhotoAsset(image: second)], isOriginal: false)
        wait(for: [done], timeout: 5)
        withExtendedLifetime(session) {}
    }

    func testMissingLocalFileFailsTheEntireSelectionWithoutPartialImages() {
        let done = expectation(description: "missing photo failure")
        done.assertForOverFulfill = true
        let session = HXMediaPickerSession(options: HXMediaPickerOptions(), completion: { result, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(result)
            XCTAssertEqual(error?.domain, "HXMediaPicker")
            XCTAssertEqual(error?.code, 5)
            done.fulfill()
        }, cancel: { XCTFail("Read failure must be an error") })
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let valid = PhotoAsset(image: image(CGSize(width: 30, height: 20), color: .green))
        session.resolve(assets: [valid, PhotoAsset(localImageAsset: LocalImageAsset(imageURL: missing))], isOriginal: true)
        wait(for: [done], timeout: 5)
        withExtendedLifetime(session) {}
    }

    func testTargetImageBoundsPreserveAspectRatioAndNeverUpscaleSmallImages() {
        let done = expectation(description: "aspect-fit previews")
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 3
        options.imageTargetSize = CGSize(width: 1920, height: 1080)
        let originals = [
            image(CGSize(width: 4000, height: 2000), color: .red),
            image(CGSize(width: 1000, height: 2000), color: .blue),
            image(CGSize(width: 320, height: 240), color: .green)
        ]
        let session = HXMediaPickerSession(options: options, completion: { result, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(error)
            XCTAssertEqual(result?.images.map(\.size), [
                CGSize(width: 1920, height: 960),
                CGSize(width: 540, height: 1080),
                CGSize(width: 320, height: 240)
            ])
            done.fulfill()
        }, cancel: { XCTFail("Preview conversion must complete") })
        session.resolve(assets: originals.map { PhotoAsset(image: $0) }, isOriginal: true)
        wait(for: [done], timeout: 10)
        withExtendedLifetime(session) {}
    }

    func testEmptySelectionIsAnError() {
        var calls = 0
        let session = HXMediaPickerSession(options: HXMediaPickerOptions(), completion: { result, error in
            XCTAssertNil(result)
            XCTAssertEqual(error?.code, 4)
            calls += 1
        }, cancel: { XCTFail("Empty result is not user cancellation") })
        session.resolve(assets: [], isOriginal: true)
        session.resolve(assets: [], isOriginal: true)
        XCTAssertEqual(calls, 1)
    }

    func testSuccessfulCompletionWaitsForDismissalAndIsDeliveredOnlyOnce() {
        var events: [String] = []
        var finishDismissal: (() -> Void)?
        let options = HXMediaPickerOptions()
        options.didDismiss = { events.append("didDismiss") }
        let session = HXMediaPickerSession(options: options, completion: { result, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(result)
            XCTAssertNil(error)
            events.append("completion")
        }, cancel: { XCTFail("Success must not cancel") })
        session.dismiss = { callback in
            events.append("dismiss")
            finishDismissal = callback
        }
        session.finish(result: HXMediaPickerResult(images: [], isOriginal: true))
        session.finish(error: NSError(domain: "late", code: 1))
        session.cancelSelection()
        XCTAssertEqual(events, ["dismiss"])
        finishDismissal?()
        XCTAssertEqual(events, ["dismiss", "didDismiss", "completion"])
        session.finish()
        XCTAssertEqual(events, ["dismiss", "didDismiss", "completion"])
    }

    func testBackgroundCancellationWaitsForDismissalAndIsDeliveredOnlyOnceOnMainThread() {
        let done = expectation(description: "cancel after dismiss")
        done.assertForOverFulfill = true
        var events: [String] = []
        let options = HXMediaPickerOptions()
        options.didDismiss = { events.append("didDismiss") }
        let session = HXMediaPickerSession(options: options, completion: { _, _ in
            XCTFail("User cancellation must not complete")
        }, cancel: {
            XCTAssertTrue(Thread.isMainThread)
            events.append("cancel")
            done.fulfill()
        })
        session.dismiss = { callback in
            XCTAssertTrue(Thread.isMainThread)
            events.append("dismiss")
            DispatchQueue.main.async(execute: callback)
        }
        DispatchQueue.global().async {
            session.cancelSelection()
            session.cancelSelection()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(events, ["dismiss", "didDismiss", "cancel"])
        withExtendedLifetime(session) {}
    }

    func testPhotoConfigurationKeepsEditingAndCameraPolicies() {
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 1
        options.allowsEditing = true
        options.cropOnly = true
        options.allowsCamera = false
        let config = HXMediaPickerConfiguration.picker(options)
        XCTAssertEqual(config.selectMode, .single)
        XCTAssertEqual(config.selectOptions, .photo)
        XCTAssertEqual(config.maximumSelectedCount, 1)
        XCTAssertEqual(config.editorOptions, .photo)
        XCTAssertFalse(config.previewView.bottomView.isHiddenEditButton)
        XCTAssertEqual(config.photoSelectionTapAction, .openEditor)
        XCTAssertTrue(config.editor.isFixedCropSizeState)
        XCTAssertFalse(config.photoList.allowAddCamera)
        options.automaticallyEditsSinglePhoto = false
        XCTAssertEqual(HXMediaPickerConfiguration.picker(options).photoSelectionTapAction, .preview)
    }

    func testSingleSelectionConfirmationKeepsTheDoneButtonAndEmbeddedCameraSavePolicy() {
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 1
        options.selectionRequiresConfirmation = true
        options.allowsEditing = false
        options.allowsCamera = true
        options.saveToPhotoLibrary = true
        let config = HXMediaPickerConfiguration.picker(options)
        XCTAssertEqual(config.maximumSelectedCount, 1)
        XCTAssertEqual(config.selectMode, .multiple)
        XCTAssertEqual(config.photoSelectionTapAction, .preview)
        XCTAssertFalse(config.previewView.disableFinishButtonWhenNotSelected,
                       "The Moments preset must not add a new confirmation requirement")
        XCTAssertTrue(config.previewView.bottomView.isHiddenEditButton)
        XCTAssertTrue(config.photoList.allowAddCamera)
        XCTAssertTrue(config.photoList.isSaveSystemAlbum)
        options.saveToPhotoLibrary = false
        XCTAssertFalse(HXMediaPickerConfiguration.picker(options).photoList.isSaveSystemAlbum)
    }

    func testVideoLimitsAndSavePolicyDoNotEnablePhotoEditing() {
        let options = HXMediaPickerOptions()
        options.mediaType = .video
        options.maximumSelectedCount = 9
        options.minimumVideoDuration = 2
        options.maximumVideoDuration = 60
        options.maximumVideoFileSize = 1024 * 1024
        options.saveToPhotoLibrary = true
        options.allowsEditing = true
        let picker = HXMediaPickerConfiguration.picker(options)
        let camera = HXMediaPickerConfiguration.camera(options)
        XCTAssertEqual(picker.selectOptions, .video)
        XCTAssertEqual(picker.maximumSelectedCount, 1)
        XCTAssertEqual(picker.minimumSelectedVideoDuration, 2)
        XCTAssertEqual(picker.maximumSelectedVideoDuration, 60)
        XCTAssertEqual(picker.maximumSelectedVideoFileSize, 1024 * 1024)
        XCTAssertTrue(picker.editorOptions.isEmpty)
        XCTAssertTrue(picker.previewView.bottomView.isHiddenEditButton)
        XCTAssertEqual(picker.photoSelectionTapAction, .preview)
        XCTAssertEqual(picker.videoSelectionTapAction, .preview,
                       "The Moments preset must not send business video selection into an editor")
        XCTAssertEqual(picker.selectMode, .single)
        XCTAssertEqual(camera.videoMinimumDuration, 2)
        XCTAssertEqual(camera.videoMaximumDuration, 60)
        XCTAssertTrue(camera.isSaveSystemAlbum)
        XCTAssertFalse(camera.allowsEditing)
    }

    func testNegativeLimitsAreNormalizedAndUnlimitedCameraRecordingUsesClickMode() {
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = -1
        options.minimumVideoDuration = -2
        options.maximumVideoDuration = -3
        options.maximumVideoFileSize = -4
        let picker = HXMediaPickerConfiguration.picker(options)
        XCTAssertEqual(picker.maximumSelectedCount, 1)
        XCTAssertEqual(picker.selectMode, .single)
        XCTAssertEqual(picker.minimumSelectedVideoDuration, 0)
        XCTAssertEqual(picker.maximumSelectedVideoDuration, 0)
        XCTAssertEqual(picker.maximumSelectedVideoFileSize, 0)
        XCTAssertEqual(HXMediaPickerConfiguration.camera(options).takePhotoMode, .click)
    }

    func testAutomaticLightAndDarkThemeConfiguration() {
        let options = HXMediaPickerOptions()
        options.themeColor = .systemOrange
        options.appearance = .automatic
        XCTAssertEqual(HXMediaPickerConfiguration.picker(options).appearanceStyle, .varied)
        options.appearance = .light
        XCTAssertEqual(HXMediaPickerConfiguration.picker(options).appearanceStyle, .normal)
        options.appearance = .dark
        let dark = HXMediaPickerConfiguration.picker(options)
        XCTAssertEqual(dark.appearanceStyle, .dark)
        XCTAssertEqual(dark.themeColor, .systemOrange)
        XCTAssertEqual(dark.photoList.bottomView.finishButtonDarkBackgroundColor, .systemOrange)
        XCTAssertEqual(dark.previewView.bottomView.finishButtonDarkBackgroundColor, .systemOrange)
        XCTAssertTrue(dark.photoList.photoToolbar == PhotoToolBarView.self)
        XCTAssertTrue(dark.previewView.photoToolbar == PhotoToolBarView.self)
    }

    func testReturningFromPreviewDoesNotWriteIntoAnAbsentSelectedStrip() throws {
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 9
        var config = HXMediaPickerConfiguration.picker(options)
        config.allowLoadPhotoLibrary = false
        let grid: PhotoToolBar = PhotoToolBarView(config, type: .picker)
        let preview: PhotoToolBar = PhotoToolBarView(config, type: .preview)
        let assets = (0..<9).map { _ in PhotoAsset(image: image(CGSize(width: 20, height: 20), color: .blue)) }
        preview.updateSelectedAssets(assets)
        preview.frame = CGRect(x: 0, y: 0, width: 320, height: preview.viewHeight)
        preview.layoutIfNeeded()
        XCTAssertNil(grid.selectViewOffset)
        let previewOffset = try XCTUnwrap(preview.selectViewOffset)
        // PickerTransition.popTransition synchronizes these even when only the
        // preview has a selected strip. This assignment crashed on the device.
        grid.selectViewOffset = previewOffset
        XCTAssertNil(grid.selectViewOffset)
        grid.selectViewOffset = nil
        preview.selectViewOffset = CGPoint(x: 24, y: 0)
        XCTAssertEqual(preview.selectViewOffset, CGPoint(x: 24, y: 0))
        preview.selectViewOffset = nil
        XCTAssertEqual(preview.selectViewOffset, CGPoint(x: 24, y: 0))

        config.photoList.bottomView.isShowSelectedView = true
        let gridWithStrip: PhotoToolBar = PhotoToolBarView(config, type: .picker)
        gridWithStrip.updateSelectedAssets(assets)
        gridWithStrip.frame = CGRect(x: 0, y: 0, width: 320, height: gridWithStrip.viewHeight)
        gridWithStrip.layoutIfNeeded()
        gridWithStrip.selectViewOffset = preview.selectViewOffset
        XCTAssertEqual(gridWithStrip.selectViewOffset, CGPoint(x: 24, y: 0))

        config.previewView.bottomView.isShowPreviewList = true
        let previewWithoutStrip: PhotoToolBar = PhotoToolBarView(config, type: .preview)
        previewWithoutStrip.selectViewOffset = preview.selectViewOffset
        XCTAssertNil(previewWithoutStrip.selectViewOffset)
    }

    func testClassicToolbarKeepsAllButtonsAboveTheActualWindowBottomSafeArea() throws {
        let window = try XCTUnwrap(UIApplication.shared.windows.first(where: \.isKeyWindow))
        let rootView = try XCTUnwrap(window.rootViewController?.view)
        rootView.layoutIfNeeded()
        XCTAssertGreaterThan(window.safeAreaInsets.bottom, 0, "Run this test on a home-indicator simulator")
        let options = HXMediaPickerOptions()
        options.maximumSelectedCount = 9
        var config = HXMediaPickerConfiguration.picker(options)
        config.allowLoadPhotoLibrary = false
        config.photoList.bottomView.isShowPrompt = false
        config.photoList.bottomView.isShowSelectedView = false
        let toolbar = PhotoToolBarView(config, type: .picker)
        rootView.addSubview(toolbar)
        defer { toolbar.removeFromSuperview() }
        toolbar.frame = CGRect(x: 0, y: rootView.bounds.height - toolbar.viewHeight,
                               width: rootView.bounds.width, height: toolbar.viewHeight)
        toolbar.setNeedsLayout()
        toolbar.layoutIfNeeded()
        XCTAssertEqual(toolbar.toolbarHeight, 50 + window.safeAreaInsets.bottom, accuracy: 0.5)
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { child -> [UIButton] in
                guard !child.isHidden else { return [] }
                return (child as? UIButton).map { [$0] } ?? buttons(in: child)
            }
        }
        let visibleButtons = buttons(in: toolbar)
        XCTAssertGreaterThanOrEqual(visibleButtons.count, 2)
        let safeBottom = rootView.bounds.height - window.safeAreaInsets.bottom
        for button in visibleButtons {
            let rect = button.convert(button.bounds, to: rootView)
            XCTAssertLessThanOrEqual(rect.maxY, safeBottom + 0.5, button.currentTitle ?? "toolbar button")
        }
    }
}
