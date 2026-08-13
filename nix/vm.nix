{
  config,
  pkgs,
  lib,
  ...
}:

{
  networking = {
    hostName = "fetchproxies";
    interfaces.eth0.useDHCP = true;

    nameservers = [ "127.0.0.1" ];
  };

  networking.firewall = {
    enable = true;

    allowedTCPPorts = [
      1314
      1315
      1323
      8080
    ];
  };

  networking.nftables.enable = true;

  environment.etc."nitter.conf".text = ''
    [Server]
    hostname = "localhost"
    address = "0.0.0.0"
    port = 1314

    [Config]
    hmacKey = "fetchproxies-nitter-key"

    [Preferences]
    theme = "Auto"

    [Proxy]
    type = "socks5"
    host = "127.0.0.1"
    port = 1081
  '';

  systemd.tmpfiles.rules = [
    "d /srv/kiwix 0755 root root -"
  ];

  virtualisation.podman = {
    enable = true;
    extraPackages = [ pkgs.gvisor ];
  };

  virtualisation.containers.ociRuntime = {
    runsc = {
      path = "${pkgs.gvisor}/bin/runsc";
    };
  };

  environment.systemPackages = [
    pkgs.gvisor
    pkgs.sqlite
  ];

  fileSystems."/srv/archive" = {
    device = "archive";
    fsType = "virtiofs";
  };

}
