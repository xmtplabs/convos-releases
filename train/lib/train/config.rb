# frozen_string_literal: true

require "yaml"
require "time"
require "tzinfo"
require "tzinfo/data"

module Train
  # release-config.yml parsing + the cut "slot decision": is THIS
  # invocation the one true daily trigger for 15:45 America/New_York?
  #
  # Ports the release-cut.yml "Slot / day / skip decision" step. Two cron
  # slots exist ("45 19 * * *" and "45 20 * * *") because 15:45 ET maps to
  # different UTC hours across DST; exactly one is correct for any given
  # day, resolved via tzinfo rather than offset-string or ENV["TZ"] tricks.
  module Config
    Decision = Struct.new(:go, :reason, keyword_init: true)

    NY = TZInfo::Timezone.get("America/New_York")

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

    # today_et: the America/New_York calendar date "now" claims, as a Date.
    # date_override, if given (--date YYYY-MM-DD), replaces "today" for
    # testing without needing to mock wall-clock time.
    def today_et(date_override: nil)
      require "date"
      return Date.parse(date_override) if date_override

      NY.to_local(Time.now.utc).to_date
    end

    # et_offset_for(date): the America/New_York UTC offset (e.g. "-0400")
    # in effect at 15:45 local time on the given ET calendar date.
    # period_for_local resolves the wall-clock reading directly (no
    # UTC->local round-trip), so this is exact even on DST transition days.
    def et_offset_for(date)
      local = Time.utc(date.year, date.month, date.day, 15, 45, 0)
      offset = NY.period_for_local(local).utc_total_offset
      format("%+03d%02d", offset / 3600, (offset.abs / 60) % 60)
    end

    # slot_matches?(schedule, date): does the cron slot string ("MM HH * * *",
    # UTC) land on 15:45 America/New_York for this calendar date? Exactly one
    # of the two possible slots ("45 19 * * *", "45 20 * * *") matches any
    # given date, DST-transition days included.
    def slot_matches?(schedule, date)
      minute, hour, = schedule.split(" ").map(&:to_i)
      utc = Time.utc(date.year, date.month, date.day, hour, minute, 0)
      local = NY.to_local(utc)
      local.hour == 15 && local.min == 45
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

      if schedule && !slot_matches?(schedule, date)
        offset = et_offset_for(date)
        return Decision.new(go: false, reason: "Wrong slot for offset #{offset}.")
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
