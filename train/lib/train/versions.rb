# frozen_string_literal: true

require "semantic"

module Train
  # Train version semantics (strict X.Y.Z — VERSION_RE gates before the
  # semantic gem, which would accept pre-release/build suffixes) plus
  # read/bump of an app checkout's marketing version. Layouts:
  #   convos-client: android/gradle.properties VERSION_NAME
  #   convos-ios:    Convos.xcodeproj/project.pbxproj MARKETING_VERSION
  module Versions
    class Error < StandardError; end

    # No leading zeros — semver forbids them and the semantic gem rejects
    # them, so valid? and parse! must agree.
    VERSION_RE = /\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z/

    module_function

    def valid?(version)
      version.to_s.match?(VERSION_RE)
    end

    # parse!: Semantic::Version for a strict train version; Error otherwise
    # (including anything the gem itself rejects — never a raw ArgumentError).
    def parse!(version)
      raise Error, "bad version '#{version}'" unless valid?(version)

      begin
        Semantic::Version.new(version.to_s)
      rescue ArgumentError
        raise Error, "bad version '#{version}'"
      end
    end

    def next_minor(version)
      parse!(version).increment!(:minor).to_s
    end

    def next_patch(version)
      parse!(version).increment!(:patch).to_s
    end

    def tag(version)
      "v#{parse!(version)}"
    end

    # "v2.1.0" -> "2.1.0"; nil for anything that isn't v + strict X.Y.Z.
    def from_tag(tag)
      version = tag.to_s.delete_prefix("v")
      return nil unless tag.to_s.start_with?("v") && valid?(version)

      version
    end

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
