# Entry point for convos-ios. Imported by that repo's stub Fastfile:
#   import "#{ENV.fetch('CONVOS_LANES')}/ios.rb"
# Constants must be defined before the lane imports that reference them.

# Reusable constants
PROJECT          = "Convos.xcodeproj"

# PR (ad-hoc, Firebase) flavor
PR_SCHEME        = "Convos (PR Preview)"
PR_CONFIG        = "PR Preview"
PR_BUNDLE_ID     = "org.convos.ios-preview.pr"
PR_NSE_BUNDLE_ID = "org.convos.ios-preview.pr.ConvosNSE"

# Prod (App Store, TestFlight) flavor. Built on every push to `dev`; talks
# to the prod backend via config.prod.json. The Convos (Prod) scheme does not
# build the App Clip target, so only the app + NSE bundle IDs are signed.
PROD_SCHEME          = "Convos (Prod)"
PROD_CONFIG          = "Release"
PROD_BUNDLE_ID       = "org.convos.ios"
PROD_NSE_BUNDLE_ID   = "org.convos.ios.ConvosNSE"

MATCH_GIT_URL    = ENV["MATCH_GIT_URL"] || "git@github.com:xmtplabs/convos-certificates.git"
OUTPUT_DIR       = "build"
OUTPUT_NAME      = "Convos-PR.ipa"

# Resolve sibling lane files relative to this file so both consumer paths
# work: nix (imported from the CONVOS_LANES store path) and non-nix
# (fetched by import_from_git into fastlane's clone dir).
lanes_dir = File.dirname(__FILE__)
import "#{lanes_dir}/helpers.rb"
import "#{lanes_dir}/match.rb"
import "#{lanes_dir}/firebase.rb"
import "#{lanes_dir}/release.rb"
import "#{lanes_dir}/bootstrap.rb"
