{
  lib,
  ruby,
  stdenv,
  bundlerEnv,
  makeWrapper,
  git,
}:
let
  gems = bundlerEnv {
    name = "train-gems";
    inherit ruby;
    gemdir = ./.;
  };
in
stdenv.mkDerivation {
  inherit ruby;
  name = "train";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./bin
      ./lib
      ./test
    ];
  };
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    ${gems.wrappedRuby}/bin/ruby -Ilib -Itest test/run_all.rb
    runHook postCheck
  '';

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [
    gems
    ruby
    git
  ];
  installPhase = ''
    mkdir -p $out/share/train
    cp -r bin lib $out/share/train/
  '';

  postBuild = ''
    makeWrapper ${gems.wrappedRuby}/bin/ruby $out/bin/train \
     --add-flags "-I$out/share/train/lib" \
     --add-flags "$out/share/train/bin/train" \
     --prefix PATH : ${lib.makeBinPath [ git ]}
  '';
}
