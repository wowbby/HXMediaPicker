Pod::Spec.new do |s|
  s.name = 'HXMediaPicker'
  s.version = '1.0.0'
  s.summary = 'Objective-C media selection bridge with classic crop controls for HXPhotoPicker.'
  s.homepage = 'https://github.com/wowbby/HXMediaPicker'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = 'wowbby'
  s.source = { :git => 'https://github.com/wowbby/HXMediaPicker.git', :tag => s.version.to_s }
  s.ios.deployment_target = '10.0'
  s.swift_version = '5.0'
  s.static_framework = true
  s.source_files = 'Sources/HXMediaPicker/**/*.swift'
  s.frameworks = 'UIKit', 'Photos', 'AVFoundation'
  s.dependency 'HXPhotoPicker', '= 5.0.6'
end
