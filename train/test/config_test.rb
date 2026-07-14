# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "date"
require "train/config"

class ConfigTest < Minitest::Test
  EDT_THU = Date.new(2026, 7, 16)   # America/New_York: -0400 (EDT), Thursday
  EST_THU = Date.new(2026, 12, 17)  # America/New_York: -0500 (EST), Thursday
  EDT_WRONG_DAY = Date.new(2026, 7, 17) # Friday, EDT
  SPRING_FORWARD = Date.new(2026, 3, 8)  # DST starts 2am ET; still EDT by 15:45
  FALL_BACK = Date.new(2026, 11, 1)      # DST ends 2am ET; already EST by 15:45

  def setup
    @dir = Dir.mktmpdir("train-config-test-")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_config(cut_day: "thursday", skip_dates: [])
    path = File.join(@dir, "release-config.yml")
    File.write(path, "cut-day: #{cut_day}\nskip-dates: [#{skip_dates.join(", ")}]\n")
    path
  end

  def test_load_parses_cut_day_and_skip_dates
    cfg = Train::Config.load(write_config(cut_day: "thursday", skip_dates: ["2026-11-26"]))
    assert_equal "thursday", cfg.fetch("cut-day")
    assert_equal ["2026-11-26"], cfg.fetch("skip-dates")
  end

  def test_load_defaults_skip_dates_to_empty_array
    path = File.join(@dir, "release-config.yml")
    File.write(path, "cut-day: thursday\n")
    cfg = Train::Config.load(path)
    assert_equal [], cfg.fetch("skip-dates")
  end

  def test_et_offset_edt
    assert_equal "-0400", Train::Config.et_offset_for(EDT_THU)
  end

  def test_et_offset_est
    assert_equal "-0500", Train::Config.et_offset_for(EST_THU)
  end

  # ---- slot decision truth table ----
  # EDT date x both slots
  def test_edt_correct_slot_and_day_goes
    d = Train::Config.slot_decision(
      force: false, schedule: "45 19 * * *", date: EDT_THU, config: base_config
    )
    assert d.go, d.reason
  end

  def test_edt_wrong_slot_declines
    d = Train::Config.slot_decision(
      force: false, schedule: "45 20 * * *", date: EDT_THU, config: base_config
    )
    refute d.go
    assert_match(/wrong slot/i, d.reason)
  end

  # EST date x both slots
  def test_est_correct_slot_and_day_goes
    d = Train::Config.slot_decision(
      force: false, schedule: "45 20 * * *", date: EST_THU, config: base_config
    )
    assert d.go, d.reason
  end

  def test_est_wrong_slot_declines
    d = Train::Config.slot_decision(
      force: false, schedule: "45 19 * * *", date: EST_THU, config: base_config
    )
    refute d.go
    assert_match(/wrong slot/i, d.reason)
  end

  def test_wrong_day_declines
    d = Train::Config.slot_decision(
      force: false, schedule: "45 19 * * *", date: EDT_WRONG_DAY, config: base_config
    )
    refute d.go
    assert_match(/not thursday/i, d.reason)
  end

  def test_skip_date_declines
    cfg = base_config.merge("skip-dates" => ["2026-07-16"])
    d = Train::Config.slot_decision(
      force: false, schedule: "45 19 * * *", date: EDT_THU, config: cfg
    )
    refute d.go
    assert_match(/skip date/i, d.reason)
  end

  def test_force_bypasses_slot_day_and_skip
    cfg = base_config.merge("skip-dates" => ["2026-07-16"])
    d = Train::Config.slot_decision(
      force: true, schedule: "45 20 * * *", date: EDT_WRONG_DAY, config: cfg
    )
    assert d.go, d.reason
  end

  # ---- DST transition days ----
  def test_spring_forward_sunday_maps_to_edt_slot
    assert Train::Config.slot_matches?("45 19 * * *", SPRING_FORWARD)
    refute Train::Config.slot_matches?("45 20 * * *", SPRING_FORWARD)
  end

  def test_fall_back_sunday_maps_to_est_slot
    refute Train::Config.slot_matches?("45 19 * * *", FALL_BACK)
    assert Train::Config.slot_matches?("45 20 * * *", FALL_BACK)
  end

  def test_no_schedule_dispatch_without_force_still_checks_day_and_skip
    # workflow_dispatch without force=true: schedule is nil (no cron slot to
    # validate), but day/skip checks still apply.
    d = Train::Config.slot_decision(
      force: false, schedule: nil, date: EDT_THU, config: base_config
    )
    assert d.go, d.reason

    d2 = Train::Config.slot_decision(
      force: false, schedule: nil, date: EDT_WRONG_DAY, config: base_config
    )
    refute d2.go
  end

  private

  def base_config
    { "cut-day" => "thursday", "skip-dates" => [] }
  end
end
