# frozen_string_literal: true

require_relative "test_helper"

# Glob, never a hand-maintained list — a new *_test.rb that nobody requires
# is a suite that silently shrinks.
Dir.glob(File.join(__dir__, "*_test.rb")).sort.each { |file| require file }
