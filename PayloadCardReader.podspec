Pod::Spec.new do |s|
  s.name             = 'PayloadCardReader'
  s.version          = '0.1.4'
  s.summary          = 'Device extension of Payload iOS library'
  s.swift_versions   = '4.2'


  s.description      = <<-DESC
Adds mobile card reader device support to the
Payload iOS library for processing EMV, Swipe, and NFC payments.
More at https://docs.payload.co/card-readers
                       DESC

  s.homepage         = 'https://github.com/payload-code/payload-cardreader-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Payload' => 'help@payload.co' }
  s.source           = { :git => 'https://github.com/payload-code/payload-cardreader-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '11.0'

  s.source_files = 'PayloadCardReader/Classes/**/*'
  
  s.dependency 'PayloadAPI', '~> 0.2.2'
  s.vendored_libraries = 'PayloadCardReader/Lib/*.a'
  
  s.libraries = 'c++'
  s.xcconfig = {
     'CLANG_CXX_LANGUAGE_STANDARD' => 'c++11',
     'CLANG_CXX_LIBRARY' => 'libc++'
  }
  
  s.pod_target_xcconfig = { 'VALID_ARCHS' => 'arm64 armv7 x86_64' }
end
