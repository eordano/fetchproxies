{
  rustPlatform,
  pkg-config,
  openssl,
  fetchurl,
  ...
}:

let
  htmx = fetchurl {
    url = "https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js";
    hash = "sha256-4gndpcgjVHnzFm3vx3UOHbzVpcGAi3eS/C5nM3aPtEc=";
  };
in

rustPlatform.buildRustPackage {
  pname = "fetchproxies-dashboard";
  version = "0.1.0";

  src = ../dashboard;
  cargoLock.lockFile = ../dashboard/Cargo.lock;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  doCheck = false;

  postInstall = ''
    mkdir -p $out/share/fetchproxies-dashboard
    cp -r static $out/share/fetchproxies-dashboard/static
    cp ${htmx} $out/share/fetchproxies-dashboard/static/htmx.min.js
  '';

  meta = {
    description = "Fetchproxies dashboard (axum + htmx + askama, postgres backend)";
    mainProgram = "fetchproxies-dashboard";
  };
}
