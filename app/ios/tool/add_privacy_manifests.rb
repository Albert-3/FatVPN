#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds each bundle's PrivacyInfo.xcprivacy to its target's Resources phase.
#
# Apple wants a privacy manifest from every bundle that touches a "required
# reason" API, and this app ships three of them — the app, the tunnel and the
# widget — each using a different set (see the manifests themselves). A manifest
# describes the bundle it sits in, so one file at the top would cover nothing.
#
# Why a script rather than the checked-in project file: two of the three targets
# do not exist in Runner.xcodeproj at all. There is no Mac for this project
# (only Codemagic's cloud CI), so PacketTunnel and FatVpnWidget are created on
# every build by add_packet_tunnel_target.rb and add_widget_target.rb, and
# anything of theirs has to be wired in the same way. Runner's manifest is done
# here too rather than by hand in the .pbxproj: same gem, same review, one place
# to look.
#
# MUST run after both scripts — the targets it attaches to are their output. It
# raises instead of warning when one is missing: a manifest that
# quietly fails to ship is invisible until App Store Connect emails about it,
# days later, on a build number that cannot be reused.
#
# Idempotent, like its neighbours: re-running adds nothing and changes nothing.
#
# codemagic.yaml re-checks the result on the exported .ipa, because "the file
# reference is in the project" and "the file is in the bundle" are not the same
# claim — the same reason the App Group entitlement is verified there.

# See add_packet_tunnel_target.rb for why the version is pinned here as well as
# in codemagic.yaml: `gem install` makes a version available, `gem` activates it.
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'

IOS_DIR = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(IOS_DIR, 'Runner.xcodeproj')
MANIFEST = 'PrivacyInfo.xcprivacy'

# target name => the group (and directory) its manifest lives in. The extension
# group is created by the script that creates the target, with the group name
# equal to the target name; Runner's comes with the Flutter template.
TARGETS = {
  'Runner' => 'Runner',
  'PacketTunnel' => 'PacketTunnel',
  'FatVpnWidget' => 'FatVpnWidget',
}.freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

TARGETS.each do |target_name, group_name|
  target = project.targets.find { |t| t.name == target_name }
  unless target
    raise "[add_privacy_manifests] Target '#{target_name}' not found. This script " \
          'runs after add_packet_tunnel_target.rb and add_widget_target.rb — check ' \
          'the step order in codemagic.yaml.'
  end

  path_on_disk = File.join(IOS_DIR, group_name, MANIFEST)
  unless File.exist?(path_on_disk)
    raise "[add_privacy_manifests] #{path_on_disk} is missing — the target would " \
          'ship without a privacy manifest.'
  end

  group = project.main_group[group_name] ||
          project.main_group.new_group(group_name, group_name)
  ref = group.find_file_by_path(MANIFEST) || group.new_reference(MANIFEST)

  phase = target.resources_build_phase
  already = phase.files.any? { |build_file| build_file.file_ref == ref }
  phase.add_file_reference(ref) unless already

  puts "[add_privacy_manifests] #{target_name}: #{already ? 'already had' : 'added'} " \
       "#{group_name}/#{MANIFEST}"
end

project.save

puts "[add_privacy_manifests] Saved #{PROJECT_PATH}."
