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

    # Quote-aware (a ">" inside a quoted attribute doesn't end the tag) and
    # anchored to elements (</? + letter) so prose like "a < b > c" survives.
    TAG_RE = %r{</?[A-Za-z](?:[^<>"']|"[^"]*"|'[^']*')*>}
    # Hidden editorial text must never publish.
    COMMENT_RE = /<!--.*?-->/m
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

      # Alt text only — StripDown would leave the raw asset URL behind.
      def image(_link, _title, alt_text)
        alt_text
      end

      def paragraph(text)
        "#{text}\n\n"
      end

      # StripDown passes raw HTML through — strip comments and tags, keep
      # the text.
      def raw_html(html)
        html.gsub(COMMENT_RE, "").gsub(TAG_RE, "")
      end

      def block_html(html)
        "#{html.gsub(COMMENT_RE, "").gsub(TAG_RE, "")}\n"
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

    # The final TAG_RE pass catches tags redcarpet's tokenizer hands through
    # as plain text (e.g. attributes containing ">"), which never reach the
    # raw_html callback.
    def render_with(renderer, markdown)
      # autolink keeps <https://…>/<a@b.c> parsed as links — otherwise the
      # TAG_RE pass below would eat them as pseudo-tags.
      Redcarpet::Markdown.new(renderer, strikethrough: true, tables: true, autolink: true)
                         .render(to_utf8(markdown.to_s))
                         .gsub(COMMENT_RE, "")
                         .gsub(TAG_RE, "")
                         .gsub(/[ \t]{2,}/, " ")
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
