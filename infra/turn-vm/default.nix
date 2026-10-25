# Local research VM; no host networking or libvirt configuration is modified.
{ nixpkgs, hostIP }:
let
  system = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
      ({ lib, pkgs, ... }: {
        networking.hostName = "turn-spike";
        system.stateVersion = "26.05";
        virtualisation = {
          cores = 2;
          memorySize = 2048;
          diskSize = 12288;
          graphics = false;
          qemu.options = [
            "-virtfs local,path=\"$TURN_VM_RUNTIME\",mount_tag=turn-runtime,security_model=none,readonly=on"
            "-qmp unix:\"$TURN_VM_QMP\",server=on,wait=off"
          ];
          forwardPorts = [
            { host.address = "127.0.0.1"; host.port = 2223; guest.port = 22; }
            { host.address = hostIP; host.port = 3478; guest.port = 3478; proto = "udp"; }
            { host.address = hostIP; host.port = 3478; guest.port = 3478; }
            { host.address = hostIP; host.port = 5349; guest.port = 5349; }
          ] ++ map (port: {
            host.address = hostIP; host.port = port; guest.port = port; proto = "udp";
          }) (lib.range 49160 49259);
        };
        virtualisation.fileSystems."/run/turn-runtime" = {
          device = "turn-runtime";
          fsType = "9p";
          options = [ "trans=virtio" "version=9p2000.L" "ro" ];
        };
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
            PermitRootLogin = "prohibit-password";
          };
          authorizedKeysFiles = [ "/run/turn-admin.pub" ];
        };
        systemd.services.sshd = {
          requires = [ "run-turn\\x2druntime.mount" ];
          after = [ "run-turn\\x2druntime.mount" ];
          preStart = "${pkgs.coreutils}/bin/install -m 600 /run/turn-runtime/admin.pub /run/turn-admin.pub";
        };
        # The shared directory contains only this VM's credentials, never the CA key.
        systemd.services.coturn = {
          requires = [ "run-turn\\x2druntime.mount" ];
          after = [ "run-turn\\x2druntime.mount" ];
          serviceConfig.LoadCredential = [
            "secret:/run/turn-runtime/secret"
            "cert:/run/turn-runtime/server.crt"
            "key:/run/turn-runtime/server.key"
          ];
        };
        services.coturn = {
          enable = true;
          listening-ips = [ "10.0.2.15" ];
          relay-ips = [ "10.0.2.15" ];
          min-port = 49160;
          max-port = 49259;
          use-auth-secret = true;
          static-auth-secret-file = "/run/credentials/coturn.service/secret";
          realm = "turn-spike.local";
          cert = "/run/credentials/coturn.service/cert";
          pkey = "/run/credentials/coturn.service/key";
          no-dtls = true;
          no-cli = true;
          no-tcp-relay = true;
          extraConfig = ''
            external-ip=${hostIP}/10.0.2.15
            fingerprint
            no-multicast-peers
            no-tlsv1
            no-tlsv1_1
            total-quota=80
            user-quota=16
            log-file=stdout
            simple-log
          '';
        };
        networking.firewall = {
          allowedTCPPorts = [ 22 3478 5349 ];
          allowedUDPPorts = [ 3478 ];
          allowedUDPPortRanges = [ { from = 49160; to = 49259; } ];
        };
        environment.systemPackages = [ pkgs.coturn ];
      })
    ];
  };
in system.config.system.build.vm
