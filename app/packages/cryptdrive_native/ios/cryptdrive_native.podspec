Pod::Spec.new do |s|
  s.name             = 'cryptdrive_native'
  s.version          = '0.1.0'
  s.summary          = 'CryptDrive native library (rclone, statically linked).'
  s.homepage         = 'https://github.com/Its-Alex/CryptDrive'
  s.license          = { :type => 'MIT' }
  s.author           = { 'CryptDrive' => 'alex.marre.fr@gmail.com' }
  s.source           = { :path => '.' }
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  # Built by `mise run native:ios` (Go c-archive); Go only supports static libraries on iOS.
  s.vendored_libraries = 'Libraries/libcryptdrive.a'
  s.frameworks = 'Security', 'CoreFoundation'
  s.libraries = 'resolv'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64' }
  # Dart looks the symbols up at runtime with DynamicLibrary.process(): nothing references them at link time.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -force_load "${PODS_ROOT}/../.symlinks/plugins/cryptdrive_native/ios/Libraries/libcryptdrive.a"',
    'STRIP_STYLE' => 'non-global',
  }
end
