# HXMediaPicker 示例与测试

本目录提供独立 iOS 测试工程 `HXMediaPickerHarness`。应用入口是测试宿主，XCTest 直接验证适配层及 HXPhotoPicker 的实际行为。

## 安装依赖

在本目录运行：

```sh
pod install
```

`Podfile` 使用本地适配层及公开的 HXPhotoPicker fork：

```ruby
pod 'HXMediaPicker', :path => '..'
pod 'HXPhotoPicker', :git => 'https://github.com/wowbby/HXPhotoPicker.git', :tag => '5.0.6'
```

首次安装需要能够访问公开 Git 仓库。不要将该依赖改为官方 HXPhotoPicker `5.0.5`，该版本缺少适配层使用的扩展配置。

如需重新生成已随仓库提供的 Xcode 工程，先安装 `xcodeproj` Ruby gem，再运行：

```sh
ruby generate_project.rb
pod install
```

## 运行

使用 Xcode 打开 `HXMediaPickerHarness.xcworkspace`，选择 `HXMediaPickerHarness` scheme 和可用的 iPhone 模拟器，然后执行 Product → Test。

也可以从命令行运行。将示例中的模拟器名称替换为本机已安装的设备：

```sh
xcodebuild test -workspace HXMediaPickerHarness.xcworkspace \
  -scheme HXMediaPickerHarness -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

安全区相关断言需要使用带 Home 指示条的 iPhone 模拟器。示例不固定 `UIUserInterfaceStyle`，以便检查自动、浅色和深色外观配置。

示例通过 `App/Info.plist` 使用应用管理状态栏（`UIViewControllerBasedStatusBarAppearance=false`），用于验证预览黑色主题、自动主题变化，以及宿主关闭时先恢复状态栏再交付回调的顺序。若改为控制器管理状态栏，对应的两项专项测试会跳过。

2026-09-23：此配置下 45 项测试通过、无跳过；控制器管理状态栏的配置已通过原有 43 项测试。自动化结果不替代真机业务入口的预览返回、侧滑返回和裁剪手势验收。

仅检查真机 SDK 编译、不签名和安装：

```sh
xcodebuild build -workspace HXMediaPickerHarness.xcworkspace \
  -scheme HXMediaPickerHarness -configuration Debug -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData-device CODE_SIGNING_ALLOWED=NO
```

## 验证范围

- Objective-C 生成头及公开桥接入口。
- 合成图片的读取顺序、尺寸处理和缺失文件错误。
- 完成/取消回调只交付一次，且在关闭页面后按顺序执行。
- 图片、视频限制、保存策略和外观配置。
- 基础裁剪布局、裁剪输出及安全区内的操作按钮。
- 预览初始化、返回导航、选中状态保留和取消关闭。
- 合成短视频的实际导出、源文件保留及中间文件清理。
- 原片保存成功后的裁剪完成、取消重拍、重复回调和导出文件读取；相机根控制器及资源为测试替身，不实际拍摄或写入相册。

测试使用代码生成的图片和一秒视频，不需要用户相册素材。测试结果应以当前环境的执行输出为准。相机录制、iCloud 下载、权限交互、宿主集成和真机手势体验需要另行验证。

生成的 Pods、构建产物、日志和测试结果包不属于发布源码。

## 1.0.0 发布验证

2026-09-23：以公开 Git tag `wowbby/HXPhotoPicker` `5.0.6` 安装依赖，在 iPhone 17 Pro 模拟器上执行 31 项 XCTest，全部通过；使用 iPhone SDK 的通用 iOS 目标编译通过（未签名、未安装到真机）。其中包括大 JPEG 的加载与实际文件裁剪导出，以及 Live Photo 标签在经典/默认模式之间的切换。

## 1.0.1 发布验证

2026-09-23：同一公开 HXPhotoPicker tag 下，完整 39 项 XCTest 全部通过，通用 iPhone SDK 编译通过（未签名、未安装）。新增验证包括默认关闭的原片保存选项、Objective-C 属性、取消裁剪后重拍、单次回调、宿主直接关闭后的会话释放、全屏覆盖恢复，以及从裁剪导出文件读取完整结果。系统相册实际写入、权限交互和真实相机仍需宿主真机验证。
