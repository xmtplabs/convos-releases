_: {
  config.perSystem =
    { pkgs, ... }:
    let
      root = ./../..;
      gems = pkgs.bundlerEnv {
        name = "fastlane-gems";
        ruby = pkgs.ruby_3_4;
        gemfile = root + /Gemfile;
        lockfile = root + /Gemfile.lock;
        gemset = root + /nix/gemset.nix;
        extraConfigPaths = [ (root + /fastlane/Pluginfile) ];
      };
      # Interpolating the path copies fastlane/lanes into the nix store; the
      # wrapper pins CONVOS_LANES to that store path so consumers' stub
      # Fastfiles import lane code at the version their flake.lock pins.
      lanes = root + /fastlane/lanes;
    in
    {
      packages.fastlane = pkgs.writeShellScriptBin "fastlane" ''
        export CONVOS_LANES="''${CONVOS_LANES:-${lanes}}"
        exec ${gems}/bin/fastlane "$@"
      '';

      # Maintenance shell: bundix regenerates nix/gemset.nix after Gemfile
      # changes (run `bundle lock` first for Gemfile.lock).
      devShells.default = pkgs.mkShell {
        packages = [
          gems
          gems.wrappedRuby
          pkgs.bundix
        ];
      };
    };
}
