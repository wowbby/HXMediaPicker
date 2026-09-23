# HXMediaPicker

HXMediaPicker 是基于 [HXPhotoPicker](https://github.com/wowbby/HXPhotoPicker) 的 Swift 媒体选择适配层，为 Objective-C 和 Swift 提供统一入口。它支持相册选图、单个视频选择、拍照、录像和基础裁剪，返回 `UIImage` 或本地视频 URL。

适配层负责界面呈现、配置映射、结果读取和回调顺序；上传、文件持久化及应用自身的交互状态由调用方处理。

## 安装

当前通过 CocoaPods 的 Git 源安装，尚未发布到 CocoaPods Trunk。请在宿主应用的 `Podfile` 中同时指定这两个公开仓库和 tag：

```ruby
use_frameworks! :linkage => :static

target 'YourApp' do
  pod 'HXPhotoPicker', :git => 'https://github.com/wowbby/HXPhotoPicker.git', :tag => '5.0.6'
  pod 'HXMediaPicker', :git => 'https://github.com/wowbby/HXMediaPicker.git', :tag => '1.0.1'
end
```

然后运行 `pod install`，使用生成的 `.xcworkspace` 打开工程。

HXMediaPicker `1.0.1` 依赖上述 HXPhotoPicker fork 的 `5.0.6`。该版本提供经典裁剪布局、普通导航控件和预览切换所需的扩展配置。官方 HXPhotoPicker `5.0.5` 缺少这些接口，不能直接替换；仅写 `pod 'HXMediaPicker'` 也无法从 Trunk 安装当前版本。

## Objective-C 调用

公开类型通过 `@objc` / `@objcMembers` 暴露，CocoaPods 会生成 Swift 到 Objective-C 的接口头：

```objc
#import <HXMediaPicker/HXMediaPicker-Swift.h>

HXMediaPickerOptions *options = [HXMediaPickerOptions new];
options.source = HXMediaPickerSourceLibrary;
options.mediaType = HXMediaPickerMediaTypePhoto;
options.maximumSelectedCount = 9;
options.allowsEditing = YES;
options.appearance = HXMediaPickerAppearanceAutomatic;

[HXMediaPicker presentFromViewController:self
                               options:options
                            completion:^(HXMediaPickerResult *result, NSError *error) {
    if (error != nil) {
        NSLog(@"%@", error.localizedDescription);
        return;
    }
    NSArray<UIImage *> *images = result.images;
    // 处理选中的图片。
    (void)images;
} cancel:^{
    // 用户取消。
}];
```

Swift 调用使用同一组选项：

```swift
import HXMediaPicker

let options = HXMediaPickerOptions()
options.maximumSelectedCount = 9

HXMediaPicker.present(from: self, options: options) { result, error in
    if let error = error {
        print(error.localizedDescription)
        return
    }
    let images = result?.images ?? []
    // 处理选中的图片。
    _ = images
} cancel: {
    // 用户取消。
}
```

呈现页面必须已显示在窗口中，且没有正在呈现的其他控制器。一次只能打开一个 HXMediaPicker；重复打开会通过 `completion` 返回错误。

## 选项

| 属性 | 默认值 | 说明 |
| --- | --- | --- |
| `source` | `.library` | `.library` 打开相册，`.camera` 打开相机。 |
| `mediaType` | `.photo` | `.photo` 处理照片，`.video` 处理视频；一次选择不混合两种类型。 |
| `maximumSelectedCount` | `1` | 照片选择上限，至少为 1；视频固定单选。 |
| `selectionRequiresConfirmation` | `false` | 单选时仍显示勾选状态和完成按钮。 |
| `allowsEditing` | `false` | 开启照片基础裁剪；视频不启用编辑。 |
| `automaticallyEditsSinglePhoto` | `true` | 允许编辑且照片上限为 1 时，点选照片直接进入编辑页。 |
| `cropOnly` | `false` | 保留的兼容属性；当前可编辑照片统一使用基础裁剪布局，切换此值不会启用其他编辑工具。 |
| `allowsCamera` | `false` | 在相册列表中显示拍摄入口。 |
| `saveToPhotoLibrary` | `false` | 将拍摄结果保存到系统相册。 |
| `saveOriginalPhotoBeforeEditing` | `false` | 独立相机拍照时，配合 `allowsEditing` 和 `saveToPhotoLibrary`，先保存原片再进入裁剪。取消裁剪回到相机，已保存原片保留。 |
| `minimumVideoDuration` | `0` | 视频最小时长，单位为秒。 |
| `maximumVideoDuration` | `0` | 视频最大时长，单位为秒；0 表示不设上限。 |
| `maximumVideoFileSize` | `0` | 相册视频选择的文件大小上限，单位为字节；0 表示不设上限。 |
| `imageTargetSize` | `.zero` | 指定图片读取的目标尺寸；设置时保持比例，适配层的本地缩放不会放大小图。 |
| `appearance` | `.automatic` | 跟随宿主的有效外观，或指定 `.light` / `.dark`。 |
| `themeColor` | `#07C160` | 选择标记、完成按钮等选中状态的主色。 |
| `willPresent` | `nil` | 即将呈现选择器时调用。 |
| `didDismiss` | `nil` | 选择器关闭后、结果或取消回调前调用。 |

时长和文件大小的负值按 0 处理。使用相机录制且不设置最大时长时，采用点击开始/结束录制的方式。

### 视频选择

```objc
HXMediaPickerOptions *options = [HXMediaPickerOptions new];
options.mediaType = HXMediaPickerMediaTypeVideo;
options.maximumVideoDuration = 60;
options.maximumVideoFileSize = 100 * 1024 * 1024;
```

`result.videoURLs` 返回适配层导出的临时文件，优先使用 MP4，不支持时使用 MOV。视频按 `AVAssetExportPresetMediumQuality` 导出；需要长期保存时，请复制或移动到应用自己的目录，使用完后删除临时输出文件。适配层清理自己生成的中间文件，不删除相册中的源资源。

### 生命周期与回调

`willPresent` 可用于暂停宿主页面上的相机或其他媒体操作；`didDismiss` 可用于恢复这些操作。所有生命周期、完成、失败和取消回调均在主线程执行。

一次请求只交付一次终止回调：成功或失败走 `completion`，用户取消走 `cancel`。已经呈现的选择器会先关闭，再调用 `didDismiss`，最后交付结果或取消。页面无法呈现、相机不可用等发生在呈现之前的错误直接走 `completion`，不会补发呈现/关闭钩子。

读取图片或导出视频时会显示加载提示，待结果准备好后关闭页面。图片按选择顺序返回；任意一张读取失败时，整个请求返回错误，不交付部分结果。编辑过的照片优先返回编辑结果。

`result.isOriginal` 表示选择器返回的原图选择标记，不保证字节、编码或尺寸与原始文件完全相同，也不取消视频导出压缩。`imageTargetSize = .zero` 表示适配层不增加目标尺寸缩放，经过编辑的图片仍受 HXPhotoPicker 的编辑器降采样策略影响。

## 默认界面与裁剪

相册从最近项目开始，可通过标题切换相册。选择圈显示序号，左上角取消直接关闭选择器。预览采用系统导航的 push/pop 切换，返回后保留选择状态和列表位置；预览底部显示已选图片缩略图。

选择页和预览页使用普通导航控件与安全区布局。浅色模式采用白色页面、浅灰底栏和中性文字，深色模式使用对应的深色配色。`themeColor` 修改选中状态的主色。自动外观跟随宿主；宿主若固定浅色，自动模式也保持浅色。相机和裁剪编辑区使用各自的深色界面。

开启 `allowsEditing` 后，照片使用经典基础裁剪布局：还原、左旋转、比例选择和确认。默认不提供涂鸦、贴纸、滤镜、镜像或角度尺。裁剪比例包括原始比例、1:1、2:3、3:4、9:16 和 16:9。单选可不修改直接确认；多选的裁剪页需要修改后才能确认。未开启编辑或选择视频时，预览页隐藏编辑按钮。

## 权限

权限说明由宿主应用的 `Info.plist` 提供，请按实际功能设置：

| 键 | 用途 |
| --- | --- |
| `NSPhotoLibraryUsageDescription` | 读取相册。 |
| `NSPhotoLibraryAddUsageDescription` | 将拍摄结果保存到相册。 |
| `NSCameraUsageDescription` | 拍照和录像。 |
| `NSMicrophoneUsageDescription` | 录制带音频的视频。 |

适配层的相机配置关闭位置访问，不要求宿主为此添加位置权限说明。

## 已知限制

- 经典裁剪页支持拖动裁剪框边角调整范围，但尚未实现从裁剪框内部拖动整个框。该布局关闭照片平移和双指缩放。
- 默认同时启用拍照编辑与 `saveToPhotoLibrary` 时，保存到相册的是编辑结果。`1.0.1` 起，独立相机可额外设置 `saveOriginalPhotoBeforeEditing = true`，改为保存原片并将编辑结果交给调用方；相册列表中的拍照入口不使用该选项。
- HXPhotoPicker 在编辑大图前可能执行降采样；即使 `imageTargetSize` 为零，也不能保证编辑结果保留源文件的完整像素尺寸。
- 相机录制、iCloud 下载、权限交互和具体设备上的裁剪/返回手势需要真机验证。独立测试工程不替代宿主应用的完整流程验收。

## 示例与测试

[`Example`](Example/README.md) 提供混合 Objective-C / Swift 的独立测试工程，使用代码生成的图片与短视频检查桥接接口、结果读取、回调、配置、裁剪和导航行为。运行方法及验证范围见示例文档。

## 许可证

HXMediaPicker 使用 [MIT License](LICENSE)。HXPhotoPicker 及其资源遵循其仓库中的许可证和声明。
