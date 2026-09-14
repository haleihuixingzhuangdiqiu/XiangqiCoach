#!/usr/bin/env ruby

require "fileutils"
require "xcodeproj"
require_relative "configure_pikafish"

root = File.expand_path("..", __dir__)
project_path = File.join(root, "XiangqiCoach.xcodeproj")
FileUtils.rm_rf(project_path) if File.exist?(project_path)

project = Xcodeproj::Project.new(project_path)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2660"
project.root_object.attributes["LastUpgradeCheck"] = "2660"

app_target = project.new_target(:application, "XiangqiCoach", :ios, "17.0")
broadcast_target = project.new_target(:app_extension, "XiangqiCoachBroadcast", :ios, "17.0")
tests_target = project.new_target(:unit_test_bundle, "XiangqiCoachTests", :ios, "17.0")

def configure_target(target, bundle_identifier, info_plist)
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_identifier
    settings["INFOPLIST_FILE"] = info_plist
    settings["GENERATE_INFOPLIST_FILE"] = "NO"
    settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
    settings["SWIFT_VERSION"] = "5.0"
    settings["CODE_SIGN_STYLE"] = "Automatic"
    settings["DEVELOPMENT_TEAM"] = "UG5D6JZ378"
    settings["TARGETED_DEVICE_FAMILY"] = "1"
    settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
    settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "YES"
    settings["CURRENT_PROJECT_VERSION"] = "2026091501"
    settings["MARKETING_VERSION"] = "1.1"
  end
end

configure_target(app_target, "com.lgj.xiangqicoach", "XiangqiCoach/Resources/Info.plist")
configure_target(broadcast_target, "com.lgj.xiangqicoach.broadcast", "XiangqiCoachBroadcast/Info.plist")
configure_target(tests_target, "com.lgj.xiangqicoach.tests", "XiangqiCoachTests/Info.plist")

broadcast_target.build_configurations.each do |configuration|
  configuration.build_settings["SKIP_INSTALL"] = "YES"
  configuration.build_settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
end

tests_target.build_configurations.each do |configuration|
  configuration.build_settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/XiangqiCoach.app/XiangqiCoach"
  configuration.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  configuration.build_settings["CODE_SIGNING_ALLOWED"] = "NO"
end

def add_sources(project, target, group_name, paths)
  group = project.main_group.new_group(group_name)
  paths.sort.each do |absolute_path|
    relative_path = absolute_path.delete_prefix(project.path.dirname.to_s + "/")
    reference = group.new_file(relative_path)
    target.source_build_phase.add_file_reference(reference)
  end
end

add_sources(
  project,
  app_target,
  "XiangqiCoach Sources",
  Dir.glob(File.join(root, "XiangqiCoach/**/*.swift"))
)
add_sources(
  project,
  broadcast_target,
  "Broadcast Sources",
  Dir.glob(File.join(root, "XiangqiCoachBroadcast/**/*.swift"))
)
add_sources(
  project,
  tests_target,
  "Test Sources",
  Dir.glob(File.join(root, "XiangqiCoachTests/**/*.swift"))
)

app_target.add_dependency(broadcast_target)
tests_target.add_dependency(app_target)

embed_extensions = app_target.new_copy_files_build_phase("Embed App Extensions")
embed_extensions.dst_subfolder_spec = "13"
embed_extensions.add_file_reference(broadcast_target.product_reference, true)

project.build_configurations.each do |configuration|
  configuration.build_settings["CLANG_ENABLE_MODULES"] = "YES"
  configuration.build_settings["SWIFT_OPTIMIZATION_LEVEL"] = configuration.name == "Debug" ? "-Onone" : "-O"
end

add_sources(project, app_target, "Shared App", Dir.glob(File.join(root, "Shared/*.swift")))
add_sources(project, broadcast_target, "Shared Extension", Dir.glob(File.join(root, "Shared/*.swift")))
Dir.glob(File.join(root, "XiangqiCoach/Resources/*")).select { |p| File.directory?(p) && File.basename(p) != "Pikafish" }.each do |absolute|
  ref = project.main_group.new_file(absolute.delete_prefix(root + "/"))
  ref.last_known_file_type = "folder"
  app_target.resources_build_phase.add_file_reference(ref)
end
Dir.glob(File.join(root, "XiangqiCoach/Resources/*")).select { |p| File.file?(p) && File.extname(p) != ".plist" }.each do |absolute|
  ref = project.main_group.new_file(absolute.delete_prefix(root + "/"))
  app_target.resources_build_phase.add_file_reference(ref)
end
# 真实回归棋盘只进入 XCTest bundle，不随主 App 或录屏扩展发布。
test_fixtures = File.join(root, "XiangqiCoachTests/Fixtures")
if File.directory?(test_fixtures)
  ref = project.main_group.new_file(test_fixtures.delete_prefix(root + "/"))
  ref.last_known_file_type = "folder"
  tests_target.resources_build_phase.add_file_reference(ref)
end
configure_pikafish(project, app_target, root)
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_build_target(broadcast_target)
scheme.add_test_target(tests_target)
scheme.set_launch_target(app_target)
scheme.save_as(project_path, "XiangqiCoach", true)

puts "Generated #{project_path}"
