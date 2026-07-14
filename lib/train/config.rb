# frozen_string_literal: true

require "yaml"
require "time"

module Train
  # release-config.yml parsing + the cut "slot decision": is THIS
  # invocation the one true daily trigger for 15:45 America/New_York?
  #
  # Ports the release-cut.yml "Slot / day / skip decision" step. The bash
  # avoided wall-clock TZ arithmetic in Ruby-hostile ways by shelling out to
  # `TZ=America/New_York date`; here we use Ruby's Time with an explicit
  # America/New_York zone. Two cron slots exist ("45 19 * * *" and
  # "45 20 * * *") because 15:45 ET maps to different UTC hours across DST;
  # exactly one is correct for any given day, decided by the ET UTC offset.
  module Config
    Decision = Struct.new(:go, :reason, keyword_init: true)

    module_function

    def load(path = "release-config.yml")
      require "date"
      # permitted_classes: [Date] — release-config.yml's skip-dates are
      # written as bare ISO dates (e.g. "[2026-11-26]"), which YAML sniffs
      # as native date scalars rather than strings. Normalize back to
      # strings immediately: every comparison against "today" elsewhere in
      # this tool is string equality (Time#strftime("%F")).
      data = YAML.safe_load_file(path, permitted_classes: [Date]) || {}
      {
        "cut-day" => data.fetch("cut-day", "thursday"),
        "skip-dates" => Array(data["skip-dates"]).map { |d| d.is_a?(Date) ? d.iso8601 : d.to_s }
      }
    end

    # Ensures Ruby's Time zone math can resolve "America/New_York" even in
    # environments (observed on NixOS) where glibc needs TZDIR pointed at
    # /etc/zoneinfo explicitly for bare zone names to resolve. No-op (and
    # harmless) on systems — e.g. GitHub Actions' Ubuntu runners — where
    # bare TZ names already resolve without it.
    def ensure_tz_resolvable!
      ENV["TZ"] = "America/New_York"
      return unless ENV["TZDIR"].to_s.empty?
      return unless File.directory?("/etc/zoneinfo")

      ENV["TZDIR"] = "/etc/zoneinfo"
    end

    # today_et: the America/New_York calendar date "now" claims, as a Date.
    # date_override, if given (--date YYYY-MM-DD), replaces "today" for
    # testing without needing to mock wall-clock time.
    def today_et(date_override: nil)
      require "date"
      return Date.parse(date_override) if date_override

      ensure_tz_resolvable!
      Time.now.to_date
    end

    # et_offset_for(date): the America/New_York UTC offset (e.g. "-0400")
    # in effect at 15:45 on the given ET calendar date. Constructing the
    # Time AT that date/time (rather than using Time.now) is what makes
    # this DST-correct regardless of when the tool actually runs.
    def et_offset_for(date)
      ensure_tz_resolvable!
      Time.new(date.year, date.month, date.day, 15, 45, 0).strftime("%z")
    end

    # slot_decision: does this invocation proceed?
    #
    # force: bypasses slot/day/skip entirely (workflow_dispatch force=true,
    #   or --force).
    # schedule: the raw cron slot string from github.event.schedule (nil
    #   when not a scheduled run, e.g. workflow_dispatch without force).
    # date: the ET calendar date to decide for (today_et, possibly
    #   --date-overridden).
    # config: result of Config.load.
    def slot_decision(force:, schedule:, date:, config:)
      return Decision.new(go: true, reason: "Forced dispatch.") if force

      if schedule
        offset = et_offset_for(date)
        want = offset == "-0400" ? "45 19 * * *" : "45 20 * * *"
        unless schedule == want
          return Decision.new(go: false, reason: "Wrong slot for offset #{offset}.")
        end
      end

      cut_day = config.fetch("cut-day")
      day_name = date.strftime("%A").downcase
      unless day_name == cut_day
        return Decision.new(go: false, reason: "Not #{cut_day}.")
      end

      today = date.strftime("%F")
      if config.fetch("skip-dates").include?(today)
        return Decision.new(go: false, reason: "Skip date #{today}.")
      end

      Decision.new(go: true, reason: nil)
    end
  end
end
