{ pkgs }:
let
  caBundleWithBD = pkgs.runCommand "fetchproxies-ca-bundle" { } ''
    mkdir -p $out/etc/ssl/certs
    cat ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
        ${../brightdata-ca.crt} \
      > $out/etc/ssl/certs/ca-bundle.crt
    ln -s ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt
  '';

  pythonEnv = pkgs.python3.withPackages (ps: [ ps.websocket-client ]);

  chromiumFullpage = pkgs.writeShellApplication {
    name = "chromium-fullpage";
    runtimeInputs = [
      pythonEnv
      pkgs.chromium
    ];
    text = ''
      exec ${pythonEnv}/bin/python3 ${./chromium-fullpage.py} "$@"
    '';
  };
in
pkgs.dockerTools.streamLayeredImage {
  name = "fetchproxies-worker";
  tag = "latest";

  contents = with pkgs; [
    wget
    curl
    monolith
    yt-dlp
    chromium
    chromiumFullpage
    single-file-cli
    readability-cli
    proxychains-ng
    caBundleWithBD

    fontconfig
    dejavu_fonts
    liberation_ttf
    corefonts
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
    noto-fonts-emoji-blob-bin
    twemoji-color-font
    font-awesome
    inter
    roboto
    roboto-mono
    open-sans
    source-sans
    source-serif
    source-code-pro
    fira-code
    ibm-plex
    jetbrains-mono

    coreutils
    bash
  ];

  config = {
    Env = [
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "FONTCONFIG_PATH=${pkgs.fontconfig.out}/etc/fonts"
    ];
  };
}
