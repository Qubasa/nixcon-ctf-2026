{
  pkgs,

  src-rtunreal,
  challengeNixpkgs,

  port ? 3000,
  checkTimeout ? 600,
  totalTimeout ? 900,
  maxPatchBytes ? 512 * 1024,

  memorySize ? 6144,
  cores ? 4,
  diskSize ? 40960,

  hostPort ? 43002,

  extraModules ? [ ],
}:
let
  guest = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = null;
    inherit pkgs;
    modules = [
      (import ./guest.nix {
        inherit
          port
          src-rtunreal
          challengeNixpkgs
          checkTimeout
          totalTimeout
          maxPatchBytes
          ;
      })
      {
        virtualisation.vmVariantWithBootLoader.virtualisation = {
          graphics = false;
          restrictNetwork = true;
          forwardPorts = [
            {
              from = "host";
              host.address = "127.0.0.1";
              host.port = hostPort;
              guest.port = port;
            }
          ];
          inherit memorySize cores diskSize;
        };
      }
    ]
    ++ extraModules;
  };
in
guest.config.system.build.vmWithBootLoader
