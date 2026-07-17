# frozen_string_literal: true

require_relative "notes"
require_relative "store_notes"
require_relative "manifest"

module Train
  # Lints a releases/<version> dir with the SAME renderer promotion uses, so
  # an auto-merged notes PR can never pass lint yet fail at promote time: a
  # release-kind dir requires all three files (promotion's assert_notes_present
  # contract); a hotfix-kind dir requires exactly the files promotion's
  # assert_notes_present would require for the manifest's repos — each repo's
  # platform notes file, plus submission-notes.md when a convos-ios repo is
  # present — so a single-platform hotfix still passes with just its own file.
  module NotesLint
    RENDERS = {
      "ios.md" => :listing,
      "android.md" => :listing,
      "submission-notes.md" => :reviewer
    }.freeze

    module_function

    def check(dir)
      mfile = File.join(dir, "manifest.yml")
      return { checked: [], errors: ["no manifest.yml — not a release dir"] } unless File.exist?(mfile)

      manifest = Manifest.read(mfile)
      kind = manifest["kind"]
      # Strict whitelist: any kind other than these two (absent, misspelled,
      # wrong case) is an error rather than silently falling through to
      # hotfix's present-files-only leniency.
      return { checked: [], errors: ["manifest kind #{kind.inspect} is not release or hotfix"] } unless %w[release hotfix].include?(kind)

      required = kind == "release" ? RENDERS.keys : required_for_hotfix(manifest)

      checked = []
      errors = []

      RENDERS.each do |name, mode|
        path = File.join(dir, name)
        unless File.exist?(path)
          errors << "#{name}: missing (required for kind #{kind})" if required.include?(name)
          next
        end

        if File.symlink?(path)
          errors << "#{name} is a symlink — refusing"
          next
        end

        markdown = File.read(path, encoding: Encoding::UTF_8)
        error = lint_one(name, mode, markdown)
        if error
          errors << error
        else
          rendered = render(mode, markdown)
          checked << "#{name}: ok (#{rendered.length} chars rendered)"
        end
      end

      errors << "no notes files in #{dir}" if checked.empty? && errors.empty?

      { checked: checked, errors: errors }
    end

    # The hotfix files promotion's assert_notes_present (train/lib/train/promote.rb)
    # would require, derived from the manifest's repos rather than whatever
    # happens to be on disk: each present repo's platform notes file
    # (convos-ios -> ios.md, everything else -> android.md, matching
    # Promote::PLATFORMS), plus submission-notes.md whenever a convos-ios repo
    # is present. A manifest with no repos yet imposes no requirements.
    def required_for_hotfix(manifest)
      repos = (manifest["repos"] || {}).keys
      files = repos.map { |repo| repo.end_with?("convos-ios") ? "ios.md" : "android.md" }
      files << "submission-notes.md" if repos.any? { |repo| repo.end_with?("convos-ios") }
      files.uniq
    end
    private_class_method :required_for_hotfix

    def lint_one(name, mode, markdown)
      return "#{name}: still contains the seeded placeholder" if markdown.include?(Notes::HOTFIX_PLACEHOLDER)
      # Markup-independent: an AI draft can reproduce the reviewer sentence
      # without its _.._ emphasis, so match the core phrase against the text
      # with `_`/`*` emphasis markers stripped, not the raw seeded string.
      unmarked = markdown.delete("_*")
      return "#{name}: still contains the seeded placeholder" if unmarked.include?(Notes::REVIEWER_PLACEHOLDER_PHRASE)

      rendered = render(mode, markdown)
      return "#{name}: renders to empty store text" if rendered.strip.empty?

      if name == "android.md" && rendered.length > StoreNotes::PLAY_LIMIT
        return "android.md renders to #{rendered.length} chars (Play limit #{StoreNotes::PLAY_LIMIT})"
      end

      nil
    end
    private_class_method :lint_one

    def render(mode, markdown)
      mode == :reviewer ? StoreNotes.render_reviewer(markdown) : StoreNotes.render(markdown)
    end
    private_class_method :render
  end
end
