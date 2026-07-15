# frozen_string_literal: true

require "date"

module Train
  # Seed release notes from merged dev PRs. Only bot authors are filtered;
  # label-based filtering is deliberately absent (a dependencies PR can fix
  # a user-visible crash — humans prune, automation doesn't hide).
  module Notes
    # HOTFIX_PLACEHOLDER: the marker sentence Hotfix seeds into platform
    # notes files. Promote#prepare refuses to stage notes that still
    # contain it — the seeded template must never reach a store listing.
    HOTFIX_PLACEHOLDER = "Describe the fix being shipped"

    module_function

    # default_since: 7-day fallback when no explicit --since / prior
    # manifest cut-date is available (the seed-notes CLI subcommand, or
    # cut's own bootstrap case — the first-ever cut, with no prior
    # manifest to derive a boundary from).
    def default_since
      (Date.today - 7).iso8601
    end

    # format(prs): prs is an array of hashes with string keys "number",
    # "title", "author" => { "is_bot" => bool }. Pure formatter — no gh
    # calls — so it's directly testable. Mirrors the bash's `section`
    # helper: three grouped headers, each rendered only if it has entries,
    # in Features / Fixes / Other order.
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
