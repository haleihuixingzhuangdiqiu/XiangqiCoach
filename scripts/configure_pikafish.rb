require "xcodeproj"

# 将成熟引擎作为本进程原生代码编译，iOS 不启动外部引擎进程。
def configure_pikafish(project, app_target, root)
  group = project.main_group.groups.find { |item| item.display_name == "Pikafish Native" } || project.main_group.new_group("Pikafish Native")
  sources = Dir.glob(File.join(root, "XiangqiCoach/Vendor/Pikafish/src/**/*.cpp"))
    .reject { |path| path.end_with?("/main.cpp") || path.include?("/universal/") || path.include?("/temp_builds/") }
  sources += Dir.glob(File.join(root, "XiangqiCoach/Engine/Native/*.{h,mm}"))
  sources.sort.each do |absolute|
    path = absolute.delete_prefix(root + "/")
    reference = project.files.find { |file| file.path == path } || group.new_file(path)
    next if path.end_with?(".h")
    app_target.source_build_phase.add_file_reference(reference, true) unless app_target.source_build_phase.files_references.include?(reference)
  end

  app_target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings["SWIFT_OBJC_BRIDGING_HEADER"] = "XiangqiCoach/Engine/Native/XiangqiCoach-Bridging-Header.h"
    settings["CLANG_CXX_LANGUAGE_STANDARD"] = "c++17"
    settings["CLANG_CXX_LIBRARY"] = "libc++"
    settings["OTHER_CPLUSPLUSFLAGS"] = ["$(inherited)", "-O3", "-DNDEBUG"]
    definitions = ["$(inherited)", "IS_64BIT", "USE_POPCNT", "ZSTD_DISABLE_ASM=1", "PIKAFISH_DISABLE_SHARED_MEMORY=1"]
    settings["GCC_PREPROCESSOR_DEFINITIONS"] = definitions
    settings["GCC_PREPROCESSOR_DEFINITIONS[arch=arm64]"] = definitions + ["USE_NEON=8"]
  end

  path = "XiangqiCoach/Resources/Pikafish"
  reference = project.files.find { |file| file.path == path } || group.new_file(path)
  reference.last_known_file_type = "folder"
  app_target.resources_build_phase.add_file_reference(reference, true) unless app_target.resources_build_phase.files_references.include?(reference)
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("..", __dir__)
  project = Xcodeproj::Project.open(File.join(root, "XiangqiCoach.xcodeproj"))
  configure_pikafish(project, project.targets.find { |target| target.name == "XiangqiCoach" }, root)
  project.save
end
