# frozen_string_literal: true

module Train
  # Read/bump the marketing version of a convos app checkout. Layouts:
  #   convos-client: android/gradle.properties VERSION_NAME
  #   convos-ios:    Convos.xcodeproj/project.pbxproj MARKETING_VERSION
  module Versions
    class Error < StandardError; end

    VERSION_RE = /\A[0-9]+\.[0-9]+\.[0-9]+\z/

    module_function

    def layout_for(dir)
      gradle = File.join(dir, "android", "gradle.properties")
      pbxproj = File.join(dir, "Convos.xcodeproj", "project.pbxproj")
      return [:android, gradle] if File.file?(gradle)
      return [:ios, pbxproj] if File.file?(pbxproj)

      raise Error, "no known version file under #{dir}"
    end

    def read(dir)
      layout, path = layout_for(dir)
      versions = read_versions(layout, path)
      # ios: multiple MARKETING_VERSION entries must agree.
      unique = versions.uniq
      if unique.size != 1
        raise Error, "inconsistent versions found:\n#{versions.join("\n")}"
      end

      version = unique.first
      unless version.match?(VERSION_RE)
        raise Error, "bad version '#{version}'"
      end

      version
    end

    def bump(dir, new_version)
      unless new_version.match?(VERSION_RE)
        raise Error, "bad version '#{new_version}'"
      end

      layout, path = layout_for(dir)
      case layout
      when :android
        content = File.read(path)
        updated = content.sub(/^VERSION_NAME=.*$/, "VERSION_NAME=#{new_version}")
        File.write(path, updated)
      when :ios
        content = File.read(path)
        updated = content.gsub(/MARKETING_VERSION = [0-9][0-9.]*;/, "MARKETING_VERSION = #{new_version};")
        File.write(path, updated)
      end

      # Post-bump verify, mirroring the bash's own re-read check.
      verify = read_versions(layout, path).uniq
      unless verify == [new_version]
        raise Error, "post-bump verify failed"
      end

      new_version
    end

    # read_versions: raw extraction (may return >1 distinct value for ios;
    # read() is the one that enforces agreement).
    def read_versions(layout, path)
      content = File.read(path)
      case layout
      when :android
        content.scan(/^VERSION_NAME=(.*)$/).flatten
      when :ios
        content.scan(/MARKETING_VERSION = ([0-9][0-9.]*);/).flatten.uniq
      end
    end
    private_class_method :read_versions
  end
end
