platform :ios do
  desc "Build Convos (Prod) and upload to TestFlight internal groups"
  lane :testflight_prod do
    setup_ci if is_ci
    setup_app_store_connect_api_key

    # Self-healing CFBundleVersion: prefer git's monotonic commit count, but
    # always overshoot the highest build currently in TestFlight so re-runs
    # and out-of-order pushes never collide with ASC's "must be greater" rule.
    git_count = `git rev-list --count HEAD`.strip.to_i
    latest_tf = latest_testflight_build_number(
      app_identifier: PROD_BUNDLE_ID,
      initial_build_number: 0,
    )
    build_number = [git_count, latest_tf + 1].max
    UI.message("Build number: git=#{git_count}, latest_tf=#{latest_tf}, using=#{build_number}")

    # Surface the chosen CFBundleVersion to the workflow (train manifest
    # recording); no-op outside GitHub Actions. .to_s.empty? guards against
    # an exported-but-empty GITHUB_OUTPUT, which would otherwise crash
    # File.open("").
    unless ENV["GITHUB_OUTPUT"].to_s.empty?
      File.open(ENV["GITHUB_OUTPUT"], "a") { |f| f.puts "build-number=#{build_number}" }
    end

    increment_build_number(
      build_number: build_number,
      xcodeproj: PROJECT,
    )

    match(
      type: "appstore",
      git_url: MATCH_GIT_URL,
      app_identifier: [PROD_BUNDLE_ID, PROD_NSE_BUNDLE_ID, PROD_SHARE_EXTENSION_BUNDLE_ID],
      readonly: is_ci,
    )

    # Do not hardcode the profile names. The portal name can carry a numeric
    # suffix (e.g. "match AppStore org.convos.ios.ConvosNSE 1777583017") when
    # a name collides on the developer portal, and that suffix changes if the
    # profile is regenerated. match publishes the real installed name per
    # bundle id in sigh_<id>_appstore_profile-name; read those and write them
    # into the Manual-signing build settings just before archiving.
    app_profile = match_profile_name(PROD_BUNDLE_ID)
    nse_profile = match_profile_name(PROD_NSE_BUNDLE_ID)
    share_extension_profile = match_profile_name(PROD_SHARE_EXTENSION_BUNDLE_ID)

    apply_prod_signing("Convos", app_profile)
    apply_prod_signing("NotificationService", nse_profile)
    apply_prod_signing("ShareExtension", share_extension_profile)

    build_app(
      project: PROJECT,
      scheme: PROD_SCHEME,
      configuration: PROD_CONFIG,
      export_method: "app-store",
      output_directory: OUTPUT_DIR,
      output_name: "Convos-Prod-TestFlight.ipa",
      clean: true,
      # gym's xcodeproj-based profile auto-detection can't resolve bundle IDs
      # defined via .xcconfig variables ($(CONVOS_BUNDLE_ID) etc.), so it maps
      # them to an empty "" key and merges that into the export options. Xcode
      # 26's exportArchive rejects the resulting plist ("isn't in the correct
      # format"). We supply the full mapping explicitly below, so skip detection.
      skip_profile_detection: true,
      export_options: {
        provisioningProfiles: {
          PROD_BUNDLE_ID     => app_profile,
          PROD_NSE_BUNDLE_ID => nse_profile,
          PROD_SHARE_EXTENSION_BUNDLE_ID => share_extension_profile,
        },
      },
    )

    # Internal-only distribution. All prod TestFlight groups (Convos iOS Team,
    # Convos Team, Friends and Family, XMTP Labs Team) are internal, and Apple
    # makes a build available to internal testers automatically once it finishes
    # processing - you cannot (and need not) explicitly attach a build to an
    # internal group. pilot's groups: option is for external distribution, so
    # passing internal groups makes it call add_beta_groups and Apple rejects it
    # ("Cannot add internal group to a build"). skip_submission uploads, waits
    # for processing, and sets the changelog, but returns before the distribute
    # step, so no group assignment or beta-review submission is attempted.
    upload_to_testflight(
      ipa: File.join(OUTPUT_DIR, "Convos-Prod-TestFlight.ipa"),
      app_identifier: PROD_BUNDLE_ID,
      changelog: testflight_release_notes,
      skip_submission: true,
    )
  end

  desc "Stage an already-uploaded build's App Store Connect metadata (no binary upload, no submission)"
  lane :stage_appstore do
    setup_ci if is_ci
    setup_app_store_connect_api_key

    # Every TRAIN_* var is validated non-empty with a clear error before any
    # ASC call — a blank version/build number would otherwise surface as an
    # opaque deliver/Spaceship failure much later.
    train_version = ENV.fetch("TRAIN_VERSION", "").strip
    UI.user_error!("TRAIN_VERSION is required and must not be empty") if train_version.empty?

    train_build_number = ENV.fetch("TRAIN_BUILD_NUMBER", "").strip
    UI.user_error!("TRAIN_BUILD_NUMBER is required and must not be empty") if train_build_number.empty?

    notes_dir = ENV.fetch("TRAIN_NOTES_DIR", "").strip
    UI.user_error!("TRAIN_NOTES_DIR is required and must not be empty") if notes_dir.empty?
    UI.user_error!("TRAIN_NOTES_DIR does not exist: #{notes_dir}") unless Dir.exist?(notes_dir)

    ios_notes_path = File.join(notes_dir, "ios.md")
    UI.user_error!("ios notes file missing: #{ios_notes_path}") unless File.readable?(ios_notes_path)
    # ASC rejects "what's new" text over 4000 characters — truncate, don't
    # fail a finished staging over a long changelog.
    notes_text = File.read(ios_notes_path)[0, 4000]

    review_notes_path = File.join(notes_dir, "submission-notes.md")
    UI.user_error!("submission notes file missing: #{review_notes_path}") unless File.readable?(review_notes_path)
    review_notes_text = File.read(review_notes_path)

    deliver(
      app_identifier: PROD_BUNDLE_ID,
      app_version: train_version,
      build_number: train_build_number,
      skip_binary_upload: true,
      skip_screenshots: true,
      skip_app_version_update: false,
      submit_for_review: false,
      force: true,
      precheck_include_in_app_purchases: false,
      release_notes: { "default" => notes_text, "en-US" => notes_text },
      submission_information: { add_id_info_uses_idfa: false },
      app_review_information: { notes: review_notes_text },
    )

    # deliver's own build-selection (Deliver::SubmitForReview#select_build)
    # only runs inside submit_for_review's path (submit_for_review.rb) — with
    # submit_for_review: false above, build_number is silently ignored and NO
    # build gets attached to the edit version. Attach it explicitly here via
    # the same Spaceship calls deliver's submit_for_review.rb uses (its
    # setup_app_store_connect_api_key call already configured the ConnectAPI
    # token, so Spaceship::ConnectAPI is ready to use as-is). Idempotent:
    # selecting the same build twice is a harmless PATCH.
    app = Spaceship::ConnectAPI::App.find(PROD_BUNDLE_ID)
    UI.user_error!("could not find app #{PROD_BUNDLE_ID} in App Store Connect") unless app

    version = app.get_edit_app_store_version(platform: Spaceship::ConnectAPI::Platform::IOS)
    UI.user_error!("no editable App Store version found for #{PROD_BUNDLE_ID}") unless version
    unless version.version_string == train_version
      UI.user_error!("editable App Store version is #{version.version_string}, expected #{train_version}")
    end

    build = Spaceship::ConnectAPI::Build.all(
      app_id: app.id,
      version: train_version,
      build_number: train_build_number,
      platform: Spaceship::ConnectAPI::Platform::IOS,
    ).first
    unless build
      UI.user_error!("build #{train_build_number} not found/processed for #{train_version}")
    end

    version.select_build(build_id: build.id)
    UI.success("Successfully attached build #{train_build_number} to App Store version #{train_version}")
  end

  # The provisioning profile name match installed for a bundle id, as published
  # in the sigh_<id>_appstore_profile-name environment variable. Falls back to
  # the conventional name if the variable is missing (e.g. a readonly run that
  # found the profile already installed).
  def match_profile_name(bundle_id)
    env_key = "sigh_#{bundle_id}_appstore_profile-name"
    name = ENV[env_key]
    if name.to_s.empty?
      UI.important("#{env_key} not set; falling back to \"match AppStore #{bundle_id}\"")
      return "match AppStore #{bundle_id}"
    end
    name
  end

  # Pin Manual AppStore signing on a target's Release configuration using the
  # exact profile name match resolved. Keeps the profile name out of the Xcode
  # project so a regenerated (possibly re-suffixed) profile never desyncs it.
  # Bundle id and team are left to the Prod xcconfig; only the profile name and
  # signing style need to be set here.
  def apply_prod_signing(target, profile_name)
    update_code_signing_settings(
      path: PROJECT,
      targets: [target],
      build_configurations: [PROD_CONFIG],
      use_automatic_signing: false,
      code_sign_identity: "Apple Distribution",
      profile_name: profile_name,
    )
  end

  # Release notes shown to internal testers in TestFlight. Includes commit
  # subject + short SHA + branch so a tester can map a build back to the
  # exact commit that produced it.
  def testflight_release_notes
    sha     = (ENV["GITHUB_SHA"] || `git rev-parse HEAD`.strip).slice(0, 7)
    subject = `git log -1 --pretty=%s`.strip
    branch  = ENV["GITHUB_REF_NAME"] || `git rev-parse --abbrev-ref HEAD`.strip
    "#{subject}\nBranch: #{branch}\nCommit: #{sha}"
  end
end
