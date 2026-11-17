#!/usr/bin/env ruby
# ★ 工程布局断言（阶段 2.1）★
#
# 用法：ruby legal/assert_project_layout.rb
#
# ★ 为什么不用 grep 查 pbxproj 文本 ★
#
# 1. 两个 "Embed Widget Extensions" phase **同名**
#    （Xcode 允许不同 target 的 phase 重名）
#    ⇒ 用 awk 按名字抓块只能抓到其中一个，另一半完全看不见。
#
# 2. "宿主归属"这件事在文本层面无法判断
#    —— `DayEchoWatchWidget.appex in Embed Widget Extensions` 这行
#    出现在哪个 target 的 buildPhases 里，文本里查不出来。
#    （我第一版就写成了 "DayEchoWatch.app in Embed Widget Extensions"，
#      而 watch app 根本不嵌入自己 ⇒ 这条断言永远失败。）
#
# ⇒ 用 xcodeproj 直接读对象关系，判据才站得住。
#
# ★ 这些失败都是静默的 ★
#
# Widget Extension 嵌错位置 ⇒ 编译完全通过，
# 但手表上找不到 complication、Live Activity 界面缺失。
# 只有真机点表盘才发现 ⇒ 必须在 CI 里卡住。

require 'xcodeproj'

ROOT = File.expand_path(File.join(__dir__, '..'))
PROJ_PATH = File.join(ROOT, 'DayEcho.xcodeproj')

unless File.exist?(PROJ_PATH)
  abort "★ 找不到 #{PROJ_PATH} —— 先跑 ruby legal/gen_xcodeproj.rb"
end

project = Xcodeproj::Project.open(PROJ_PATH)
failures = []

def target(project, name)
  project.targets.find { |t| t.name == name }
end

def copy_phase_for(target, phase_name)
  target.copy_files_build_phases.find { |p| p.name == phase_name }
end

def embedded_products(target, phase_name)
  phase = copy_phase_for(target, phase_name)
  return nil unless phase
  phase.files.map { |bf| bf.file_ref&.path }.compact
end

puts '══ 工程布局断言（阶段 2.1 Widget Extension 嵌入）══'

# ---- 1. 五个 target 都存在 ----
%w[DayEcho DayEchoKit DayEchoKitWatch DayEchoIntents
   DayEchoWatch DayEchoWatchWidget DayEchoWidget].each do |name|
  if target(project, name).nil?
    failures << "缺少 target: #{name}"
  end
end
puts "  target 数量: #{project.targets.count}"

# ---- 2. watch widget extension 嵌到 watch app ----
watch_app = target(project, 'DayEchoWatch')
if watch_app
  products = embedded_products(watch_app, 'Embed Widget Extensions')
  if products.nil?
    failures << 'DayEchoWatch 缺 "Embed Widget Extensions" copy phase'
  else
    puts "  DayEchoWatch 嵌入: #{products.inspect}"
    unless products.any? { |p| p.include?('DayEchoWatchWidget.appex') }
      failures << 'DayEchoWatchWidget.appex 没有嵌到 DayEchoWatch.app（表盘 complication 会静默消失）'
    end
    # watch app 里不该出现 iOS widget extension
    if products.any? { |p| p.include?('DayEchoWidget.appex') }
      failures << 'DayEchoWidget.appex（iOS 扩展）不应嵌到 DayEchoWatch.app'
    end
    phase = copy_phase_for(watch_app, 'Embed Widget Extensions')
    unless phase.dst_subfolder_spec == '13'
      failures << "DayEchoWatch 的 embed phase dstSubfolderSpec 应为 13（PlugIns），实际 #{phase.dst_subfolder_spec.inspect}"
    end
  end
end

