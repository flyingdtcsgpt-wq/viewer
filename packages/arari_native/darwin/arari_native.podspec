Pod::Spec.new do |s|
  s.name             = 'arari_native'
  s.version          = '0.1.0'
  s.summary          = 'ARARIFlex native helpers (Vision OCR, AVSpeech TTS)'
  s.homepage         = 'https://github.com/flyingdtcsgpt-wq/viewer'
  s.license          = { :type => 'MIT' }
  s.author           = { 'ARARIFlex' => 'none' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '14.0'
  s.frameworks = 'Vision', 'AVFoundation'
  s.swift_version = '5.0'
end
