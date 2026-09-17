{
  lib,
  craneLib,
  fetchurl,
  runCommand,
  ...
}:

let
  sourceSerif4 = fetchurl {
    urls = [
      "https://git.decent.foundation/api/packages/mirrors/generic/fontsource-variable-source-serif-4/5.3.0/source-serif-4-5.3.0.tgz"
      "https://registry.npmjs.org/@fontsource-variable/source-serif-4/-/source-serif-4-5.3.0.tgz"
    ];
    hash = "sha256-ShnTpv2hqXfxWg7h5g5fU98uaud/RvHtVMf8UtAV6Fo=";
  };

  htmx = fetchurl {
    url = "https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js";
    hash = "sha256-4gndpcgjVHnzFm3vx3UOHbzVpcGAi3eS/C5nM3aPtEc=";
  };

  commonArgs = {
    pname = "fetchproxies-dashboard";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ../dashboard;
      fileset = lib.fileset.unions [
        ../dashboard/Cargo.toml
        ../dashboard/Cargo.lock
        ../dashboard/src
        ../dashboard/templates
      ];
    };

    strictDeps = true;

    doCheck = false;
  };
  binary = craneLib.buildPackage (
    commonArgs
    // {
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;
    }
  );
in
runCommand "fetchproxies-dashboard-${commonArgs.version}"
  {
    inherit (commonArgs) version;
    passthru = { inherit binary; };
    meta = {
      description = "Fetchproxies dashboard (axum + htmx + askama, postgres backend)";
      mainProgram = "fetchproxies-dashboard";
    };
  }
  ''
    mkdir -p $out/share/fetchproxies-dashboard
    ln -s ${binary}/bin $out/bin
    cp -r ${../dashboard/static} $out/share/fetchproxies-dashboard/static
    chmod -R u+w $out/share/fetchproxies-dashboard/static
    cp ${htmx} $out/share/fetchproxies-dashboard/static/htmx.min.js
    mkdir -p fontsource $out/share/fetchproxies-dashboard/static/fonts
    tar -xzf ${sourceSerif4} -C fontsource
    for subset in latin latin-ext cyrillic cyrillic-ext greek vietnamese; do
      cp fontsource/package/files/source-serif-4-$subset-wght-normal.woff2 \
        $out/share/fetchproxies-dashboard/static/fonts/SourceSerif4-Roman-$subset.woff2
      cp fontsource/package/files/source-serif-4-$subset-wght-italic.woff2 \
        $out/share/fetchproxies-dashboard/static/fonts/SourceSerif4-Italic-$subset.woff2
    done
  ''
