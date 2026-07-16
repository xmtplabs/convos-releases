# frozen_string_literal: true

require "cgi/escape"
require "redcarpet"
require "redcarpet/render_strip"

module Train
  # Renders release-notes markdown into store-ready plain text — neither
  # store renders markup. Headers become "Header:" lines, list items get
  # real bullets, links reduce to their text, emphasis/strikethrough/HTML
  # tags are stripped, entities decode.
  module StoreNotes
    PLAY_LIMIT = 500

    TAG_RE = /<[^>]*>/
    # Named entities CGI.unescapeHTML doesn't cover (it handles the XML
    # five plus numeric references).
    EXTRA_ENTITIES = {
      "&nbsp;" => " ", "&copy;" => "©", "&reg;" => "®", "&trade;" => "™",
      "&rsquo;" => "’", "&lsquo;" => "‘", "&rdquo;" => "”", "&ldquo;" => "“",
      "&ndash;" => "–", "&mdash;" => "—", "&hellip;" => "…"
    }.freeze

    class StoreText < Redcarpet::Render::StripDown
      def header(text, _level)
        "#{text.sub(/:\s*\z/, "")}:\n"
      end

      def list_item(text, _list_type)
        "• #{text.strip}\n"
      end

      # Blank line after each list so sections stay visually separated.
      def list(content, _list_type)
        "#{content}\n"
      end

      def link(_link, _title, content)
        content
      end

      def paragraph(text)
        "#{text}\n\n"
      end

      # StripDown passes raw HTML through — strip the tags, keep the text.
      def raw_html(html)
        html.gsub(TAG_RE, "")
      end

      def block_html(html)
        "#{html.gsub(TAG_RE, "")}\n"
      end

      def entity(text)
        EXTRA_ENTITIES.fetch(text) { CGI.unescapeHTML(text) }
      end
    end

    # Reviewer notes keep their URLs — App Review needs the test-environment
    # links a listing would drop.
    class ReviewerText < StoreText
      def link(link, _title, content)
        "#{content} (#{link})"
      end
    end

    module_function

    # Store-listing text: links reduce to their text.
    def render(markdown)
      render_with(StoreText.new, markdown)
    end

    # Reviewer-notes text: same typography, URLs preserved as "text (url)".
    def render_reviewer(markdown)
      render_with(ReviewerText.new, markdown)
    end

    def render_with(renderer, markdown)
      Redcarpet::Markdown.new(renderer, strikethrough: true, tables: true)
                         .render(to_utf8(markdown.to_s))
                         .gsub(/\n{3,}/, "\n\n")
                         .strip
    end

    # Force-first, transcode-fallback: the common wrong input is UTF-8
    # bytes mislabeled by a C locale (reclaim them intact); only bytes that
    # aren't UTF-8 at all get transcoded from their tagged encoding, with
    # "?" for anything unmappable — never an exception from the C extension.
    def to_utf8(text)
      return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

      forced = text.dup.force_encoding(Encoding::UTF_8)
      return forced if forced.valid_encoding?

      text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    rescue Encoding::ConverterNotFoundError
      forced.scrub("?")
    end
  end
end
