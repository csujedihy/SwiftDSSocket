Pod::Spec.new do |s|
  s.name         = "SwiftDSSocket"
  s.version      = "0.1.0"
  s.summary      = "DispatchSource based sockets framework written in pure Swift 3.1"
  s.homepage     = "https://github.com/csujedihy/SwiftDSSocket"
  s.license      = "GPL"
  s.author             = { "jedihy" => "csujedi@gmail.com" }
  s.social_media_url   = "https://github.com/csujedihy"
  s.ios.deployment_target = "9.0"
  s.osx.deployment_target = "10.10"
  s.source       = { :git => "https://github.com/csujedihy/SwiftDSSocket.git", :tag => "#{s.version}" }
  s.source_files = "Sources/**/*.swift"
  s.requires_arc = true
  s.xcconfig = { 'SWIFT_VERSION' => '3.1' }
end
