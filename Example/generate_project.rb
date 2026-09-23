require 'xcodeproj'

root = File.expand_path(__dir__)
project = Xcodeproj::Project.new(File.join(root, 'HXMediaPickerHarness.xcodeproj'))
app = project.new_target(:application, 'HXMediaPickerHarness', :ios, '13.0')
tests = project.new_target(:unit_test_bundle, 'MediaPickerTests', :ios, '13.0')
tests.add_dependency(app)

app_group = project.main_group.new_group('App', 'App')
app_group.new_file('Info.plist')
app.add_file_references([app_group.new_file('main.m')])
test_group = project.main_group.new_group('Tests', 'Tests')
tests.add_file_references(%w[MediaPickerTests.swift PickerCancelNavigationTests.swift PreviewAppearanceLifecycleTests.swift LegacyCropEditorTests.swift ObjCBridgeTests.m].map { |name| test_group.new_file(name) })

project.build_configurations.each do |config|
  config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
  config.build_settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
end
[app, tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "io.github.wowbby.hxmediapicker.tests.#{target.name}"
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    config.build_settings['ENABLE_TESTABILITY'] = 'YES' if config.name == 'Debug'
  end
end
app.build_configurations.each do |config|
  config.build_settings['INFOPLIST_FILE'] = 'App/Info.plist'
  config.build_settings['INFOPLIST_KEY_NSPhotoLibraryUsageDescription'] = '用于测试相册选择组件。'
  config.build_settings['INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription'] = '用于测试照片保存。'
  config.build_settings['INFOPLIST_KEY_NSCameraUsageDescription'] = '用于测试相机组件。'
  config.build_settings['INFOPLIST_KEY_NSMicrophoneUsageDescription'] = '用于测试录制视频。'
  config.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
end
tests.build_configurations.each do |config|
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/HXMediaPickerHarness.app/HXMediaPickerHarness'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @loader_path/Frameworks'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_build_target(tests)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(project.path, 'HXMediaPickerHarness', true)
