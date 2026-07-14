# Entry point for convos-client (android). Imported by that repo's stub
# Fastfile (android/fastlane/Fastfile).
platform :android do
  desc "Build devRelease APK and upload to Firebase App Distribution"
  lane :pr_adhoc do
    gradle(task: "assembleDevRelease")

    # The gradle action publishes the built APK's absolute path; don't glob
    # relative paths — the lane's cwd is not the gradle root.
    apk = lane_context[SharedValues::GRADLE_APK_OUTPUT_PATH]
    UI.user_error!("gradle reported no devRelease APK output") if apk.to_s.empty? || !File.exist?(apk)

    firebase_app_distribution(
      app: ENV.fetch("FIREBASE_APP_ID_ANDROID_DEV"),
      # Prefer JSON content in memory; fall back to a file path so local
      # runs with a downloaded key still work. Mirrors the ios lane.
      service_credentials_json_data: ENV["FIREBASE_SERVICE_ACCOUNT_JSON_CONTENT"],
      service_credentials_file: ENV["FIREBASE_SERVICE_ACCOUNT_JSON"],
      groups: ENV.fetch("FIREBASE_TESTER_GROUPS", "xmtp-internal"),
      release_notes: android_release_notes,
      android_artifact_type: "APK",
      android_artifact_path: apk,
    )
  end

  # Compose release notes from PR metadata when running in CI, otherwise
  # fall back to the latest commit subject.
  def android_release_notes
    pr_number = first_non_empty_android(ENV["GITHUB_PR_NUMBER"], ENV["PR_NUMBER"])
    pr_title  = first_non_empty_android(ENV["GITHUB_PR_TITLE"],  ENV["PR_TITLE"])
    sha       = ENV["GITHUB_SHA"]&.slice(0, 7)

    if pr_number && pr_title
      "PR ##{pr_number}: #{pr_title}#{sha ? " (#{sha})" : ""}"
    else
      `git log -1 --pretty=%s`.strip
    end
  end

  # Empty strings are truthy in Ruby; GitHub Actions sets these to "" on
  # workflow_dispatch (non-PR triggers).
  def first_non_empty_android(*values)
    values.compact.map(&:to_s).map(&:strip).find { |v| !v.empty? }
  end

  desc "Build prodRelease AAB and upload to the Play Store internal testing track"
  lane :play_internal do
    require "fileutils"
    require "json"

    # Validate the Play credential BEFORE the expensive build: the lane's
    # contract is a readable service-account JSON file path.
    sa_path = ENV.fetch("PLAY_SERVICE_ACCOUNT_JSON_PATH")
    UI.user_error!("Play service account file missing or unreadable: #{sa_path}") unless File.readable?(sa_path)
    begin
      JSON.parse(File.read(sa_path))
    rescue JSON::ParserError => e
      UI.user_error!("Play service account file is not valid JSON: #{e.message}")
    end

    # Deterministic, monotonic versionCode: commit timestamp / 60.
    # Same sha => same code, so an accidental duplicate upload fails loudly
    # at Play instead of silently shipping twins. ~29.7M today, far under
    # Play's 2.1B cap and far above the static code in gradle.properties.
    commit_epoch = `git show -s --format=%ct HEAD`.strip
    UI.user_error!("could not read HEAD commit timestamp") if commit_epoch.empty?
    version_code = commit_epoch.to_i / 60

    # Plausibility guard: reject garbage (failed git plumbing) and
    # future-dated commits — a code above "now" would poison the monotonic
    # watermark and block every subsequent upload until dev catches up.
    now_code = Time.now.to_i / 60
    unless version_code.between?(29_000_000, now_code + 1440)
      UI.user_error!("versionCode #{version_code} implausible (expected 29,000,000..#{now_code + 1440}); check HEAD commit timestamp")
    end

    # Changelog file supply matches to the AAB's versionCode by filename.
    # Absolute path, resolved once: FastlaneFolder.path can be a memoized
    # RELATIVE "./" and supply evaluates relative paths under a different
    # cwd than the lane.
    metadata_dir = File.expand_path(File.join(FastlaneCore::FastlaneFolder.path, "metadata", "android"))
    changelog_dir = File.join(metadata_dir, "en-US", "changelogs")
    FileUtils.mkdir_p(changelog_dir)
    # Play rejects release notes over 500 characters — truncate, don't fail
    # a finished build over a long commit subject.
    File.write(File.join(changelog_dir, "#{version_code}.txt"),
               play_internal_release_notes[0, 500])

    gradle(
      task: "bundleProdRelease",
      properties: { "VERSION_CODE" => version_code },
    )

    aab = lane_context[SharedValues::GRADLE_AAB_OUTPUT_PATH]
    UI.user_error!("gradle reported no prodRelease AAB output") if aab.to_s.empty? || !File.exist?(aab)

    upload_to_play_store(
      package_name: "org.convos.android",
      track: "internal",
      release_status: "completed",
      aab: aab,
      # _PATH suffix: this is a file path; the GHA secret of the similar
      # name is base64 content, decoded to a file by the workflow.
      json_key: sa_path,
      metadata_path: metadata_dir,
      skip_upload_apk: true,
      skip_upload_metadata: true,
      skip_upload_images: true,
      skip_upload_screenshots: true,
    )
  end

  # Same composition as the iOS testflight_release_notes helper.
  def play_internal_release_notes
    sha     = (ENV["GITHUB_SHA"] || `git rev-parse HEAD`.strip).slice(0, 7)
    subject = `git log -1 --pretty=%s`.strip
    branch  = ENV["GITHUB_REF_NAME"] || `git rev-parse --abbrev-ref HEAD`.strip
    "#{subject}\nBranch: #{branch}\nCommit: #{sha}"
  end

  desc "Build prodRelease APK and upload to Firebase App Distribution (dev-stream prod builds)"
  lane :prod_adhoc do
    gradle(task: "assembleProdRelease")

    apk = lane_context[SharedValues::GRADLE_APK_OUTPUT_PATH]
    UI.user_error!("gradle reported no prodRelease APK output") if apk.to_s.empty? || !File.exist?(apk)

    firebase_app_distribution(
      app: ENV.fetch("FIREBASE_APP_ID_ANDROID_PROD"),
      service_credentials_json_data: ENV["FIREBASE_SERVICE_ACCOUNT_JSON_CONTENT"],
      service_credentials_file: ENV["FIREBASE_SERVICE_ACCOUNT_JSON"],
      groups: ENV.fetch("FIREBASE_TESTER_GROUPS", "xmtp-prod-internal"),
      release_notes: play_internal_release_notes[0, 500],
      android_artifact_type: "APK",
      android_artifact_path: apk,
    )
  end
end
