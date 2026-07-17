# frozen_string_literal: true

# Records post_cut calls; nothing touches Slack in tests. Returns the thread
# anchor shape production Notify returns so Cut's ai-notes hand-off is exercised.
class FakeNotifier
  attr_reader :cuts

  def initialize
    @cuts = []
  end

  def post_cut(version:, kind:)
    @cuts << { version: version, kind: kind }
    { channel: "C0APP", ts: "1700000000.000100" }
  end
end
