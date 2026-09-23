import UIKit
import HXPhotoPicker

// Keep page appearance separate from HX's navigation delegate, which owns the
// preview push/pop animations and interactive back gesture.
final class HXMediaPickerController: PhotoPickerController, PhotoPickerControllerDelegate {
    private var selectionStatusBarStyle: UIStatusBarStyle = .default
    private var hostStatusBarStyle: UIStatusBarStyle?
    private var usesApplicationStatusBarStyle: Bool {
        Bundle.main.object(forInfoDictionaryKey: "UIViewControllerBasedStatusBarAppearance") as? Bool == false
    }

    init(config: PickerConfiguration) {
        super.init(picker: config)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        selectionStatusBarStyle = config.statusBarStyle
        pickerDelegate = self
        super.viewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        if usesApplicationStatusBarStyle, hostStatusBarStyle == nil {
            hostStatusBarStyle = UIApplication.shared.statusBarStyle
        }
        super.viewWillAppear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        // HX can synchronously notify the host from super.viewDidDisappear.
        // Restore first so a host callback/new picker is never overwritten.
        if isBeingDismissed || presentingViewController == nil {
            restoreHostStatusBarStyle()
        }
        super.viewDidDisappear(animated)
    }

    func restoreHostStatusBarStyle() {
        guard let style = hostStatusBarStyle else { return }
        hostStatusBarStyle = nil
        UIApplication.shared.statusBarStyle = style
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if let visible = topViewController { applyPageAppearance(to: visible) }
    }

    func pickerController(_ pickerController: PhotoPickerController,
                          viewControllersWillAppear viewController: UIViewController) {
        applyPageAppearance(to: viewController)
    }

    func pickerController(_ pickerController: PhotoPickerController,
                          viewControllersDidAppear viewController: UIViewController) {
        // UIKit calls appearance callbacks again when an interactive pop is
        // cancelled. Align status-bar state with the page that actually remains.
        guard viewController === topViewController else { return }
        applyPageAppearance(to: viewController)
    }

    private func applyPageAppearance(to viewController: UIViewController) {
        let isPreview = viewController is PhotoPreviewViewController
        config.statusBarStyle = isPreview ? .lightContent : selectionStatusBarStyle
        setNeedsStatusBarAppearanceUpdate()
        viewController.setNeedsStatusBarAppearanceUpdate()
        if usesApplicationStatusBarStyle, hostStatusBarStyle != nil {
            UIApplication.shared.statusBarStyle = preferredStatusBarStyle
        }

        if #available(iOS 13.0, *) {
            guard isPreview else { return }
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .black
            appearance.shadowColor = .clear
            appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
            // Before iOS 26 the picker uses UIKit's implicit Back item. Give its
            // indicator a page-owned color instead of changing the shared bar.
            let backImage = UIImage(systemName: "chevron.left")
            appearance.setBackIndicatorImage(backImage?.withTintColor(.white, renderingMode: .alwaysOriginal),
                                             transitionMaskImage: backImage)
            let backAppearance = UIBarButtonItemAppearance(style: .plain)
            backAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white]
            appearance.backButtonAppearance = backAppearance
            let item = viewController.navigationItem
            item.standardAppearance = appearance
            item.scrollEdgeAppearance = appearance
            item.compactAppearance = appearance
            if #available(iOS 15.0, *) { item.compactScrollEdgeAppearance = appearance }
            (item.leftBarButtonItems ?? []).forEach { $0.tintColor = .white }
            (item.rightBarButtonItems ?? []).forEach { $0.tintColor = .white }
        } else {
            let isDark = PhotoManager.isDark
            navigationBar.barStyle = isPreview ? .black : (isDark ? config.navigationBarDarkStyle : config.navigationBarStyle)
            navigationBar.barTintColor = isPreview ? .black : (isDark ? config.navigationViewBackgroudDarkColor : config.navigationViewBackgroundColor)
            navigationBar.tintColor = isPreview ? .white : (isDark ? config.navigationDarkTintColor : config.navigationTintColor)
        }
    }
}
