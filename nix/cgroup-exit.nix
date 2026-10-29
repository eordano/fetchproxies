{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fetchproxies.cgroup-exit;
  slots = config.services.wireguardExits.slots;

  bpftool = "${pkgs.bpftools}/bin/bpftool";

  sockMarkProg =
    fwmark:
    pkgs.runCommand "cgroup-exit-sock-mark-${toString fwmark}.o" { } ''
      cat > mark.c <<EOC
      #include <linux/bpf.h>
      __attribute__((section("cgroup/sock"), used))
      int set_mark(struct bpf_sock *sk) { sk->mark = ${toString fwmark}; return 1; }
      __attribute__((section("license"), used)) char _license[] = "GPL";
      EOC
      ${pkgs.llvmPackages.clang-unwrapped}/bin/clang -O2 -target bpf -nostdinc \
        -I${pkgs.linuxHeaders}/include -c mark.c -o $out
    '';

  mkUnit =
    unit: u:
    let
      slot = slots.${u.backend};
      cgroup = "/sys/fs/cgroup/system.slice/${unit}.service";
      pin = "/sys/fs/bpf/cgroup-exit-${unit}";
      attach = pkgs.writeShellScript "cgroup-exit-attach-${unit}" ''
        set -eu
        ${bpftool} cgroup detach ${cgroup} cgroup_inet_sock_create pinned ${pin} 2>/dev/null || true
        rm -f ${pin}
        ${bpftool} prog load ${sockMarkProg slot.fwmark} ${pin} type cgroup/sock
        ${bpftool} cgroup attach ${cgroup} cgroup_inet_sock_create pinned ${pin}
      '';
      detach = pkgs.writeShellScript "cgroup-exit-detach-${unit}" ''
        ${bpftool} cgroup detach ${cgroup} cgroup_inet_sock_create pinned ${pin} 2>/dev/null || true
        rm -f ${pin}
      '';
    in
    {
      after = [
        "${slot.setupUnit}.service"
        "fetchproxies-cgroup-exit-rules.service"
      ];
      requires = lib.optional u.bindToBackend "${slot.setupUnit}.service" ++ [
        "fetchproxies-cgroup-exit-rules.service"
      ];
      wants = lib.optional (!u.bindToBackend) "${slot.setupUnit}.service";
      serviceConfig = {
        ExecStartPre = lib.mkAfter [ "+${attach}" ];
        ExecStopPost = [ "+${detach}" ];
      };
    };
in
{
  options.services.fetchproxies.cgroup-exit = with lib; {
    units = mkOption {
      default = { };
      description = ''
        systemd service names (without `.service`) whose whole cgroup is pinned
        to one Mullvad location: a cgroup/sock BPF program sets the socket mark
        on every socket created by any process in the unit, so the route and
        source address are the tunnel's from connect() on. This is what makes
        a gVisor container follow the tunnel -- its sentry opens the host
        sockets as root, so uid-based marks never match.
      '';
      type = types.attrsOf (
        types.submodule {
          options.backend = mkOption {
            type = types.str;
            description = "Mullvad location name (a key in `services.fetchproxies.mullvad.locations`).";
          };
          options.bindToBackend = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether the unit Requires= the location's setup unit, and so is
              stopped and restarted with it. Turn it off for a server whose
              inbound service must outlive a dead tunnel: the unit then only
              Wants= the setup unit (still ordered after it), keeps its socket
              mark across the watchdog's re-rolls, and the egress guard is
              what keeps its traffic off the slirp uplink while the tunnel is
              down.
            '';
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.units != { }) {
    assertions = lib.mapAttrsToList (unit: u: {
      assertion = slots ? ${u.backend};
      message = "services.fetchproxies.cgroup-exit.units.${unit}.backend '${u.backend}' is not a key in services.fetchproxies.mullvad.locations.";
    }) cfg.units;

    systemd.network.config.networkConfig.ManageForeignRoutingPolicyRules = false;

    systemd.services = lib.mapAttrs mkUnit cfg.units // {
      fetchproxies-cgroup-exit-rules = {
        description = "Keep marked traffic to the slirp network on the main table";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
        ]
        ++ map (u: "${slots.${u.backend}.setupUnit}.service") (lib.attrValues cfg.units);
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ pkgs.iproute2 ];
        script = ''
          set -eu
          while ip -4 rule del priority 1400 2>/dev/null; do :; done
          ip -4 rule add to 10.0.2.0/24 lookup main priority 1400
        '';
      };
    };
  };
}
