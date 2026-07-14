{
  lib,
  ruby,
  bundlerApp,
  makeWrapper,
  lanes,
}:
bundlerApp {
  inherit ruby;
  pname = "fastlane";
  gemdir = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Gemfile
      ./Gemfile.lock
      ./gemset.nix
      ./Pluginfile
    ];
  };
  exes = [ "fastlane" ];
  nativeBuildInputs = [ makeWrapper ];
  # we accept CONVOS_LANES as environment variable arg to allow overriding
  postBuild = ''
    wrapProgram $out/bin/fastlane --set-default CONVOS_LANES ${lanes}
  '';
}
