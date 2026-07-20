# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "train/manifest"

class ManifestTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("train-manifest-test-")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def file
    File.join(@dir, "manifest.yml")
  end

  def test_init_writes_defaults
    Train::Manifest.init(
      file, version: "2.1.0", kind: "release", cut_date: "2026-07-16",
      repos: { "xmtplabs/convos-ios" => "sha-ios", "xmtplabs/convos-client" => "sha-client" }
    )
    data = Train::Manifest.read(file)

    assert_equal "2.1.0", data["version"]
    assert_equal "release", data["kind"]
    assert_equal "2026-07-16", data["cut-date"]
    assert_equal "cut", data["status"]

    ios = data["repos"]["xmtplabs/convos-ios"]
    assert_equal "sha-ios", ios["source-sha"]
    assert_equal "release/2.1.0", ios["release-branch"]
    assert_equal "pending", ios["status"]
    assert_equal [], ios["rc"]
  end

  def test_init_refuses_existing_file
    Train::Manifest.init(file, version: "1.0.0", kind: "release", cut_date: "2026-01-01", repos: {})

    assert_raises(Train::Manifest::Error) do
      Train::Manifest.init(file, version: "1.0.0", kind: "release", cut_date: "2026-01-01", repos: {})
    end
  end

  def test_append_rc_appends_new_value
    init_with_one_repo
    result = Train::Manifest.append_rc(
      file, repo: "xmtplabs/convos-ios", sha: "abc123", run: "https://run/1", key: "build-number", value: "421"
    )
    assert_equal :appended, result

    data = Train::Manifest.read(file)
    rc = data["repos"]["xmtplabs/convos-ios"]["rc"]
    assert_equal 1, rc.size
    assert_equal "abc123", rc.first["sha"]
    assert_equal 421, rc.first["build-number"]
    assert_equal "rc-available", data["repos"]["xmtplabs/convos-ios"]["status"]
  end

  def test_append_rc_same_value_is_idempotent_and_skips
    init_with_one_repo
    Train::Manifest.append_rc(
      file, repo: "xmtplabs/convos-ios", sha: "abc123", run: "https://run/1", key: "build-number", value: "421"
    )
    result = Train::Manifest.append_rc(
      file, repo: "xmtplabs/convos-ios", sha: "abc123", run: "https://run/2", key: "build-number", value: "421"
    )
    assert_equal :skipped, result

    data = Train::Manifest.read(file)
    rc = data["repos"]["xmtplabs/convos-ios"]["rc"]
    assert_equal 1, rc.size, "duplicate (sha,key,value) must not append a second entry"
  end

  def test_append_rc_new_value_for_same_sha_appends
    # WHY value-keyed idempotency: a rerun that produced a NEW artifact id
    # (e.g. a fresh TestFlight build number for the same sha) must be
    # recorded; only an exact (sha,key,value) duplicate is skipped.
    init_with_one_repo
    Train::Manifest.append_rc(
      file, repo: "xmtplabs/convos-ios", sha: "abc123", run: "https://run/1", key: "build-number", value: "421"
    )
    result = Train::Manifest.append_rc(
      file, repo: "xmtplabs/convos-ios", sha: "abc123", run: "https://run/2", key: "build-number", value: "422"
    )
    assert_equal :appended, result

    data = Train::Manifest.read(file)
    rc = data["repos"]["xmtplabs/convos-ios"]["rc"]
    assert_equal 2, rc.size
  end

  def test_append_rc_after_promotion_keeps_status_promoted
    # A late/stray RC upload (CI retry, manual rerun) landing after the repo
    # was already promoted must still record the rc entry, but must NOT
    # downgrade status back to "rc-available" — that would misrepresent an
    # already-promoted repo as still awaiting promotion.
    init_with_one_repo
    Train::Manifest.record_promotion(
      file, repo: "xmtplabs/convos-ios", key: "build-number", value: "421",
      tag: "v2.1.0", notes_sha: "notes-sha-1", run: "https://run/1"
    )

    result = Train::Manifest.append_rc(
      file, repo: "xmtplabs/convos-ios", sha: "abc123", run: "https://run/2", key: "build-number", value: "999"
    )
    assert_equal :appended, result

    data = Train::Manifest.read(file)
    repo = data["repos"]["xmtplabs/convos-ios"]
    assert_equal "promoted", repo["status"], "a late RC append must not downgrade a promoted repo's status"
    assert(repo["rc"].any? { |e| e["sha"] == "abc123" && e["build-number"] == 999 }, "the rc entry must still be recorded")
  end

  def test_append_rc_rejects_non_integer_values
    init_with_one_repo
    ["", "abc", "4.21", "-1", "1a", " 1", "0", "000"].each do |bad|
      assert_raises(Train::Manifest::Error, "expected rejection for #{bad.inspect}") do
        Train::Manifest.append_rc(
          file, repo: "xmtplabs/convos-ios", sha: "abc123", run: "https://run/1", key: "build-number", value: bad
        )
      end
    end
  end

  def test_set_repo_status
    init_with_one_repo
    Train::Manifest.set_repo_status(file, repo: "xmtplabs/convos-ios", status: "branched")
    data = Train::Manifest.read(file)
    assert_equal "branched", data["repos"]["xmtplabs/convos-ios"]["status"]
  end

  def test_set_status_writes_top_level_status
    init_with_one_repo
    Train::Manifest.set_status(file, "branched")
    data = Train::Manifest.read(file)
    assert_equal "branched", data["status"]
  end

  # YAML field names must be EXACTLY kebab-case, matching what the bash
  # (via yq) produces — app-repo workflows parse this same file. Assert
  # against the raw file content, not just the parsed hash, so a stray
  # camelCase or snake_case regression is caught even if Ruby's hash
  # access happens to still work via some alias.
  def test_yaml_keys_are_kebab_case_literally
    Train::Manifest.init(
      file, version: "2.1.0", kind: "release", cut_date: "2026-07-16",
      repos: { "xmtplabs/convos-ios" => "sha-ios" }
    )
    Train::Manifest.append_rc(
      file, repo: "xmtplabs/convos-ios", sha: "sha-ios", run: "https://run/1", key: "build-number", value: "421"
    )
    raw = File.read(file)

    assert_match(/^cut-date:/, raw)
    assert_match(/source-sha:/, raw)
    assert_match(/release-branch:/, raw)
    assert_match(/build-number:/, raw)
    refute_match(/cutDate/, raw)
    refute_match(/cut_date/, raw)
    refute_match(/sourceSha/, raw)
    refute_match(/source_sha/, raw)
  end

  # ---- record_promotion ----

  def test_record_promotion_writes_promoted_block_and_repo_status
    init_with_one_repo
    changed = Train::Manifest.record_promotion(
      file, repo: "xmtplabs/convos-ios", key: "build-number", value: "421",
      tag: "v2.1.0", notes_sha: "notes-sha-1", run: "https://run/1"
    )
    assert_equal true, changed

    data = Train::Manifest.read(file)
    repo = data["repos"]["xmtplabs/convos-ios"]
    assert_equal "promoted", repo["status"]
    assert_equal({
      "build-number" => 421, "tag" => "v2.1.0", "notes-sha" => "notes-sha-1", "run" => "https://run/1"
    }, repo["promoted"])
  end

  def test_record_promotion_sets_top_level_status_only_when_every_repo_promoted
    Train::Manifest.init(
      file, version: "2.1.0", kind: "release", cut_date: "2026-07-16",
      repos: { "xmtplabs/convos-ios" => "sha-ios", "xmtplabs/convos-client" => "sha-client" }
    )

    Train::Manifest.record_promotion(
      file, repo: "xmtplabs/convos-ios", key: "build-number", value: "421",
      tag: "v2.1.0", notes_sha: "notes-sha-1", run: "https://run/1"
    )
    data = Train::Manifest.read(file)
    refute_equal "promoted", data["status"], "top-level status must not flip until every repo is promoted"

    Train::Manifest.record_promotion(
      file, repo: "xmtplabs/convos-client", key: "version-code", value: "77",
      tag: "v2.1.0", notes_sha: "notes-sha-1", run: "https://run/2"
    )
    data = Train::Manifest.read(file)
    assert_equal "promoted", data["status"]
  end

  def test_record_promotion_is_idempotent_for_identical_block
    init_with_one_repo
    Train::Manifest.record_promotion(
      file, repo: "xmtplabs/convos-ios", key: "build-number", value: "421",
      tag: "v2.1.0", notes_sha: "notes-sha-1", run: "https://run/1"
    )
    changed = Train::Manifest.record_promotion(
      file, repo: "xmtplabs/convos-ios", key: "build-number", value: "421",
      tag: "v2.1.0", notes_sha: "notes-sha-1", run: "https://run/1"
    )
    assert_equal false, changed
  end

  def test_record_promotion_rejects_non_integer_value
    init_with_one_repo
    assert_raises(Train::Manifest::Error) do
      Train::Manifest.record_promotion(
        file, repo: "xmtplabs/convos-ios", key: "build-number", value: "abc",
        tag: "v2.1.0", notes_sha: "notes-sha-1", run: "https://run/1"
      )
    end
  end

  # ---- add_repo ----

  def test_add_repo_appends_a_pending_entry_and_resets_top_level_status
    init_with_one_repo
    Train::Manifest.set_status(file, "promoted")

    Train::Manifest.add_repo(file, repo: "xmtplabs/convos-client", sha: "sha-android", branch: "hotfix/2.1.0")

    data = Train::Manifest.read(file)
    entry = data["repos"]["xmtplabs/convos-client"]
    assert_equal(
      { "source-sha" => "sha-android", "release-branch" => "hotfix/2.1.0", "status" => "pending", "rc" => [] },
      entry
    )
    assert_equal "branched", data["status"]
    assert_equal "sha-ios", data["repos"]["xmtplabs/convos-ios"]["source-sha"]
  end

  def test_add_repo_refuses_an_already_present_repo
    init_with_one_repo

    err = assert_raises(Train::Manifest::Error) do
      Train::Manifest.add_repo(file, repo: "xmtplabs/convos-ios", sha: "other", branch: "hotfix/2.1.0")
    end
    assert_match(/already in manifest/, err.message)
  end

  # ---- set_announcement ----

  def test_set_announcement_writes_channel_and_ts
    init_with_one_repo
    Train::Manifest.set_announcement(file, channel: "C0APP", ts: "1700000000.000100")

    data = Train::Manifest.read(file)
    assert_equal({ "channel" => "C0APP", "ts" => "1700000000.000100" }, data["announcement"])
  end

  def test_set_announcement_overwrites_existing_block
    init_with_one_repo
    Train::Manifest.set_announcement(file, channel: "C0APP", ts: "1700000000.000100")
    Train::Manifest.set_announcement(file, channel: "C0APP", ts: "1700000001.000200")

    data = Train::Manifest.read(file)
    assert_equal({ "channel" => "C0APP", "ts" => "1700000001.000200" }, data["announcement"])
  end

  private

  def init_with_one_repo
    Train::Manifest.init(
      file, version: "2.1.0", kind: "release", cut_date: "2026-07-16",
      repos: { "xmtplabs/convos-ios" => "sha-ios" }
    )
  end
end
