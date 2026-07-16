# frozen_string_literal: true

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
    ENTITIES = {
      "&amp;" => "&", "&lt;" => "<", "&gt;" => ">",
      "&quot;" => "\"", "&#39;" => "'", "&nbsp;" => " "
    }.freeze

    class StoreText < Redcarpet::Render::StripDown
      def header(text, _level)
        "#{text.sub(/:\s*\z/, "")}:\n"
      end

      def list_item(text, _list_type)
        "• #{text.strip}\n"
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
        ENTITIES.fetch(text, text)
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

    # Output is always UTF-8 (the bullets are), independent of the process
    # locale a caller read the markdown under; invalid bytes are scrubbed
    # rather than exploding inside the C extension.
    def render_with(renderer, markdown)
      text = markdown.to_s
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      text = text.scrub("?") unless text.valid_encoding?

      Redcarpet::Markdown.new(renderer, strikethrough: true, tables: true)
                         .render(text)
                         .gsub(/\n{3,}/, "\n\n")
                         .strip
    end
  end
end
