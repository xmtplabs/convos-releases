# frozen_string_literal: true

module Train
  # Publishes key=value pairs to the step log and, under GitHub Actions,
  # to GITHUB_OUTPUT for later workflow steps.
  module Outputs
    module_function

    def emit(pairs, out: $stdout)
      lines = pairs.map { |k, v| "#{k}=#{v}" }
      lines.each { |line| out.puts(line) }

      path = ENV["GITHUB_OUTPUT"]
      return if path.to_s.empty?

      File.open(path, "a") { |f| lines.each { |line| f.puts(line) } }
    end
  end
end
