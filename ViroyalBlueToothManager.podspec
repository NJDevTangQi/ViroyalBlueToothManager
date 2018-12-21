#
# Be sure to run `pod lib lint VIBLEManager.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'ViroyalBlueToothManager'
  s.version          = '1.0.0'
  s.summary          = '蓝牙指令封装'

# This description is used to generate tags and improve search results.
#   * Think: What does it do? Why did you write it? What is the focus?
#   * Try to keep it short, snappy and to the point.
#   * Write the description between the DESC delimiters below.
#   * Finally, don't worry about the indent, CocoaPods strips it!

  s.description      = <<-DESC
包含蓝牙设备的配对、指令下发
                       DESC

  s.homepage         = 'https://github.com/NJDevTangQi/ViroyalBlueToothManager'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'NJDevTangQi' => '824282017@qq.com' }
  s.source           = { :git => 'https://github.com/NJDevTangQi/ViroyalBlueToothManager.git', :tag => s.version.to_s }

  s.ios.deployment_target = '10.0'

  s.source_files = 'ViroyalBlueToothManager/*'

  s.frameworks = 'CoreBluetooth'

  s.subspec 'fota' do |ss|
      ss.source_files = ['ViroyalBlueToothManager/fota/*.h']
      ss.vendored_libraries = ['ViroyalBlueToothManager/fota/*.a']
  end

end