# ---- 3. iOS widget extension 嵌到 iOS app ----
ios_app = target(project, 'DayEcho')
if ios_app
  products = embedded_products(ios_app, 'Embed Widget Extensions')
  if products.nil?
    failures << 'DayEcho 缺 "Embed Widget Extensions" copy phase'
  else
    puts "  DayEcho 嵌入: #{products.inspect}"
    unless products.any? { |p| p.include?('DayEchoWidget.appex') }
      failures << 'DayEchoWidget.appex 没有嵌到 DayEcho.app（Live Activity 界面会缺失）'
    end
    if products.any? { |p| p.include?('DayEchoWatchWidget.appex') }
      failures << 'DayEchoWatchWidget.appex（watch 扩展）不应嵌到 DayEcho.app'
    end
    phase = copy_phase_for(ios_app, 'Embed Widget Extensions')
    unless phase.dst_subfolder_spec == '13'
      failures << "DayEcho 的 embed phase dstSubfolderSpec 应为 13（PlugIns），实际 #{phase.dst_subfolder_spec.inspect}"
    end
  end
end

# ---- 4. 两个 extension 与 watch app 都链接 DayEchoIntents ----
#
# ★ 为什么必须链接同一个 framework ★
#
# Control Widget 的 `ControlWidgetButton(action:)` 与 Watch App 的 intent
# 必须是**同一个类型**，否则系统调不通。
# ⇒ 两者都链接 DayEchoIntents。
def linked_products(target)
  return [] unless target
  # ★ 必须看 path，不能看 name ★
  #
  # framework 的 PBXFileReference：
  #   path = "DayEchoIntents.framework"
  #   name = nil
  #
  # 用 `name` 判断会永远匹配不到 ⇒ 断言误报"没链接"。
  target.frameworks_build_phase.files.map { |bf| bf.file_ref&.path }.compact
end

{
  'DayEchoWatch' => 'DayEchoWatchWidget',
  'DayEchoWatchWidget' => 'DayEchoWatchWidget',
}.each do |host, _|
  t = target(project, host)
  next unless t
  names = linked_products(t)
  unless names.any? { |n| n.include?('DayEchoIntents') }
    failures << "#{host} 没有链接 DayEchoIntents framework（intent 类型会与 Control Widget 不是同一个）"
  else
    puts "  #{host} 链接: #{names.inspect}"
  end
end

# ---- 5. embed phase 必须带 RemoveHeadersOnCopy ----
[watch_app, ios_app].each do |t|
  next unless t
  phase = copy_phase_for(t, 'Embed Widget Extensions')
  next unless phase
  phase.files.each do |bf|
    attrs = bf.settings&.dig('ATTRIBUTES') || []
    unless attrs.include?('RemoveHeadersOnCopy')
      failures << "#{t.name} 的 #{bf.file_ref&.path} 缺 ATTRIBUTES = (RemoveHeadersOnCopy, )"
    end
  end
end

# ---- 6. 原有 Embed Watch Content 不能被这次改动破坏 ----
if ios_app
  phase = copy_phase_for(ios_app, 'Embed Watch Content')
  if phase.nil?
    failures << 'DayEcho 缺 "Embed Watch Content" copy phase'
  else
    unless phase.dst_path == '$(CONTENTS_FOLDER_PATH)/Watch'
      failures << "Embed Watch Content 的 dstPath 不对：#{phase.dst_path.inspect}"
    end
    unless phase.dst_subfolder_spec == '16'
      failures << "Embed Watch Content 的 dstSubfolderSpec 应为 16，实际 #{phase.dst_subfolder_spec.inspect}"
    end
    products = phase.files.map { |bf| bf.file_ref&.path }.compact
    unless products.any? { |p| p.include?('DayEchoWatch.app') }
      failures << 'DayEchoWatch.app 没有出现在 Embed Watch Content 里'
    end
    puts "  Embed Watch Content: #{products.inspect}"
  end
end

