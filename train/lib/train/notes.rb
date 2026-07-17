# frozen_string_literal: true

require "date"

module Train
  # Seed release notes from merged dev PRs. Only bot authors are filtered;
  # label-based filtering is deliberately absent (a dependencies PR can fix
  # a user-visible crash — humans prune, automation doesn't hide).
  module Notes
    # Marker sentence Hotfix seeds into platform notes; Promote#prepare refuses
    # to stage notes that still contain it (the template must never ship).
    HOTFIX_PLACEHOLDER = "Describe the fix being shipped"

    # Marker sentence Cut seeds into a weekly train's submission-notes.md;
    # NotesLint refuses it too — an unedited reviewer seed must never ship.
    REVIEWER_PLACEHOLDER = "_For app reviewers: summarize user-visible changes, test-account hints._"

    # The core wording of REVIEWER_PLACEHOLDER, without its Markdown emphasis
    # markup. An AI-drafted submission-notes.md can reproduce this sentence
    # without the surrounding `_..._`, so NotesLint matches on this phrase
    # against markup-stripped text rather than the raw seeded string alone.
    REVIEWER_PLACEHOLDER_PHRASE = "For app reviewers: summarize user-visible changes"

    module_function

    # 7-day fallback when no --since / prior cut-date is available (the
    # seed-notes subcommand, or cut's first-ever bootstrap).
    def default_since
      (Date.today - 7).iso8601
    end

    # Pure formatter over PR hashes (keys "number", "title", "author.is_bot").
    # Three grouped headers rendered only if non-empty: Features / Fixes / Other.
    def format(prs)
      non_bot = prs.reject { |pr| pr.dig("author", "is_bot") }

      sections = []
      sections << render_section("Features", non_bot.select { |pr| feat?(pr) })
      sections << render_section("Fixes", non_bot.select { |pr| fix?(pr) })
      sections << render_section("Other", non_bot.reject { |pr| feat?(pr) || fix?(pr) })
      sections.compact.join
    end

    def feat?(pr)
      pr.fetch("title").match?(/\Afeat/i)
    end

    def fix?(pr)
      pr.fetch("title").match?(/\Afix/i)
    end

    def render_section(header, prs)
      return nil if prs.empty?

      lines = prs.map { |pr| "- #{pr.fetch("title")} (##{pr.fetch("number")})" }
      "## #{header}\n#{lines.join("\n")}\n\n"
    end
    private_class_method :render_section
  end
end
