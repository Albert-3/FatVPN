#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the PacketTunnel (NetworkExtension) target to Runner.xcodeproj.
#
# There is no Mac available for this project (only Codemagic's cloud CI), so
# Xcode's own "File > New > Target" wizard is not an option — this script
# does the equivalent programmatically via the `xcodeproj` gem, which is
# already installed on Codemagic's mac_mini_m2 image alongside CocoaPods.
# Idempotent: exits immediately if the target already exists, so it's safe
# to run on every CI build (see codemagic.yaml, invoked before `pod install`).
#
# See docs/ios-vpn-tunnel-spec.md for the full tunnel architecture/plan.

require 'xcodeproj'

IOS_DIR = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(IOS_DIR, 'Runner.xcodeproj')
EXT_NAME = 'PacketTunnel'
EXT_BUNDLE_ID = 'com.fatvpn.fatvpnApp.PacketTunnel'
APP_GROUP = 'group.com.fatvpn.fatvpnApp'
DEPLOYMENT_TARGET = '13.0'
XCFRAMEWORK_RELPATH = '../packages/singbox_mm/ios/Frameworks/Libbox.xcframework'

project = Xcodeproj::Project.open(PROJECT_PATH)

if project.targets.any? { |t| t.name == EXT_NAME }
  puts "[add_packet_tunnel_target] Target '#{EXT_NAME}' already exists — nothing to do."
  exit 0
end

runner_target = project.targets.find { |t| t.name == 'Runner' }
raise "[add_packet_tunnel_target] Runner target not found in #{PROJECT_PATH}" unless runner_target

debug_xcconfig = project.files.find { |f| f.path == 'Flutter/Debug.xcconfig' }
release_xcconfig = project.files.find { |f| f.path == 'Flutter/Release.xcconfig' }
raise '[add_packet_tunnel_target] Flutter/Debug.xcconfig or Release.xcconfig file reference not found' unless debug_xcconfig && release_xcconfig

# Apple rejects the archive at upload time ("Missing Entitlement ... bundle
# 'Runner.app' is missing entitlement 'com.apple.developer.networking.
# networkextension'") unless the *host* app carries the same NetworkExtension
# entitlement as the embedded Packet Tunnel Provider — this is required even
# though Runner never calls NetworkExtension APIs directly. Runner's App ID
# already has the Network Extensions capability enabled on Apple Developer
# Portal (confirmed: its "FatVPN App Store" profile lists it), so wiring the
# entitlement here doesn't require touching/regenerating that profile.
#
# The App Group entitlement is deliberately NOT added here yet — Runner's
# provisioning profile predates that capability on the App ID, and
# re-fetching/regenerating it is riskier (see commit efb5e4b on the Runner
# cert/key pairing) than this project wants to do until App Group config
# sharing is actually implemented (Фаза 3+).
runner_group = project.main_group.find_subpath('Runner', false)
raise '[add_packet_tunnel_target] Runner group not found' unless runner_group

unless runner_group.find_file_by_path('Runner.entitlements')
  runner_group.new_reference('Runner.entitlements')
end
runner_target.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

# --- PacketTunnel: new Network Extension target ------------------------------
ext_target = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)

ext_group = project.main_group.new_group(EXT_NAME, EXT_NAME)
swift_refs = ['PacketTunnelProvider.swift', 'ExtensionPlatformInterface.swift'].map { |f| ext_group.new_reference(f) }
ext_group.new_reference('Info.plist')
ext_group.new_reference('PacketTunnel.entitlements')

swift_refs.each { |ref| ext_target.source_build_phase.add_file_reference(ref) }