# ---- 7. ★ widget extension 必须用真实 Info.plist 且含 NSExtension 字典 ★ ----
#
# ★★ 为什么要查这个 ★★
#
# 2026-11-17 真机装机炸在这里：
#   IXErrorDomain Code=2  Failed to create app extension placeholder for
#                          .../DayEcho.app/PlugIns/DayEchoWidget.appex
#   IXErrorDomain Code=17 extensionDictionary must be set in placeholder
#                          attributes for an app extension placeholder
#
# 根因（**两次踩坑实测**）：
#   ① INFOPLIST_KEY_NSExtensionPointIdentifier（平铺）
#      ⇒ Xcode 在 Info.plist 顶层生成 NSExtensionPointIdentifier key，
#        **不生成** NSExtension 字典 ⇒ 装机失败。
#   ② INFOPLIST_KEY_NSExtension_NSExtensionPointIdentifier（嵌套）
#      ⇒ Xcode **根本不处理**这个键，
#        产物 plist 里连一个 NSExtensionPointIdentifier 都没有
#        ⇒ 装机依然失败。
#
# ⇒ 唯一可靠解：给 widget target 提供**真实 Info.plist 文件**，
#   里面写 NSExtension 字典。
#
# ★ 为什么必须在这里查 ★
# 编译不关心 plist 结构，打包也不关心，只有真机安装才读 NSExtension
# ⇒ 光靠「编译通过 + 打包成功」抓不到它。
# 这条断言在**工程生成后、编译前**就把它拦下来。
# 产物级另有一道（CI 的 "Assert app extensions have NSExtension dictionary"）。
{
  'DayEchoWidget' => 'Sources/DayEchoWidget/Info.plist',
  'DayEchoWatchWidget' => 'Sources/DayEchoWatchWidget/Info.plist',
}.each do |name, plist_rel|
  t = target(project, name)
  next unless t

  gen = nil
  plist_setting = nil
  t.build_configurations.each do |cfg|
    bs = cfg.build_settings
    gen ||= bs['GENERATE_INFOPLIST_FILE']
    plist_setting ||= bs['INFOPLIST_FILE']
  end

  # ① 不许用 GENERATE_INFOPLIST_FILE（生成式 plist 造不出 NSExtension 字典）
  if gen.to_s.upcase == 'YES'
    failures << "#{name} 仍在用 GENERATE_INFOPLIST_FILE=YES —— " \
                 "Xcode 生成的 plist 不含 NSExtension 字典，" \
                 "真机安装必报 IXErrorDomain Code=17。" \
                 "必须改用真实 Info.plist 文件（INFOPLIST_FILE）。"
  end

  # ② 必须指定真实 Info.plist 路径
  if plist_setting.to_s.empty?
    failures << "#{name} 没设 INFOPLIST_FILE —— 必须指向真实 Info.plist"
  elsif File.expand_path(plist_setting, ROOT) != File.expand_path(File.join(ROOT, plist_rel))
    failures << "#{name} 的 INFOPLIST_FILE 指向 #{plist_setting.inspect}，" \
                 "应为 #{plist_rel.inspect}"
  end

  # ③ 那个真实 plist 必须真的有 NSExtension 字典
  abs = File.join(ROOT, plist_rel)
  unless File.exist?(abs)
    failures << "#{name} 的 Info.plist 不存在：#{abs}"
  else
    begin
      plist = Xcodeproj::Plist.read_from_path(abs)
      ext = plist['NSExtension']
      if ext.nil?
        failures << "#{plist_rel} 缺 NSExtension 字典 —— " \
                     "真机安装必报 IXErrorDomain Code=17 " \
                     "(extensionDictionary must be set)"
      elsif ext['NSExtensionPointIdentifier'] != 'com.apple.widgetkit-extension'
        failures << "#{plist_rel} 的 NSExtensionPointIdentifier 应为 " \
                     "'com.apple.widgetkit-extension'，实际 " \
                     "#{ext['NSExtensionPointIdentifier'].inspect}"
      else
        puts "  #{name}: #{plist_rel} 有 NSExtension 字典 " \
             "(#{ext['NSExtensionPointIdentifier']})"
      end
    rescue => e
      failures << "#{plist_rel} 解析失败：#{e.message}"
    end
  end
end

puts
if failures.empty?
  puts '✅ 全部通过'
  exit 0
else
  puts "❌ 失败 #{failures.count} 项："
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
