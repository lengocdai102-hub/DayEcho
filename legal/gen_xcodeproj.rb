#!/usr/bin/env ruby
# 生成 DayEcho 的 Xcode 工程（iOS App + watchOS App + Kit framework）。
# 用法：ruby legal/gen_xcodeproj.rb
#
# 关键点（都是踩过的坑）：
#   1. Kit 必须是真正的 framework target —— 混编进 App 会报
#      "no such module 'DayEchoKit'"，而 SwiftPM 全绿完全掩盖这个问题。
#   2. watchOS App 必须嵌入在 iOS App 里（"Embed Watch Content"），
#      且 watchOS target 是 iOS target 的依赖。
#   3. lproj 必须用 PBXVariantGroup，否则本地化整个失效。
#   4. knownRegions 不登记的 lproj，Xcode 不认这个语言。
require 'xcodeproj'
require 'fileutils'

ROOT = File.expand_path(File.join(__dir__, '..'))
PROJ_PATH = File.join(ROOT, 'DayEcho.xcodeproj')

FileUtils.rm_rf(PROJ_PATH)
project = Xcodeproj::Project.new(PROJ_PATH)

IOS_MIN = '17.0'
WATCH_MIN = '10.0'
BUNDLE_ID = 'com.dayecho.app'
WATCH_BUNDLE_ID = 'com.dayecho.app.watchkitapp'

# ============================================================
# 1. iOS App target
# ============================================================
ios_target = project.new_target(:application, 'DayEcho', :ios, IOS_MIN)

