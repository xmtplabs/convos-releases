# frozen_string_literal: true

# A developer shell may carry a real webhook — tests must never post to
# Slack, even where a default Train::Notify gets constructed.
ENV.delete("SLACK_WEBHOOK_URL")

# The nix sandbox runs under a US-ASCII locale; the store-notes bullets
# are UTF-8 — match what real runners use.
Encoding.default_external = Encoding::UTF_8

# The repo's nix devshell wraps Ruby with GEM_HOME/GEM_PATH pinned to the
# fastlane bundlerEnv gemset — train has no test-only deps of its own; it
# reuses whatever's already in that gemset (octokit for train/github.rb,
# plus anything a future require pulls in). minitest ships as a default
# gem bundled inside the underlying ruby_3_4 derivation itself, but the
# bundler-wrapped `ruby` on PATH can't RubyGems-activate it (BUNDLE_FROZEN=1,
# GEM_PATH doesn't include it). Since the wrapper is a thin execve of the
# real interpreter (RbConfig still reports the real store path), we can
# load minitest directly off disk via $LOAD_PATH instead of gem activation
# — no new gem, no flake/devshell change, just finding what's already there.
default_gems = File.join(RbConfig::CONFIG["prefix"], "lib", "ruby", "gems", RbConfig::CONFIG["ruby_version"], "gems")
minitest_lib = Dir.glob(File.join(default_gems, "minitest-*", "lib")).max_by { |p| p }
$LOAD_PATH.unshift(minitest_lib) if minitest_lib && !$LOAD_PATH.include?(minitest_lib)

require "minitest/autorun"
