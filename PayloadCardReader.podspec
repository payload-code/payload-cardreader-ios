Pod::Spec.new do |s|
  s.name             = 'PayloadCardReader'
  s.version          = '0.1.0'
  s.summary          = 'Device extension of Payload iOS library'


  s.description      = <<-DESC
Adds mobile card reader device support to the
Payload iOS library for processing EMV, Swipe, and NFC payments.
More at https://docs.payload.co/card-readers
                       DESC

  s.homepage         = 'https://github.com/payload-code/payload-cardreader-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Payload' => 'help@payload.co' }
  s.source           = { :git => 'https://github.com/payload-code/payload-cardreader-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '10.0'

  s.source_files = 'PayloadCardReader/Classes/**/*'
  
  s.dependency 'PayloadAPI', '~> 0.1.1'
  s.vendored_libraries = 'PayloadCardReader/Lib/*.a', 'PayloadCardReader/Lib/lib*.dylib', 'PayloadCardReader/Lib/lib*.tbd'

end
