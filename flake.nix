{
  description = "nixek-ci: Nix-native CI framework";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in
  {
    # The nixek-ci-agent binary
    packages.${system}.nixekcid = pkgs.rustPlatform.buildRustPackage {
      pname = "nixek-ci-agent";
      version = "0.1.0";
      src = ../nixekd;
      cargoLock.lockFile = ../nixekd/Cargo.lock;
    };

    packages.${system}.default = self.packages.${system}.nixekcid;

    # Library for defining CI jobs
    lib = {
      # mkJob: create a CI job with a NixOS machine and steps
      # Usage: mkJob { inherit nixpkgs pkgs nixekcid; } { machine = { ... }; steps = [ ... ]; }
      mkMachine = { nixpkgs, pkgs, nixekcid, extraModules ? [] }: let
        lib = pkgs.lib;
        evalConfig = import "${nixpkgs}/nixos/lib/eval-config.nix";

        baseModule = { config, ... }: {
          # nixek-ci agent baked in
          environment.systemPackages = [ nixekcid ];

          # Mark this as a CI VM
          system.activationScripts.nixek-ci-marker = "mkdir -p /run && touch /run/nixek-ci-vm";

          # Mount 9p config share if available
          fileSystems."/mnt/nixek-config" = {
            device = "nixek-config";
            fsType = "9p";
            options = [ "trans=virtio" "version=9p2000.L" "nofail" "x-systemd.device-timeout=5s" ];
          };

          systemd.services.nixek-ci-agent = {
            description = "nixek-ci agent — run job steps";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" "mnt-nixek\\x2dconfig.mount" ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${nixekcid}/bin/nixek-ci-agent run-job";
              StandardOutput = "journal+console";
              StandardError = "journal+console";
            };
          };

          # Auto-poweroff after agent finishes (success or failure)
          systemd.services.nixek-ci-poweroff = {
            description = "Power off after CI job";
            wantedBy = [ "multi-user.target" ];
            after = [ "nixek-ci-agent.service" ];
            requires = [ "nixek-ci-agent.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.systemd}/bin/systemctl poweroff";
            };
          };
        };
      in {
        # Build a QEMU qcow2 image
        qemu = import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
          inherit pkgs lib;
          diskSize = 8 * 1024;
          format = "qcow2";
          copyChannel = false;
          config = (evalConfig {
            system = "x86_64-linux";
            modules = [
              ({
                imports = [ "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix" ];
                fileSystems."/" = {
                  device = "/dev/disk/by-label/nixos";
                  fsType = "ext4";
                  autoResize = true;
                };
                boot.growPartition = true;
                boot.kernelParams = [ "console=ttyS0" ];
                boot.loader.grub.device = "/dev/vda";
                boot.loader.timeout = 0;
                services.getty.autologinUser = "root";
                networking.firewall.enable = false;
              })
              baseModule
            ] ++ extraModules;
          }).config;
        };

        # Build an AWS AMI
        aws = ((import "${nixpkgs}/nixos/release.nix") {
          configuration = { config, ... }: {
            amazonImage = {
              format = "raw";
              sizeMB = 8 * 1024;
            };
            imports = [ baseModule ] ++ extraModules;
          };
        }).amazonImage.x86_64-linux;
      };
    };
  };
}
