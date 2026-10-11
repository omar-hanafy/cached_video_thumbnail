#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint cached_video_thumbnail.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'cached_video_thumbnail'
  s.version          = '0.2.0'
  s.summary          = 'High-performance video thumbnail engine for Flutter.'
  s.description      = <<-DESC
Cached, scheduled, cancellable video thumbnail generation from asset, file,
and network videos, built for infinite feeds on low-end devices.
                       DESC
  s.homepage         = 'https://github.com/omar-hanafy/cached_video_thumbnail'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Omar Hanafy' => 'saberyemen48@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'cached_video_thumbnail/Sources/cached_video_thumbnail/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.resource_bundles = {'cached_video_thumbnail_privacy' => ['cached_video_thumbnail/Sources/cached_video_thumbnail/PrivacyInfo.xcprivacy']}
end
