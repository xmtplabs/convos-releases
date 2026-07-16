# frozen_string_literal: true

# Records post_cut calls; nothing touches Slack in tests.
class FakeNotifier
  attr_reader :cuts

  def initialize
    @cuts = []
  end

  def post_cut(version:, kind:)
    @cuts << { version: version, kind: kind }
  end
end
