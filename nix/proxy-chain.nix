{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.fetchproxies.proxy-chain;

  wgBackends = lib.filterAttrs (_: b: b.type == "wireguard") cfg.backends;
  wgNames = lib.attrNames wgBackends;
  indexedWg = lib.imap0 (i: name: { inherit name i; }) wgNames;
  indexFor = name: (lib.findFirst (x: x.name == name) { i = 0; } indexedWg).i;

  wgTableBase = 100;
  wgRulePriorityBase = 1000;
  wgRelayPortBase = 10800;
in
{
  options.services.fetchproxies.proxy-chain = with lib; {
    enable = mkEnableOption "fetchproxies proxy chain";

    backends = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            type = mkOption {
              type = types.enum [
                "wireguard"
                "socks"
                "direct"
              ];
              description = "Backend type";
            };
            wireguardConfig = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to WireGuard config (for wireguard type)";
            };
            upstream = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Upstream SOCKS address host:port (for socks type)";
            };
            wireguardPeers = mkOption {
              type = types.listOf types.attrs;
              default = [ ];
              description = "WireGuard peer configurations (for wireguard type)";
            };
            localIPs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Local IPs for the WireGuard interface (for wireguard type)";
            };
          };
        }
      );
      default = { };
      description = "Named proxy backends";
    };

    chains = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            port = mkOption {
              type = types.port;
              description = "SOCKS5 listen port for this chain";
            };
            forwarderEnvFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Optional environment file with PROXY_CHAIN_FORWARDER; the configured backend list is used until it exists.";
            };
            backends = mkOption {
              type = types.listOf types.str;
              description = ''
                Ordered list of candidate backend names. gost tries them
                in sequence per connection (strategy=fifo). A backend that
                fails (TCP refused / closed early) is skipped for
                `failTimeoutSec` seconds before being tried again.
              '';
            };
            maxFails = mkOption {
              type = types.int;
              default = 1;
              description = ''
                Consecutive failures that mark a backend dead. gost v3
                default is 1; set higher to tolerate transient flakes.
              '';
            };
            failTimeoutSec = mkOption {
              type = types.int;
              default = 30;
              description = "Seconds a failed backend stays out of rotation.";
            };
            retries = mkOption {
              type = types.int;
              default = 5;
              description = ''
                Within-request retry count. gost v3 REQUIRES this on the
                listener (`-L socks5://...?retries=N`), not the forwarder --
                without it a failed dial to the first node returns error
                to the client instead of falling through to the next.
                Default 5 covers rotating through a dead-then-live
                sequence across the whole backend list.
              '';
            };
          };
        }
      );
      default = { };
      description = "Per-service proxy chains";
    };

    enableTor = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run a local Tor daemon with a SOCKS port on 127.0.0.1:9050.
        Set to false if none of your chains use a `tor` backend -- the
        egress rule allowing Tor-owned sockets remains harmless either
        way (matches on uid 35, which only exists while Tor is running).
      '';
    };

    allowedDnsResolvers = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.1" ];
      description = ''
        IPv4 addresses allowed for outbound DNS (UDP/TCP port 53) in the
        egress kill-switch.  Defaults to loopback only -- add the guest's
        upstream resolver here if you point `networking.nameservers` at
        something off-box (e.g. SLIRP's built-in forwarder at 10.0.2.3).
      '';
    };

    allowedHostSocks = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            ip = mkOption {
              type = types.str;
              description = "IPv4 address of the upstream SOCKS server (typically 10.0.2.2 -- the SLIRP gateway).";
            };
            port = mkOption {
              type = types.port;
              description = "TCP port of the upstream SOCKS server on the host.";
            };
          };
        }
      );
      default = [ ];
      description = ''
        Extra host:port pairs the egress kill-switch should allow the
        guest to reach over TCP. Intended for host-side SOCKS relays the
        guest chains through (e.g. a gost forwarder on the deployment host
        that tunnels to a tailscale exit node). Keep the list narrow --
        each entry is an arbitrary-target egress widening.
      '';
    };

    allowedDirectUids = mkOption {
      type = types.listOf types.int;
      default = [ ];
      description = ''
        Numeric uids whose outbound packets bypass the wg-only egress
        kill-switch. Use this to authorise specific services to fall
        through to the VM's NAT gateway when the dashboard switches
        their egress mode from `proxy_chain` to `direct` (e.g.
        invidious-companion uid 880 once a Google OAuth refresh token
        is in place -- the source IP no longer matters and chaining
        through Mullvad becomes pure overhead). Without an entry here
        the packets get logged + dropped by the kill-switch and the
        service hangs in connect().

        The exemption is unconditional -- once a uid is listed, the
        service CAN leak directly regardless of what the dashboard
        currently has it set to. Whether that path actually carries
        traffic is gated by the supervisor-managed env file (PROXY=
        empty -> direct, otherwise -> chain). Listing a uid here is the
        capability; the dashboard chooses when to use it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    networking.wireguard.interfaces = lib.mapAttrs' (
      name: backend:
      lib.nameValuePair "wg-${name}" {
        privateKeyFile = backend.wireguardConfig;
        ips = backend.localIPs;
        table = toString (wgTableBase + indexFor name);
        fwmark = toString (wgTableBase + indexFor name);
        peers = backend.wireguardPeers;
        postSetup = ''
          ${pkgs.iproute2}/bin/ip route add default dev wg-${name} table ${
            toString (wgTableBase + indexFor name)
          }
        '';
      }
    ) wgBackends;

    networking.localCommands = lib.mkAfter (
      lib.concatMapStrings (entry: ''
        ${pkgs.iproute2}/bin/ip rule add fwmark ${toString (wgTableBase + entry.i)} table ${
          toString (wgTableBase + entry.i)
        } priority ${toString (wgRulePriorityBase + entry.i)} 2>/dev/null || true
      '') indexedWg
    );

    services.tor = lib.mkIf cfg.enableTor {
      enable = true;
      client.enable = true;
      settings = {
        SOCKSPort = [
          {
            addr = "127.0.0.1";
            port = 9050;
          }
        ];
        DataDirectory = "/var/lib/tor";
      };
    };

    networking.nftables.ruleset = lib.mkAfter ''
      table inet fetchproxies-egress {
        chain output {
          type filter hook output priority 0; policy drop;

          oifname "lo" accept
          ct state established,related accept

          udp dport 51820 accept

          tcp dport 9222 accept

          tcp dport 44445 accept

          meta skuid ${toString config.ids.uids.tor} accept

          ${lib.concatMapStringsSep "\n          " (
            uid: "meta skuid ${toString uid} accept"
          ) cfg.allowedDirectUids}

          oifname "wg-*" accept

          ${lib.concatMapStringsSep "\n          " (
            ip: "meta l4proto { tcp, udp } th dport 53 ip daddr ${ip} accept"
          ) cfg.allowedDnsResolvers}

          ${lib.concatMapStringsSep "\n          " (
            e: "ip daddr ${e.ip} tcp dport ${toString e.port} accept"
          ) cfg.allowedHostSocks}

          log prefix "fetchproxies-egress-drop: " drop
        }
      }
    '';

    systemd.services =
      let
        wgRelayServices = lib.listToAttrs (
          map (
            entry:
            let
              relayPort = wgRelayPortBase + entry.i;
            in
            lib.nameValuePair "proxy-wg-relay-${entry.name}" {
              description = "SOCKS5 relay for WireGuard backend ${entry.name}";
              after = [ "wireguard-wg-${entry.name}.service" ];
              requires = [ "wireguard-wg-${entry.name}.service" ];
              wantedBy = [ "proxy-chain.service" ];
              serviceConfig = {
                ExecStart = "${pkgs.gost}/bin/gost -L 'socks5://127.0.0.1:${toString relayPort}?interface=wg-${entry.name}'";
                DynamicUser = true;
                Restart = "always";
                RestartSec = 3;
              };
            }
          ) indexedWg
        );

        wgRelayDeps = map (entry: "proxy-wg-relay-${entry.name}.service") indexedWg;

        backendHostPort =
          name:
          let
            backend = cfg.backends.${name};
          in
          if backend.type == "wireguard" then
            "127.0.0.1:${toString (wgRelayPortBase + indexFor name)}"
          else if backend.type == "socks" then
            backend.upstream
          else
            throw "proxy-chain: direct backend '${name}' can't be used as a chain forwarder";

        chainForwarder =
          chain:
          let
            nodes = lib.concatMapStringsSep "," backendHostPort chain.backends;
            query = "strategy=fifo&maxFails=${toString chain.maxFails}&failTimeout=${toString chain.failTimeoutSec}s";
          in
          "socks5://${nodes}?${query}";

        chainServices = lib.mapAttrs' (
          chainName: chain:
          lib.nameValuePair "proxy-chain-${chainName}" {
            description = "Fetchproxies SOCKS5 chain '${chainName}'";
            after = [
              "network-online.target"
              "tor.service"
              "proxy-chain.service"
            ]
            ++ wgRelayDeps;
            wants = [
              "network-online.target"
              "tor.service"
            ]
            ++ wgRelayDeps;
            wantedBy = [ "proxy-chain.service" ];
            partOf = [ "proxy-chain.service" ];
            serviceConfig = {
              EnvironmentFile = lib.optional (chain.forwarderEnvFile != null) "-${chain.forwarderEnvFile}";
              ExecStart =
                if chain.forwarderEnvFile == null then
                  ''${pkgs.gost}/bin/gost -D -L "socks5://:${toString chain.port}?retries=${toString chain.retries}" -F "${chainForwarder chain}"''
                else
                  "${pkgs.writeShellScript "proxy-chain-${chainName}-start" ''
                    exec ${pkgs.gost}/bin/gost -D -L "socks5://:${toString chain.port}?retries=${toString chain.retries}" -F "''${PROXY_CHAIN_FORWARDER:-${chainForwarder chain}}"
                  ''}";
              DynamicUser = true;
              Restart = "always";
              RestartSec = 5;
            };
          }
        ) cfg.chains;

      in
      wgRelayServices
      // chainServices
      // {
        proxy-chain = {
          description = "Fetchproxies SOCKS5 proxy chains (umbrella)";
          after = [
            "network-online.target"
            "tor.service"
          ]
          ++ wgRelayDeps;
          wants = [
            "network-online.target"
            "tor.service"
          ]
          ++ wgRelayDeps;
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            RuntimeDirectory = "proxy-chain";
            ExecStart = pkgs.writeShellScript "proxy-chain-umbrella" ''
              ${pkgs.coreutils}/bin/printf '{}' > /run/proxy-chain/health.json
            '';
          };
        };
      };
  };
}
