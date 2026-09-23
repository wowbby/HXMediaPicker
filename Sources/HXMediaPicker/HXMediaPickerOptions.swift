import UIKit
import HXPhotoPicker

@objc public enum HXMediaPickerSource: Int { case library, camera }
@objc public enum HXMediaPickerMediaType: Int { case photo, video }
@objc public enum HXMediaPickerAppearance: Int { case automatic, light, dark }

@objcMembers public final class HXMediaPickerOptions: NSObject {
    public var source: HXMediaPickerSource = .library
    public var mediaType: HXMediaPickerMediaType = .photo
    public var maximumSelectedCount: Int = 1
    /// Keep a checkmark and Done button even when the maximum count is one.
    public var selectionRequiresConfirmation = false
    public var allowsEditing = false
    public var automaticallyEditsSinglePhoto = true
    /// Retained for Objective-C callers; editable photos use the legacy basic crop UI.
    public var cropOnly = false
    public var allowsCamera = false
    public var saveToPhotoLibrary = false
    public var minimumVideoDuration: Int = 0
    public var maximumVideoDuration: Int = 0
    /// Bytes; zero means unlimited.
    public var maximumVideoFileSize: Int = 0
    /// CGSizeZero preserves the original/edited image resolution.
    public var imageTargetSize: CGSize = .zero
    /// Automatic follows the presenting application's effective appearance.
    public var appearance: HXMediaPickerAppearance = .automatic
    /// WeChat green (#07C160); callers can still override the selected-state accent.
    public var themeColor = UIColor(red: 7.0 / 255, green: 193.0 / 255, blue: 96.0 / 255, alpha: 1)
    public var willPresent: (() -> Void)?
    public var didDismiss: (() -> Void)?
}

@objcMembers public final class HXMediaPickerResult: NSObject {
    public let images: [UIImage]
    public let videoURLs: [URL]
    public let isOriginal: Bool

    @nonobjc init(images: [UIImage] = [], videoURLs: [URL] = [], isOriginal: Bool) {
        self.images = images
        self.videoURLs = videoURLs
        self.isOriginal = isOriginal
        super.init()
    }
}

