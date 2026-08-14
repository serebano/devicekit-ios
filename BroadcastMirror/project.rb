#!/usr/bin/env ruby
# Generate BroadcastMirror.xcodeproj: a lean host app + a ReplayKit
# broadcast-upload extension, manual-signed. Run with Homebrew ruby (the
# `xcodeproj` gem is installed there):
#
#   /opt/homebrew/opt/ruby/bin/ruby BroadcastMirror/project.rb
#
# Signing profile names + versions come from the environment (see ascprov.rb /
# build.sh); sensible defaults let it generate a compilable project with no env.
require 'xcodeproj'
require 'fileutils'

TEAM     = ENV.fetch('DEVELOPMENT_TEAM', 'RA9PQ9434F')
APP_BID  = ENV.fetch('APP_BUNDLE_ID', 'net.busymate.mirror')
EXT_BID  = ENV.fetch('EXT_BUNDLE_ID', 'net.busymate.mirror.upload')
APP_PROF = ENV.fetch('APP_PROFILE_NAME', 'Busymate Mirror Dev')
EXT_PROF = ENV.fetch('EXT_PROFILE_NAME', 'Busymate Mirror Upload Dev')
MKT_VER  = ENV.fetch('MARKETING_VERSION', '1.0')
BLD_VER  = ENV.fetch('CURRENT_PROJECT_VERSION', '1')

ROOT = File.dirname(File.expand_path(__FILE__))
proj_path = File.join(ROOT, 'BroadcastMirror.xcodeproj')
File.exist?(proj_path) && FileUtils.rm_rf(proj_path)
project = Xcodeproj::Project.new(proj_path)

def common(bs, team)
  bs['DEVELOPMENT_TEAM'] = team
  bs['CODE_SIGN_STYLE'] = 'Manual'
  bs['CODE_SIGN_IDENTITY'] = 'Apple Development'
  bs['SWIFT_VERSION'] = '5.0'
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
  bs['TARGETED_DEVICE_FAMILY'] = '1'
  bs['GENERATE_INFOPLIST_FILE'] = 'NO'
  bs['MARKETING_VERSION'] = MKT_VER
  bs['CURRENT_PROJECT_VERSION'] = BLD_VER
end

# Pure logic shared verbatim with the BroadcastMirrorCore SwiftPM package
# (single source of truth — the package is what `swift test` exercises).
CORE = %w[
  Core/Sources/BroadcastMirrorCore/DownscalePolicy.swift
  Core/Sources/BroadcastMirrorCore/AnnexB.swift
  Core/Sources/BroadcastMirrorCore/BitratePolicy.swift
  Core/Sources/BroadcastMirrorCore/FramePacer.swift
]

# ---- Host app target ----
app = project.new_target(:application, 'BroadcastMirror', :ios, '16.0')
host_group = project.new_group('Host')
%w[Host/App.swift Host/BroadcastPicker.swift].each do |f|
  app.add_file_references([host_group.new_reference(f)])
end
app.build_configurations.each do |c|
  bs = c.build_settings
  common(bs, TEAM)
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = APP_BID
  bs['PRODUCT_NAME'] = 'BroadcastMirror'
  bs['INFOPLIST_FILE'] = 'Host/Info.plist'
  bs['PROVISIONING_PROFILE_SPECIFIER'] = APP_PROF
  bs['ASSETCATALOG_COMPILER_APPICON_NAME'] = ''
  bs['ENABLE_PREVIEWS'] = 'NO'
end

# ---- Broadcast upload extension target ----
ext = project.new_target(:app_extension, 'BroadcastMirrorUpload', :ios, '16.0')
upload_group = project.new_group('Upload')
%w[
  Upload/SampleHandler.swift Upload/H264Encoder.swift Upload/PixelScaler.swift
  Upload/LoopbackServer.swift Upload/BroadcastConfig.swift
  Upload/MemoryPressureGuard.swift Upload/BroadcastMirror.swift
].each { |f| ext.add_file_references([upload_group.new_reference(f)]) }
core_group = project.new_group('Core')
CORE.each { |f| ext.add_file_references([core_group.new_reference(f)]) }
ext.build_configurations.each do |c|
  bs = c.build_settings
  common(bs, TEAM)
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BID
  bs['PRODUCT_NAME'] = 'BroadcastMirrorUpload'
  bs['INFOPLIST_FILE'] = 'Upload/Info.plist'
  bs['PROVISIONING_PROFILE_SPECIFIER'] = EXT_PROF
  bs['PRODUCT_MODULE_NAME'] = 'BroadcastMirrorUpload'
end

# ---- Embed the extension into the app ----
app.add_dependency(ext)
embed = app.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
bf = embed.add_file_reference(ext.product_reference)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "wrote #{proj_path}"
puts "targets: #{project.targets.map(&:name).join(', ')}"
puts "app=#{APP_BID} ext=#{EXT_BID} team=#{TEAM}"
