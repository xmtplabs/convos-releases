# frozen_string_literal: true

require "yaml"
require "date"

module Train
  # Train manifest operations. Field names are kebab-case to match what `yq`
  # produces, since app-repo workflows and humans read/write this same YAML.
  module Manifest
    class Error < StandardError; end

    # POSITIVE_INT_RE: single source of truth for "positive integer" as
    # accepted by append_rc's id-value (build-number/version-code). Used
    # here AND by Append#run so both entry points reject the same things —
    # notably "0"/"000", which `/\A[0-9]+\z/` would have let through.
    POSITIVE_INT_RE = /\A[1-9][0-9]*\z/.freeze

    module_function

    # init: writes a brand-new manifest. Refuses to overwrite an existing
    # file — the once-per-date cut claim depends on this being a hard
    # collision, not a silent merge.
    #
    # repos: { "owner/repo" => "sha", ... }
    def init(file, version:, kind:, cut_date:, repos:)
      raise Error, "#{file} already exists" if File.exist?(file)

      data = {
        "version" => version,
        "kind" => kind,
        "cut-date" => cut_date.to_s,
        "status" => "cut",
        "repos" => {}
      }
      repos.each do |repo, sha|
        data["repos"][repo] = {
          "source-sha" => sha,
          "release-branch" => "#{kind}/#{version}",
          "status" => "pending",
          "rc" => []
        }
      end
      write(file, data)
      data
    end

    # append_rc: idempotent per (sha, key, VALUE). A rerun that produced a
    # NEW artifact id (e.g. a fresh TestFlight build number for the same
    # sha) must be recorded; only an exact duplicate is skipped. value must
    # be a positive integer — the bash rejects anything else because it
    # gets interpolated unquoted into a yq expression as a yaml int.
    def append_rc(file, repo:, sha:, run:, key:, value:)
      int_value = validate_integer!(value)

      data = read(file)
      repo_data = data.fetch("repos").fetch(repo) do
        raise Error, "#{file}: no repo #{repo} in manifest"
      end
      existing = repo_data["rc"].any? { |e| e["sha"] == sha && e[key] == int_value }
      if existing
        return :skipped
      end

      repo_data["rc"] << { "sha" => sha, "run" => run, key => int_value }
      repo_data["status"] = "rc-available"
      write(file, data)
      :appended
    end

    def set_repo_status(file, repo:, status:)
      data = read(file)
      data.fetch("repos").fetch(repo) do
        raise Error, "#{file}: no repo #{repo} in manifest"
      end
      data["repos"][repo]["status"] = status
      write(file, data)
      data
    end

    # set_status: top-level "status" writer (mirrors set_repo_status). Cut
    # uses this to advance a manifest past "cut" once every repo's ensure
    # has succeeded — reconcile_in_flight only treats status:"cut" as
    # in-flight, so a manifest stuck at "cut" forever would block every
    # subsequent week's cut.
    def set_status(file, status)
      data = read(file)
      data["status"] = status
      write(file, data)
      data
    end

    def read(file)
      # permitted_classes: [Date] — a human hand-editing cut-date via the
      # GitHub web pencil (design spec shows it unquoted, e.g.
      # "cut-date: 2026-07-16") produces a native YAML date scalar rather
      # than a string; normalize back to the ISO string the rest of the
      # tool compares against.
      data = YAML.safe_load_file(file, permitted_classes: [Date]) || {}
      normalize_dates!(data)
      data
    end

    def normalize_dates!(node)
      case node
      when Hash
        node.each { |k, v| node[k] = v.is_a?(Date) ? v.iso8601 : normalize_dates!(v) }
      when Array
        node.map! { |v| v.is_a?(Date) ? v.iso8601 : normalize_dates!(v) }
      end
      node
    end

    def write(file, data)
      # Strip the leading "---" document marker for a cleaner diff/read
      # experience; semantically identical YAML either way.
      yaml = YAML.dump(data, line_width: -1).sub(/\A---\n/, "")
      File.write(file, yaml)
    end

    def validate_integer!(value)
      str = value.to_s
      unless str.match?(POSITIVE_INT_RE)
        raise Error, "id-value must be a positive integer, got '#{value}'"
      end

      Integer(str)
    end
  end
end