// API verified against SilenceLove/HXPhotoPicker tag 5.0.5, PickerConfiguration.swift.
// Start from the official Moments preset, then apply the classic appearance
// and media policies; the preset also changes video behavior and fixed colors.
enum HXMediaPickerConfiguration {
    static func picker(_ options: HXMediaPickerOptions) -> PickerConfiguration {
        var config = PhotoTools.getWXPickerConfig(isMoment: true)
        restoreAdaptiveAppearance(to: &config)
        config.usesClassicAppearance = true
        config.isAutoBack = false
        config.modalPresentationStyle = .fullScreen
        config.selectOptions = options.mediaType == .photo ? .photo : .video
        config.maximumSelectedCount = options.mediaType == .video ? 1 : max(1, options.maximumSelectedCount)
        config.selectMode = config.maximumSelectedCount == 1 && !options.selectionRequiresConfirmation ? .single : .multiple
        config.maximumSelectedPhotoCount = config.maximumSelectedCount
        config.maximumSelectedVideoCount = config.maximumSelectedCount
        config.allowSelectedTogether = false
        config.minimumSelectedVideoDuration = max(0, options.minimumVideoDuration)
        config.maximumSelectedVideoDuration = max(0, options.maximumVideoDuration)
        config.maximumSelectedVideoFileSize = max(0, options.maximumVideoFileSize)
        config.videoSelectionTapAction = .preview
        config.previewView.disableFinishButtonWhenNotSelected = false
        config.photoList.previewStyle = .push
        config.previewView.usesSystemNavigationTransition = true
        config.editorOptions = options.allowsEditing && options.mediaType == .photo ? .photo : []
        if options.mediaType == .photo && options.allowsEditing && config.maximumSelectedCount == 1 && options.automaticallyEditsSinglePhoto {
            config.photoSelectionTapAction = .openEditor
        }
        config.editor = editor(options, multipleSelection: config.selectMode == .multiple)
        config.photoList.allowAddCamera = options.allowsCamera
        config.photoList.isSaveSystemAlbum = options.saveToPhotoLibrary
        config.photoList.cameraType = .custom(camera(options))
        config.appearanceStyle = options.appearance == .automatic ? .varied :
            (options.appearance == .light ? .normal : .dark)
        config.themeColor = options.themeColor
        config.navigationTintColor = .black
        config.navigationDarkTintColor = .white
        // Open the recent-assets grid directly, as the former WXMoment setup did.
        // Set navigation items after albumShowMode: its iOS 26 setter rewrites them.
        // A text-cancel item calls cancelCallback(), so it closes the whole picker.
        config.albumShowMode = .popup
        config.photoList.leftNavigationItems = [PhotoTextCancelItemView.self]
        config.photoList.rightNavigationItems = []
        if #available(iOS 15.0, *) {
            // Use ordinary controls throughout the picker on iOS 26.
            config.photoList.cancelButtonConfig = nil
            config.photoList.filterButtonConfig = nil
        }
        config.photoList.navigationTitle = AlbumTitleView.self
        config.photoList.titleView.backgroundColor = .clear
        config.photoList.titleView.backgroudDarkColor = .clear
        config.photoList.titleView.arrow.backgroundColor = .clear
        config.photoList.titleView.arrow.backgroudDarkColor = .clear
        config.photoList.titleView.arrow.arrowColor = .black
        config.photoList.titleView.arrow.arrowDarkColor = .white
        config.photoList.isShowFilterItem = false
        config.photoList.cell.customSelectableCellClass = nil
        config.photoList.cell.selectBox.style = .number
        config.previewView.selectBox.style = .number
        config.photoList.bottomView.isShowSelectedView = false
        config.photoList.isShowAssetNumber = true
        config.previewView.bottomView.isShowPreviewList = false
        config.previewView.bottomView.isShowSelectedView = true
        config.previewView.bottomView.isHiddenOriginalButton = true
        config.previewView.bottomView.isHiddenEditButton = config.editorOptions.isEmpty
        // Classic toolbar respects both palettes on iOS 26 and uses the library's
        // safe-area layout (Core+UIDevice.swift), without a device-resolution whitelist.
        config.photoList.photoToolbar = PhotoToolBarView.self
        config.previewView.photoToolbar = PhotoToolBarView.self
        applyNeutralPalette(to: &config.photoList.bottomView)
        applyNeutralPalette(to: &config.previewView.bottomView)
        return config
    }

    private static func restoreAdaptiveAppearance(to config: inout PickerConfiguration) {
        // Initialize AFTER the WX preset: camera/permission icons are shared
        // resources, and these initializers also restore their light-mode images.
        let adaptive = PickerConfiguration()
        let albumRowHeight = config.albumList.cellHeight
        config.navigationViewBackgroundColor = adaptive.navigationViewBackgroundColor
        config.navigationTitleColor = adaptive.navigationTitleColor
        config.statusBarStyle = adaptive.statusBarStyle
        config.navigationBarStyle = adaptive.navigationBarStyle
        config.splitSeparatorLineColor = adaptive.splitSeparatorLineColor
        config.albumList = adaptive.albumList
        config.albumList.cellHeight = albumRowHeight
        config.albumController = adaptive.albumController
        config.photoList.backgroundColor = adaptive.photoList.backgroundColor
        config.photoList.titleView = adaptive.photoList.titleView
        config.photoList.cell.kf_indicatorColor = adaptive.photoList.cell.kf_indicatorColor
        config.photoList.cameraCell = adaptive.photoList.cameraCell
        config.photoList.limitCell = adaptive.photoList.limitCell
        config.photoList.assetNumber = adaptive.photoList.assetNumber
        config.photoList.emptyView = adaptive.photoList.emptyView
        config.photoList.bottomView = adaptive.photoList.bottomView
        config.previewView.backgroundColor = adaptive.previewView.backgroundColor
        config.previewView.livePhotoMark = adaptive.previewView.livePhotoMark
        config.previewView.HDRMark = adaptive.previewView.HDRMark
        config.previewView.bottomView = adaptive.previewView.bottomView
        config.notAuthorized = adaptive.notAuthorized
    }

    // User reference: light toolbar, black text, gray disabled controls. Apply after
    // themeColor, whose setter also recolors these labels in HXPhotoPicker 5.0.5.
    private static func applyNeutralPalette(to toolbar: inout PickerBottomViewConfiguration) {
        let lightBackground = UIColor(white: 247.0 / 255, alpha: 1)
        let disabledText = UIColor(white: 178.0 / 255, alpha: 1)
        toolbar.backgroundColor = lightBackground
        toolbar.barTintColor = lightBackground
        toolbar.backgroundDarkColor = UIColor(white: 30.0 / 255, alpha: 1)
        toolbar.barTintDarkColor = toolbar.backgroundDarkColor
        toolbar.previewButtonTitleColor = .black
        toolbar.originalButtonTitleColor = .black
        toolbar.editButtonTitleColor = .black
        toolbar.previewButtonDisableTitleColor = disabledText
        toolbar.editButtonDisableTitleColor = disabledText
        toolbar.originalSelectBox.borderColor = disabledText
        toolbar.originalSelectBox.backgroundColor = .clear
        toolbar.originalSelectBox.borderDarkColor = UIColor(white: 140.0 / 255, alpha: 1)
        toolbar.originalSelectBox.darkBackgroundColor = .clear
        toolbar.finishButtonTitleColor = .white
        toolbar.finishButtonTitleDarkColor = .white
        toolbar.finishButtonDisableTitleColor = UIColor(white: 191.0 / 255, alpha: 1)
        toolbar.finishButtonDisableBackgroundColor = UIColor(white: 235.0 / 255, alpha: 1)
        toolbar.finishButtonDisableTitleDarkColor = UIColor(white: 102.0 / 255, alpha: 1)
        toolbar.finishButtonDisableDarkBackgroundColor = UIColor(white: 45.0 / 255, alpha: 1)
    }

    static func camera(_ options: HXMediaPickerOptions) -> CameraConfiguration {
        var config = CameraConfiguration()
        config.isAutoBack = false
        config.modalPresentationStyle = .fullScreen
        config.isSaveSystemAlbum = options.saveToPhotoLibrary
        config.allowLocation = false
        config.allowsEditing = options.allowsEditing && options.mediaType == .photo
        config.editor = editor(options, multipleSelection: false)
        config.tintColor = options.themeColor
        config.videoMinimumDuration = TimeInterval(max(0, options.minimumVideoDuration))
        config.videoMaximumDuration = TimeInterval(max(0, options.maximumVideoDuration))
        // HX's press mode clamps an unlimited maximum to one second.
        if options.maximumVideoDuration <= 0 { config.takePhotoMode = .click }
        return config
    }

    // Editable photos use the basic crop layout with rotation, reset and ratios.
    private static func editor(_ options: HXMediaPickerOptions, multipleSelection: Bool) -> EditorConfiguration {
        var config = EditorConfiguration()
        config.isFixedCropSizeState = true
        config.usesLegacyCropLayout = true
        config.legacyCropFinishTitle = multipleSelection ? "裁剪" : "选择"
        config.isWhetherFinishButtonDisabledInUneditedState = multipleSelection
        config.finishButtonTitleNormalColor = .white
        config.finishButtonTitleDisableColor = .white.withAlphaComponent(0.5)
        config.photo.defaultSelectedToolOption = .cropSize
        config.toolsView.toolOptions = config.toolsView.toolOptions.filter { $0.type == .cropSize }
        config.cropSize.isShowScaleSize = false
        config.cropSize.maskType = .customColor(color: .black)
        config.cropSize.defaultSeletedIndex = 0
        config.cropSize.aspectRatios = [
            .init(title: .localized("原始值"), ratio: .zero),
            .init(title: .localized("正方形"), ratio: CGSize(width: 1, height: 1)),
            .init(title: .custom("2:3"), ratio: CGSize(width: 2, height: 3)),
            .init(title: .custom("3:4"), ratio: CGSize(width: 3, height: 4)),
            .init(title: .custom("9:16"), ratio: CGSize(width: 9, height: 16)),
            .init(title: .custom("16:9"), ratio: CGSize(width: 16, height: 9))
        ]
        return config
    }
}