# ============================================================
# 2. Kit framework target
# ============================================================
kit_target = project.new_target(:framework, 'DayEchoKit', :ios, IOS_MIN)
kit_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.dayecho.kit'
  s['PRODUCT_NAME'] = 'DayEchoKit'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  s['DEFINES_MODULE'] = 'YES'
  s['SKIP_INSTALL'] = 'YES'
  s['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'NO'
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['APPLICATION_EXTENSION_API_ONLY'] = 'NO'
  # Kit 用到的框架
  s['FRAMEWORK_SEARCH_PATHS'] = '$(inherited)'
end

# Kit 源码
kit_files = %w[
  Sources/DayEchoKit/Models.swift
  Sources/DayEchoKit/RecordingStore.swift
  Sources/DayEchoKit/Transfer.swift
]
kit_group = project.new_group('DayEchoKit', 'Sources/DayEchoKit')
kit_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = kit_group.new_reference(File.basename(f))
  kit_target.add_file_references([ref])
end

# ============================================================
# 3. watchOS 三件套：Watch App（壳） + WatchKit Extension（业务）
# ============================================================
# watchOS 的工程结构和 iOS 不一样：
#   DayEchoWatchApp   (watch2_app)        —— 壳，不放业务代码
#   DayEchoWatchExtension (watch2_extension) —— 真正的 App 入口与界面
#   iOS App 通过 "Embed Watch Content" 嵌入 watch2_app
#
# 踩过的坑：用 :watch2_app 单一 target 时，WatchKit 扩展缺失，
# 编译报 "Unable to find module 'WatchKit'"。
# 另一个坑：watch2_extension 必须作为 watch2_app 的依赖，
# 且 watch2_app 必须被 iOS App 嵌入，否则装到手表上点不开。

# ---- 3a0. watchOS 版 DayEchoKit ----
# 同一个 framework target 不能同时产 iOS 与 watchOS 版本（平台不同、
# 头文件不同）。watchOS extension 必须链接 watchOS 架构的 Kit，
# 否则链接期报 "building for iOS but linking in watchOS framework"。
watch_kit_target = project.new_target(:framework, 'DayEchoKitWatch', :watchos, WATCH_MIN)
watch_kit_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.dayecho.kit.watch'
  s['PRODUCT_NAME'] = 'DayEchoKit'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['WATCHOS_DEPLOYMENT_TARGET'] = WATCH_MIN
  s['TARGETED_DEVICE_FAMILY'] = '4'
  s['SUPPORTED_PLATFORMS'] = 'watchos watchsimulator'
  s['SDKROOT'] = 'watchos'
  s['DEFINES_MODULE'] = 'YES'
  s['SKIP_INSTALL'] = 'YES'
  s['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'NO'
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
end

watch_kit_group = project.new_group('DayEchoKitWatch', 'Sources/DayEchoKit')
kit_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = watch_kit_group.new_reference(File.basename(f))
  watch_kit_target.add_file_references([ref])
end

# ---- 3a. WatchKit Extension（业务代码在这里）----
watch_ext = project.new_target(:watch2_extension, 'DayEchoWatchExtension', :watchos, WATCH_MIN)
watch_ext.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = "#{WATCH_BUNDLE_ID}.extension"
  s['PRODUCT_NAME'] = 'DayEchoWatchExtension'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['WATCHOS_DEPLOYMENT_TARGET'] = WATCH_MIN
  s['TARGETED_DEVICE_FAMILY'] = '4'
  s['SUPPORTED_PLATFORMS'] = 'watchos watchsimulator'
  s['SDKROOT'] = 'watchos'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'DayEcho'
  s['INFOPLIST_KEY_NSMicrophoneUsageDescription'] =
    'DayEcho 需要麦克风来录制你的语音片段。录音只保存在你的设备上。'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['SKIP_INSTALL'] = 'YES'
end

# Extension 依赖 watchOS 版 Kit（见下方 watch_kit_target）
watch_ext.add_dependency(watch_kit_target)
watch_ext.frameworks_build_phase.add_file_reference(watch_kit_target.product_reference)

watch_files = %w[
  Sources/DayEchoWatchApp/WatchApp.swift
]
watch_group = project.new_group('DayEchoWatchApp', 'Sources/DayEchoWatchApp')
watch_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = watch_group.new_reference(File.basename(f))
  watch_ext.add_file_references([ref])
end

# Extension 的本地化
watch_lproj_group = project.new_group('WatchLocalization', 'Sources/DayEchoWatchApp/WatchResources')
%w[en zh-Hans].each do |lang|
  lproj_path = File.join(ROOT, "Sources/DayEchoWatchApp/WatchResources/#{lang}.lproj")
  next unless File.directory?(lproj_path)
  vg = watch_lproj_group.new_variant_group("#{lang}.lproj")
  vg.new_reference(File.join(lproj_path, 'Localizable.strings'))
  watch_ext.add_resources([vg])
end

# ---- 3b. Watch App（壳）----
watch_target = project.new_target(:watch2_app, 'DayEchoWatch', :watchos, WATCH_MIN)
watch_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = WATCH_BUNDLE_ID
  s['PRODUCT_NAME'] = 'DayEchoWatch'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['WATCHOS_DEPLOYMENT_TARGET'] = WATCH_MIN
  s['TARGETED_DEVICE_FAMILY'] = '4'
  s['SUPPORTED_PLATFORMS'] = 'watchos watchsimulator'
  s['SDKROOT'] = 'watchos'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'DayEcho'
  s['INFOPLIST_KEY_WKCompanionAppBundleIdentifier'] = BUNDLE_ID
  s['INFOPLIST_KEY_WKWatchOnly'] = 'YES'
  s['CODE_SIGNING_ALLOWED'] = 'NO'
  s['CODE_SIGNING_REQUIRED'] = 'NO'
  s['CODE_SIGN_IDENTITY'] = ''
  s['SKIP_INSTALL'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
end

# 壳依赖 Extension —— 缺这个 Xcode 不会把扩展塞进 .app
watch_target.add_dependency(watch_ext)

# ============================================================
# 4. iOS App 依赖与嵌入
# ============================================================
ios_target.add_dependency(kit_target)
ios_target.frameworks_build_phase.add_file_reference(kit_target.product_reference)

# iOS App 依赖 watchOS App
ios_target.add_dependency(watch_target)
# "Embed Watch Content" build phase —— 缺了这个 .app 里不会带手表 App
embed_phase = ios_target.new_copy_files_build_phase('Embed Watch Content')
embed_phase.symbol_dst_subfolder_spec = :plug_ins
embed_phase.add_file_reference(watch_target.product_reference)

app_files = %w[
  Sources/DayEchoApp/DayEchoApp.swift
  Sources/DayEchoApp/ContentView.swift
]
app_group = project.new_group('DayEchoApp', 'Sources/DayEchoApp')
app_files.each do |f|
  path = File.join(ROOT, f)
  next unless File.exist?(path)
  ref = app_group.new_reference(File.basename(f))
  ios_target.add_file_references([ref])
end

# ---- 资源 ----
res_group = project.new_group('Resources')
catalog_path = File.join(ROOT, 'Resources/Assets.xcassets')
if File.directory?(catalog_path)
  catalog = res_group.new_file(catalog_path)
  ios_target.add_resources([catalog])
end

privacy = res_group.new_file(File.join(ROOT, 'legal/privacy_policy.html'))
ios_target.add_resources([privacy])

# ---- 本地化 ----
project.build_configurations.each do |cfg|
  cfg.build_settings['DEVELOPMENT_LANGUAGE'] = 'en'
end
project.root_object.attributes['developmentRegion'] = 'en'
project.root_object.attributes['knownRegions'] = ['en', 'zh-Hans', 'Base']

lproj_group = project.new_group('Localization', 'Sources/DayEchoApp/Resources')
%w[en zh-Hans].each do |lang|
  lproj_path = File.join(ROOT, "Sources/DayEchoApp/Resources/#{lang}.lproj")
  next unless File.directory?(lproj_path)
  vg = lproj_group.new_variant_group("#{lang}.lproj")
  vg.new_reference(File.join(lproj_path, 'Localizable.strings'))
  ios_target.add_resources([vg])
end

# ============================================================
# 5. iOS App Build Settings
# ============================================================
ios_target.build_configurations.each do |cfg|
  s = cfg.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  s['PRODUCT_NAME'] = 'DayEcho'
  s['MARKETING_VERSION'] = '1.0.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '6.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'DayEcho'
  s['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  s['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait'
  s['INFOPLIST_KEY_NSMicrophoneUsageDescription'] =
    'DayEcho 需要麦克风来录制你的语音片段。录音只保存在你的设备上。'
  s['INFOPLIST_KEY_NSHealthShareUsageDescription'] =
    '用于把心率与活动信息关联到录音时间点，全部在本地处理。'
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
  s['DEVELOPMENT_TEAM'] = ''
  s['CODE_SIGN_IDENTITY'] = ''
  s['SWIFT_STRICT_CONCURRENCY'] = 'complete'
end

project.build_configurations.each do |cfg|
  cfg.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = IOS_MIN
  cfg.build_settings['SWIFT_VERSION'] = '6.0'
end

# ============================================================
# 6. Scheme
# ============================================================
# 两个 scheme：
#   DayEcho        —— iOS App（含 watchOS 依赖），用 -destination 'generic/platform=iOS Simulator'
#   DayEchoWatch   —— 纯 watchOS，用 -destination 'generic/platform=watchOS Simulator'
#
# 关键：不能用 -sdk iphonesimulator —— 它会把所有 target 的 SDKROOT
# 覆盖成 iphonesimulator，而 watchapp2 / watchkit2-extension 的
# product type spec 只存在于 watchsimulator 域，报
# "unable to resolve product type ... in domain 'iphonesimulator'"。
# 用 -destination 让 Xcode 按 target 各自解析平台。

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(kit_target)
scheme.add_build_target(watch_kit_target)
scheme.add_build_target(watch_ext)
scheme.add_build_target(watch_target)
scheme.add_build_target(ios_target)
scheme.set_launch_target(ios_target)
scheme.save_as(PROJ_PATH, 'DayEcho', true)

watch_scheme = Xcodeproj::XCScheme.new
watch_scheme.add_build_target(watch_kit_target)
watch_scheme.add_build_target(watch_ext)
watch_scheme.add_build_target(watch_target)
watch_scheme.set_launch_target(watch_target)
watch_scheme.save_as(PROJ_PATH, 'DayEchoWatch', true)

project.save
puts "已生成 #{PROJ_PATH}"
puts "ios:   #{ios_target.name}  src=#{ios_target.source_build_phase.files.count} res=#{ios_target.resources_build_phase.files.count}"
puts "kit:   #{kit_target.name}  src=#{kit_target.source_build_phase.files.count}"
puts "watch: #{watch_target.name}  src=#{watch_target.source_build_phase.files.count}"
puts "wkit: #{watch_kit_target.name}  src=#{watch_kit_target.source_build_phase.files.count}"
puts "wext: #{watch_ext.name}  src=#{watch_ext.source_build_phase.files.count} res=#{watch_ext.resources_build_phase.files.count}"
