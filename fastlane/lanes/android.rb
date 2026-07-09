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
end
