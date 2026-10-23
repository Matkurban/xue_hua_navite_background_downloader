Pod::Spec.new do |s|
  s.name             = 'xue_hua_navite_background_downloader'
  s.version          = '1.0.0'
  s.summary          = 'Native multi-task background downloader plugin for Flutter.'
  s.description      = <<-DESC
A native multi-task background downloader plugin for Flutter supporting pause/resume, persistent queues, checksum verification, and system notifications.
                       DESC
  s.homepage         = 'https://github.com/Matkurban/xue_hua_navite_background_downloader'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Matkurban' => '3496354336@qq.com' }

  s.source           = { :path => '.' }
  s.source_files = 'xue_hua_navite_background_downloader/Sources/xue_hua_navite_background_downloader/**/*'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
