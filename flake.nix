{
  description = "nixek-ci: Nix-native CI framework";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixekd-src = {
      url = "path:/home/claw/nixekd";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixekd-src }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in
  {
    packages.${system} = let
      nixekcid = pkgs.rustPlatform.buildRustPackage {
        pname = "nixek-ci-agent";
        version = "0.1.0";
        src = nixekd-src;
        cargoLock.lockFile = "${nixekd-src}/Cargo.lock";
      };
    in {
      inherit nixekcid;
      default = nixekcid;
    };

    # Library for defining CI jobs
    lib = {
      # mkMachine: create machine images (qemu/aws) with nixek-ci-agent baked in
      mkMachine = { nixpkgs, pkgs, nixekcid, extraModules ? [] }: let
        lib = pkgs.lib;
        evalConfig = import "${nixpkgs}/nixos/lib/eval-config.nix";

        baseModule = { config, ... }: {
          environment.systemPackages = [ nixekcid pkgs.curl ];

          # Mark this as a CI VM for auto-poweroff
          system.activationScripts.nixek-ci-marker = "mkdir -p /run && touch /run/nixek-ci-vm";

          # Mount 9p config share if available (QEMU local testing)
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
              ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
              ExecStart = "${nixekcid}/bin/nixek-ci-agent run-job";
              StandardOutput = "journal+console";
              StandardError = "journal+console";
              Restart = "on-failure";
              RestartSec = "5";
            };
          };
        };
      in {
        # Build an AWS AMI (raw format for nixos-ami-upload / S3 import)
        aws = ((import "${nixpkgs}/nixos/release.nix") {
          configuration = { config, ... }: {
            amazonImage = {
              format = "raw";
              sizeMB = 16 * 1024;
            };
            imports = [ baseModule ] ++ extraModules;
          };
        }).amazonImage.x86_64-linux;

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
      };
    };
  };
}
