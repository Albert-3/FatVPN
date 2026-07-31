#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the FatVpnWidget (WidgetKit) target to Runner.xcodeproj.
#
# Same reason as add_packet_tunnel_target.rb, which this deliberately mirrors:
# there is no Mac for this project (only Codemagic's cloud CI), so Xcode's
# "File > New > Target" wizard is not available and the target is created
# programmatically with the `xcodeproj` gem. Idempotent — exits immediately if
# the target already exists, so it is safe on every CI build.
#
# MUST run after add_packet_tunnel_target.rb: it adds the shared snapshot file
# (ios/Shared/FatVpnWidgetSnapshot.swift) to the PacketTunnel target, which does
# not exist until that script has run. It does not *fail* without it — the
# widget still builds — but the tunnel would then stop telling the widget when
# iOS starts or stops it behind the app's back.
#
# See docs/home-widgets-spec.md for what the widget does and why it does not
# talk to NetworkExtension.

# See add_packet_tunnel_target.rb for why the version is pinned here as well as
# in codemagic.yaml: `gem install` makes a version available, `gem` activates it.
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'

IOS_DIR = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(IOS_DIR, 'Runner.xcodeproj')
EXT_NAME = 'FatVpnWidget'
EXT_BUNDLE_ID = 'com.fatvpn.fatvpnApp.FatVpnWidget'
# WidgetKit's minimum. Higher than the app's 13.0 on purpose: an extension may
# require a newer OS than the app embedding it, and on iOS 13 the widget is
# simply not offered.
DEPLOYMENT_TARGET = '14.0'
SHARED_GROUP_NAME = 'Shared'
SHARED_SNAPSHOT_FILE = 'FatVpnWidgetSnapshot.swift'
# The power button's App Intent. Compiled into the widget *and* into the app —
# see the comment above `add_source_once(runner_target, intents_ref, ...)`.
INTENTS_FILE = 'FatVpnWidgetIntents.swift'
EXT_SWIFT_FILES = [
  'FatVpnWidgetBundle.swift',
  'FatVpnWidget.swift',
  'FatVpnWidgetStrings.swift',
  INTENTS_FILE,
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

runner_target = project.targets.find { |t| t.name == 'Runner' }
raise "[add_widget_target] Runner target not found in #{PROJECT_PATH}" unless runner_target

debug_xcconfig = project.files.find { |f| f.path == 'Flutter/Debug.xcconfig' }
release_xcconfig = project.files.find { |f| f.path == 'Flutter/Release.xcconfig' }
unless debug_xcconfig && release_xcconfig
  raise '[add_widget_target] Flutter/Debug.xcconfig or Release.xcconfig file reference not found'
end

# --- Shared snapshot file, compiled into every target that touches it --------
# Runner writes it (the fatvpn/widget channel in AppDelegate), PacketTunnel
# patches it when the OS starts or stops the tunnel without the app, and the
# widget reads it. One file rather than three copies of the same key names.
shared_group = project.main_group[SHARED_GROUP_NAME] ||
               project.main_group.new_group(SHARED_GROUP_NAME, SHARED_GROUP_NAME)
shared_ref = shared_group.find_file_by_path(SHARED_SNAPSHOT_FILE) ||
             shared_group.new_reference(SHARED_SNAPSHOT_FILE)

def add_source_once(target, ref, label)
  already = target.source_build_phase.files.any? { |build_file| build_file.file_ref == ref }
  target.source_build_phase.add_file_reference(ref) unless already
  puts "[add_widget_target] #{label}: #{already ? 'already had' : 'added'} #{ref.path}"
end

add_source_once(runner_target, shared_ref, 'Runner')

# --- The App Intent, in the app as well as in the widget ---------------------
# `FatVpnTogglePowerIntent` sets openAppWhenRun, which means the system performs
# it *in the app's process*. An app binary that does not contain the intent type
# cannot perform it, and the press then does nothing whatsoever — no launch, no
# error, exactly what a device showed with widgets that rendered perfectly. So
# the same file is a member of both targets.
#
# It is gated `@available(iOS 17.0, ...)`, above the app's 13.0 deployment
# target, and AppIntents.framework is weak-linked below for the same reason: an
# older device must be able to launch an app that merely *contains* the type.
ext_group = project.main_group[EXT_NAME] ||
            project.main_group.new_group(EXT_NAME, EXT_NAME)
intents_ref = ext_group.find_file_by_path(INTENTS_FILE) ||
              ext_group.new_reference(INTENTS_FILE)
add_source_once(runner_target, intents_ref, 'Runner')

runner_target.build_configurations.each do |config|
  flags = config.build_settings['OTHER_LDFLAGS'] || ['$(inherited)']
  flags = [flags] unless flags.is_a?(Array)
  # WidgetKit as well as AppIntents: Runner has compiled the shared snapshot —
  # which imports WidgetKit (iOS 14) — since the widgets landed, and hard-linking
  # it is the same latent launch failure on anything below that.
  %w[AppIntents WidgetKit].each do |framework|
    next if flags.each_cons(2).any? { |a, b| a == '-weak_framework' && b == framework }

    flags += ['-weak_framework', framework]
  end
  config.build_settings['OTHER_LDFLAGS'] = flags
end

packet_tunnel_target = project.targets.find { |t| t.name == 'PacketTunnel' }
if packet_tunnel_target
  add_source_once(packet_tunnel_target, shared_ref, 'PacketTunnel')
else
  # Loud, not fatal: the widget is still correct, it just stops being updated by
  # tunnel starts and stops that happen without the app.
  warn '[add_widget_target] PacketTunnel target not found — run ' \
       'add_packet_tunnel_target.rb first, or the tunnel will not update the widget.'
end

if project.targets.any? { |t| t.name == EXT_NAME }
  puts "[add_widget_target] Target '#{EXT_NAME}' already exists — saving shared-file wiring only."
  project.save
  exit 0
end

# --- FatVpnWidget: new WidgetKit extension target ----------------------------
ext_target = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)

