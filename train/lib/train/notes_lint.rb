# frozen_string_literal: true

require_relative "notes"
require_relative "store_notes"

module Train
  # Lints a releases/<version> dir with the SAME renderer promotion uses, so
  # an auto-merged notes PR can never pass lint yet fail at promote time.
  # Missing files are skipped — a single-platform hotfix ships one file.
  module NotesLint
    RENDERS = {
      "ios.md" => :listing,
      "android.md" => :listing,
      "submission-notes.md" => :reviewer
    }.freeze

    module_function

    def check(dir)
      checked = []
      errors = []

      RENDERS.each do |name, mode|
        path = File.join(dir, name)
        next unless File.exist?(path)

        markdown = File.read(path, encoding: Encoding::UTF_8)
        error = lint_one(name, mode, markdown)
        if error
          errors << error
        else
          rendered = render(mode, markdown)
          checked << "#{name}: ok (#{rendered.length} chars rendered)"
        end
      end

      { checked: checked, errors: errors }
    end

    def lint_one(name, mode, markdown)
      return "#{name}: still contains the seeded placeholder" if markdown.include?(Notes::HOTFIX_PLACEHOLDER)

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
