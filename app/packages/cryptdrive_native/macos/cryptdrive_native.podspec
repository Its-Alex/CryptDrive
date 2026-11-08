Pod::Spec.new do |s|
  s.name             = 'cryptdrive_native'
  s.version          = '0.1.0'
  s.summary          = 'CryptDrive native library (rclone).'
  s.homepage         = 'https://github.com/Its-Alex/CryptDrive'
  s.license          = { :type => 'MIT' }
  s.author           = { 'CryptDrive' => 'alex.marre.fr@gmail.com' }
  s.source           = { :path => '.' }
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  # Built by `mise run native:macos` (Go c-shared, universal arm64 + x86_64).
  s.vendored_libraries = 'Libraries/libcryptdrive.dylib'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