ext_target.build_configurations.each do |config|
  config.base_configuration_reference = config.name == 'Debug' ? debug_xcconfig : release_xcconfig
  # Xcode's implicit PRODUCT_NAME default ($(TARGET_NAME)) doesn't reliably
  # apply to targets created by xcodeproj in this Flutter/CocoaPods build
  # graph — leaving it unset produced a blank product name, which collided
  # with another target's output ("Multiple commands produce '.../.appex'").
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BUNDLE_ID
  config.build_settings['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/PacketTunnel.entitlements"
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  config.build_settings['SKIP_INSTALL'] = 'YES'
  # App extensions must NOT ship an embedded Frameworks/ directory — App Store
  # Connect upload validation rejects it ("Invalid Bundle. The bundle at
  # 'Runner.app/PlugIns/PacketTunnel.appex' contains disallowed file
  # 'Frameworks'", iris-code 90206). A Swift extension defaults to embedding
  # the Swift standard libraries into its own Frameworks/, but since our
  # deployment target is iOS 13 (Swift ABI stability shipped in 12.2) the
  # runtime already lives in the OS, so embedding is both unnecessary and
  # forbidden here. Turn it off so the .appex stays framework-free.
  config.build_settings['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'NO'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/Frameworks',
    '@executable_path/../../Frameworks',
  ]
  # Libbox is a *static* library built by gomobile, so its external references
  # stay unresolved until the linking target pulls in the system libraries it
  # depends on. Without these, the final link fails with e.g. "Undefined
  # symbol: _res_9_nclose" (Go's cgo DNS resolver → libresolv) and "_OBJC_
  # CLASS_$_UIApplication" / "_UIBackgroundTaskInvalid" (Go mobile lifecycle →
  # UIKit). A dynamic framework would resolve these at its own build time; a
  # static one makes it PacketTunnel's job.
  config.build_settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lresolv', '-framework', 'UIKit']
end

# --- Link Libbox.xcframework (Фаза 1 artifact) into the extension -----------
# Confirmed static (ar archive, both device and simulator slices) via `file`
# on the extracted binary — a static library is linked into the extension's
# own binary at build time, not embedded/copied at runtime, so there's no
# "Embed Frameworks" copy phase here (that would be for dynamic frameworks).
xcframework_abspath = File.expand_path(File.join(IOS_DIR, XCFRAMEWORK_RELPATH))
if File.exist?(xcframework_abspath)
  frameworks_group = project.main_group['Frameworks'] || project.main_group.new_group('Frameworks')
  xcframework_ref = frameworks_group.new_reference(XCFRAMEWORK_RELPATH)
  xcframework_ref.last_known_file_type = 'wrapper.xcframework'

  ext_target.frameworks_build_phase.add_file_reference(xcframework_ref)

  ext_target.build_configurations.each do |config|
    existing = Array(config.build_settings['FRAMEWORK_SEARCH_PATHS'] || ['$(inherited)'])
    config.build_settings['FRAMEWORK_SEARCH_PATHS'] = (existing + ['$(PROJECT_DIR)/../packages/singbox_mm/ios/Frameworks']).uniq
  end
else
  warn "[add_packet_tunnel_target] #{xcframework_abspath} not found yet (Фаза 1) — PacketTunnel target created without linking Libbox.xcframework."
end

# --- Runner: depend on + embed the extension --------------------------------
runner_target.add_dependency(ext_target)

embed_ext_phase = runner_target.new_copy_files_build_phase('Embed Foundation Extensions')
embed_ext_phase.dst_subfolder_spec = Xcodeproj::Constants::COPY_FILES_BUILD_PHASE_DESTINATIONS[:plug_ins]
embed_ext_build_file = embed_ext_phase.add_file_reference(ext_target.product_reference)
embed_ext_build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# new_copy_files_build_phase appends at the end, i.e. *after* Flutter's "Thin
# Binary" run-script phase (xcode_backend.sh embed_and_thin). That script
# scans Runner.app's embedded binaries (including PlugIns), so if the embed
# copy runs after it, Xcode's build system sees a dependency cycle
# ("Multiple commands produce" / "Cycle in dependencies"). Move it right
# before Thin Binary so the extension is copied in first.
runner_target.build_phases.delete(embed_ext_phase)
thin_binary_index = runner_target.build_phases.index { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
insert_at = thin_binary_index || runner_target.build_phases.length
runner_target.build_phases.insert(insert_at, embed_ext_phase)

project.save

puts "[add_packet_tunnel_target] Added target '#{EXT_NAME}' (#{EXT_BUNDLE_ID}) and saved #{PROJECT_PATH}."
