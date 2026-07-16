_: {
  config.perSystem =
    {
      pkgs,
      config,
      ...
    }:
    let
      root = ./../..;
      lanes = root + /fastlane/lanes;
    in
    {
      packages.fastlane = pkgs.callPackage (root + /fastlane) { inherit lanes; };
      packages.train = pkgs.callPackage (root + /train) { };

      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.bundix
          config.packages.train
          config.packages.fastlane
          pkgs.wrangler
        ];
      };
    };
}