# The group and the intent's file reference already exist — they are created
# above, before the early exit, so that Runner's membership is wired even on a
# project that already has the extension target.
swift_refs = EXT_SWIFT_FILES.map do |f|
  ext_group.find_file_by_path(f) || ext_group.new_reference(f)
end
ext_group.new_reference('Info.plist')
ext_group.new_reference('FatVpnWidget.entitlements')

swift_refs.each { |ref| ext_target.source_build_phase.add_file_reference(ref) }
ext_target.source_build_phase.add_file_reference(shared_ref)

ext_target.build_configurations.each do |config|
  config.base_configuration_reference = config.name == 'Debug' ? debug_xcconfig : release_xcconfig
  # Explicit for the same reason as in add_packet_tunnel_target.rb: a target
  # created by the gem does not reliably inherit Xcode's $(TARGET_NAME) default,
  # and an empty product name collides with another target's output.
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_BUNDLE_ID
  config.build_settings['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/#{EXT_NAME}.entitlements"
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  config.build_settings['SKIP_INSTALL'] = 'YES'
  # App extensions must not ship an embedded Frameworks/ directory — App Store
  # Connect rejects the upload (iris 90206). Swift's runtime has lived in the OS
  # since 12.2, far below this target's minimum, so there is nothing to embed.
  config.build_settings['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'NO'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/Frameworks',
    '@executable_path/../../Frameworks',
  ]
  # Extensions may not call the APIs that only a full app can (openURL and
  # friends). Xcode sets this for extension targets it creates; the gem does not.
  config.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  # No Libbox here, unlike PacketTunnel: the widget links nothing but the
  # system's own SwiftUI and WidgetKit, which Swift auto-links from the imports.
end

# --- Runner: depend on + embed the extension --------------------------------
runner_target.add_dependency(ext_target)

# add_packet_tunnel_target.rb already created this phase and placed it correctly
# (before Flutter's "Thin Binary", or the build graph cycles). Reuse it rather
# than adding a second copy phase writing into the same PlugIns directory.
embed_phase = runner_target.build_phases.find do |phase|
  phase.respond_to?(:name) && phase.name == 'Embed Foundation Extensions'
end

if embed_phase.nil?
  embed_phase = runner_target.new_copy_files_build_phase('Embed Foundation Extensions')
  embed_phase.dst_subfolder_spec = Xcodeproj::Constants::COPY_FILES_BUILD_PHASE_DESTINATIONS[:plug_ins]
  runner_target.build_phases.delete(embed_phase)
  thin_binary_index = runner_target.build_phases.index do |p|
    p.respond_to?(:name) && p.name == 'Thin Binary'
  end
  runner_target.build_phases.insert(thin_binary_index || runner_target.build_phases.length, embed_phase)
end

embed_build_file = embed_phase.add_file_reference(ext_target.product_reference)
embed_build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save

puts "[add_widget_target] Added target '#{EXT_NAME}' (#{EXT_BUNDLE_ID}) and saved #{PROJECT_PATH}."
