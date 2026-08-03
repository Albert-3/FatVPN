#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the FatVpnWidget (WidgetKit) target to Runner.xcodeproj.
#
# Same reason as its neighbour add_packet_tunnel_target.rb: there is no Mac for
# this project (only Codemagic's cloud CI), so Xcode's "File > New > Target"
# wizard is not an option and the equivalent is done here through the
# `xcodeproj` gem. Idempotent — it exits immediately if the target already
# exists, so it is safe on every CI build.
#
# MUST run after add_packet_tunnel_target.rb: it also adds the shared widget
# store to that extension's target, which is how the tunnel tells the widget
# about starts and stops that happen with the app nowhere in sight.
#
# The file memberships below are the load-bearing part of this script, so they
# are spelled out rather than globbed:
#
#  * `Shared/FatVpnWidgetStore.swift` → all three targets. The widget draws what
#    the other two write; none of them can call each other.
#
# That is now the only file the widget shares with anything. The App Intent, the
# native haptics and the background toggle it drove were removed on 2026-08-03
# (see powerControl in FatVpnWidget.swift): the press is a plain
# `fatvpn://widget/toggle` link on every version of iOS, and a link needs no code
# in the extension and no shared type in the app.

# See add_packet_tunnel_target.rb for why the version is pinned here as well as
# in codemagic.yaml: `gem install` makes a version available, `gem` activates it.
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'

IOS_DIR = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(IOS_DIR, 'Runner.xcodeproj')
EXT_NAME = 'FatVpnWidget'
EXT_BUNDLE_ID = 'com.fatvpn.fatvpnApp.FatVpnWidget'

# 16.0, not the app's 13.0.
#
# Below 16 there is no lock-screen widget to draw and the accessory families do
# not exist, so nothing on 14–15 would work anyway. Raising it further would drop
# the accessory (lock screen and StandBy) widgets on iOS 16 for no gain.
DEPLOYMENT_TARGET = '16.0'

WIDGET_SOURCES = %w[
  FatVpnWidget.swift
  FatVpnWidgetBundle.swift
  FatVpnWidgetStrings.swift
].freeze

# Shared with the app (and, for the store, with the tunnel).
SHARED_STORE = 'FatVpnWidgetStore.swift'

project = Xcodeproj::Project.open(PROJECT_PATH)

if project.targets.any? { |t| t.name == EXT_NAME }
  puts "[add_widget_target] Target '#{EXT_NAME}' already exists — nothing to do."
  exit 0
end

runner_target = project.targets.find { |t| t.name == 'Runner' }
raise "[add_widget_target] Runner target not found in #{PROJECT_PATH}" unless runner_target

tunnel_target = project.targets.find { |t| t.name == 'PacketTunnel' }
unless tunnel_target
  raise '[add_widget_target] PacketTunnel target not found. This script runs ' \
        'after add_packet_tunnel_target.rb — check the step order in codemagic.yaml.'
end

debug_xcconfig = project.files.find { |f| f.path == 'Flutter/Debug.xcconfig' }
release_xcconfig = project.files.find { |f| f.path == 'Flutter/Release.xcconfig' }
unless debug_xcconfig && release_xcconfig
  raise '[add_widget_target] Flutter/Debug.xcconfig or Release.xcconfig file reference not found'
end

# --- Groups -----------------------------------------------------------------

ext_group = project.main_group.new_group(EXT_NAME, EXT_NAME)
shared_group = project.main_group['Shared'] || project.main_group.new_group('Shared', 'Shared')
widget_refs = WIDGET_SOURCES.map { |name| ext_group.new_reference(name) }
ext_group.new_reference('Info.plist')
ext_group.new_reference("#{EXT_NAME}.entitlements")

store_ref = shared_group.find_file_by_path(SHARED_STORE) || shared_group.new_reference(SHARED_STORE)

# --- FatVpnWidget: the new app-extension target ------------------------------

ext_target = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)

widget_refs.each { |ref| ext_target.source_build_phase.add_file_reference(ref) }
ext_target.source_build_phase.add_file_reference(store_ref)

ext_target.build_configurations.each do |config|
  config.base_configuration_reference = config.name == 'Debug' ? debug_xcconfig : release_xcconfig
  # See add_packet_tunnel_target.rb: the implicit PRODUCT_NAME default does not
  # reliably apply to targets created by this gem in a Flutter/CocoaPods build
  # graph, and a blank one collides with another target's output.
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BUNDLE_ID
  config.build_settings['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/#{EXT_NAME}.entitlements"
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  config.build_settings['SKIP_INSTALL'] = 'YES'
  # Nothing reads this today — the widget shares only FatVpnWidgetStore.swift
  # with the app, and the store is identical in both. Kept because a file shared
  # with the app is the normal way this widget grows, and an extension cannot
  # compile everything the app can (`import NetworkExtension`, for one).
  config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
    ['$(inherited)', 'FATVPN_WIDGET_EXTENSION']
  # An app extension must not ship an embedded Frameworks/ directory — App Store
  # Connect rejects it (iris-code 90206) — and it does not need one: Swift's
  # runtime has lived in the OS since 12.2.
  config.build_settings['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'NO'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/Frameworks',
    '@executable_path/../../Frameworks',
  ]
end

# --- The app's share of the widget's code ------------------------------------

# Just the store: the app writes the snapshot the widget draws. Everything else
# the two used to share went with the App Intent — and with it the
# `-weak_framework AppIntents` this script used to add to Runner, which existed
# because Runner deploys to iOS 13 where that framework does not exist at all.
runner_target.source_build_phase.add_file_reference(store_ref)

# The tunnel writes the snapshot when it comes up or goes down without the app,
# which on iOS is the ordinary case: an on-demand start, or a stop from
# Settings > VPN, neither of which the app ever hears about.
tunnel_target.source_build_phase.add_file_reference(store_ref)

# --- Runner: depend on + embed the extension ---------------------------------

runner_target.add_dependency(ext_target)

embed_phase = runner_target.build_phases.find do |phase|
  phase.respond_to?(:name) && phase.name == 'Embed Foundation Extensions'
end
created_embed_phase = embed_phase.nil?
embed_phase ||= runner_target.new_copy_files_build_phase('Embed Foundation Extensions')
embed_phase.dst_subfolder_spec = Xcodeproj::Constants::COPY_FILES_BUILD_PHASE_DESTINATIONS[:plug_ins]
embed_build_file = embed_phase.add_file_reference(ext_target.product_reference)
embed_build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# Only when this script created the phase. Reusing PacketTunnel's — the normal
# case, since that script runs first — means it is already in the right place,
# and moving it again would drag the tunnel's embed with it.
if created_embed_phase
  # new_copy_files_build_phase appends at the end, i.e. *after* Flutter's "Thin
  # Binary" run-script phase, which scans Runner.app's embedded binaries
  # (PlugIns included). Copying in after that scan is a dependency cycle.
  runner_target.build_phases.delete(embed_phase)
  thin_binary_index = runner_target.build_phases.index do |p|
    p.respond_to?(:name) && p.name == 'Thin Binary'
  end
  runner_target.build_phases.insert(thin_binary_index || runner_target.build_phases.length,
                                    embed_phase)
end

project.save

puts "[add_widget_target] Added target '#{EXT_NAME}' (#{EXT_BUNDLE_ID}) and saved #{PROJECT_PATH}."
