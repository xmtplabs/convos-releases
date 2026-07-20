# frozen_string_literal: true

# Records request calls; nothing touches the network in tests.
class FakeAiNotes
  attr_reader :requests

  def initialize
    @requests = []
  end

  def request(version:, slack: nil)
    @requests << { version: version, slack: slack }
    true
  end
end
