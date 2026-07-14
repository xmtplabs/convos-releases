_: {
  config.perSystem =
    { pkgs, lib, config, ... }:
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
      # Just bin/ + lib/ — the train CLI's sources — rather than the whole
      # repo (root + /.), so unrelated changes elsewhere don't bust its
      # store path / rebuild it.
      trainSrc = lib.fileset.toSource {
        inherit root;
        fileset = lib.fileset.unions [
          (root + /bin)
          (root + /lib)
        ];
      };
    in
    {
      packages.fastlane = pkgs.writeShellScriptBin "fastlane" ''
        export CONVOS_LANES="''${CONVOS_LANES:-${lanes}}"
        exec ${gems}/bin/fastlane "$@"
      '';

      # Release-train CLI. TRAIN_ROOT pins the ruby sources into the store so
      # `train` works from any cwd (workflows run it on caller checkouts).
      packages.train = pkgs.writeShellScriptBin "train" ''
        export TRAIN_ROOT="''${TRAIN_ROOT:-${trainSrc}}"
        exec ${gems.wrappedRuby}/bin/ruby -I "$TRAIN_ROOT/lib" "$TRAIN_ROOT/bin/train" "$@"
      '';

      # Maintenance shell: bundix regenerates nix/gemset.nix after Gemfile
      # changes (run `bundle lock` first for Gemfile.lock).
      devShells.default = pkgs.mkShell {
        packages = [
          gems
          gems.wrappedRuby
          pkgs.bundix
          config.packages.train
        ];
      };
    };
}
