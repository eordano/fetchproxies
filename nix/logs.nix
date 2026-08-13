{ colmenaBasePath, ... }:
{
  imports = [
    (colmenaBasePath + "/modules/behaviors/logs-forward.nix")
    (colmenaBasePath + "/modules/services/geoip-databases.nix")
  ];

  behaviors.logs = {
    useVector = true;
    upstream = "10.0.2.2";
    journaldMaxUse = "50M";
    journaldMaxRetentionSec = 24 * 3600;
    vectorBufferType = "memory";
  };
}
