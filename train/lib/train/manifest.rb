# frozen_string_literal: true

require "yaml"
require "date"

module Train
  # Train manifest operations. Field names are kebab-case to match what `yq`
  # produces, since app-repo workflows and humans read/write this same YAML.
  module Manifest
    class Error < StandardError; end

    # Single source of truth for "positive integer" (build-number/version-code),
    # used here and by Append#run. Rejects "0"/"000", unlike `/\A[0-9]+\z/`.
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

    # Idempotent per (sha, key, value): a rerun with a NEW artifact id for the
    # same sha is recorded; only an exact duplicate is skipped.
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
      # Don't downgrade "promoted" back to "rc-available": a stray RC landing
      # after promotion is still recorded, but must not misrepresent status.
      repo_data["status"] = "rc-available" unless repo_data["status"] == "promoted"
      write(file, data)
      :appended
    end

    # add_repo: extends an existing manifest with a repo cut later than the
    # others (a hotfix reaching its second platform). Top-level status
    # returns to "branched" — the train has an in-flight repo again.
    def add_repo(file, repo:, sha:, branch:)
      data = read(file)
      raise Error, "#{file}: #{repo} already in manifest" if data.fetch("repos").key?(repo)

      data["repos"][repo] = {
        "source-sha" => sha,
        "release-branch" => branch,
        "status" => "pending",
        "rc" => []
      }
      data["status"] = "branched"
      write(file, data)
      data
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

    # Top-level "status" writer. Cut advances a manifest past "cut" once every
    # repo's ensure succeeds — reconcile_in_flight treats "cut" as in-flight,
    # so a manifest stuck there would block every subsequent cut.
    def set_status(file, status)
      data = read(file)
      data["status"] = status
      write(file, data)
      data
    end

    # Writes the per-repo "promoted" block and flips that repo's status to
    # "promoted"; advances the TOP-LEVEL status only once EVERY repo carries a
    # promoted block. Idempotent: an identical existing block is a no-op
    # (returns false) so a rerun doesn't re-commit an unchanged manifest.
    def record_promotion(file, repo:, key:, value:, tag:, notes_sha:, run:)
      int_value = validate_integer!(value)

      data = read(file)
      repo_data = data.fetch("repos").fetch(repo) do
        raise Error, "#{file}: no repo #{repo} in manifest"
      end

      block = { key => int_value, "tag" => tag, "notes-sha" => notes_sha, "run" => run }
      return false if repo_data["promoted"] == block

      repo_data["promoted"] = block
      repo_data["status"] = "promoted"

      data["status"] = "promoted" if data.fetch("repos").values.all? { |r| r["promoted"] }
      write(file, data)
      true
    end

    def read(file)
      # permitted_classes: [Date] — an unquoted hand-edited cut-date parses as
      # a native YAML date; normalize back to the ISO string the tool compares.
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
