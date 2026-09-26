{
  inputs.clan-core.url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
  inputs.nixpkgs.follows = "clan-core/nixpkgs";

  inputs.nixbot.url = "github:Mic92/nixbot";
  inputs.nixbot.inputs.nixpkgs.follows = "nixpkgs";

  inputs.homewort.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/homewort.git";

  inputs.homewort-v2.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/homewort-v2.git";

  inputs.gaolbird.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/gaolbird.git";

  inputs.xin.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/xin.git";

  inputs.baas.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/baas.git";
  inputs.baas.flake = false;

  inputs.rtunreal.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/rtunreal-challenge.git";
  inputs.rtunreal.flake = false;

  inputs.rtunreal-nixpkgs.url = "https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1073483.c7def046b9a8/nixexprs.tar.zst";

  inputs.ctfd-chall-manager.url = "github:ctfer-io/ctfd-chall-manager/v0.10.1";
  inputs.ctfd-chall-manager.flake = false;

  outputs =
    {
      self,
      clan-core,
      nixpkgs,
      ...
    }@inputs:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      clan = clan-core.lib.clan {
        inherit self;
        imports = [ (import ./clan.nix { inherit inputs; }) ];
        specialArgs = { inherit inputs; };

      };
    in
    {
      inherit (clan.config) nixosConfigurations nixosModules clanInternals;
      clan = clan.config;

      packages.x86_64-linux = {
        chall-manager = pkgs.callPackage ./pkgs/chall-manager.nix { };
        homewort-scenario = pkgs.callPackage ./services/homewort/scenario/package.nix { };
        homewort-v2-scenario = pkgs.callPackage ./services/homewort-v2/scenario/package.nix { };
        gaolbird-1-scenario = pkgs.callPackage ./services/gaolbird/scenario-1/package.nix { };
        gaolbird-2-scenario = pkgs.callPackage ./services/gaolbird/scenario-2/package.nix { };
        gaolbird-3-scenario = pkgs.callPackage ./services/gaolbird/scenario-3/package.nix { };
        gaolbird-4-scenario = pkgs.callPackage ./services/gaolbird/scenario-4/package.nix { };
        xin-scenario = pkgs.callPackage ./services/xin/scenario/package.nix { };
        baas = pkgs.callPackage ./services/baas/package.nix { src-baas = inputs.baas; };

        rtunreal-vm = import ./services/rtunreal/vm.nix {
          inherit pkgs;
          src-rtunreal = inputs.rtunreal;
          challengeNixpkgs = inputs.rtunreal-nixpkgs;
        };
      };

      checks.x86_64-linux = {
        homewort-allocator = import ./services/homewort/allocator-test.nix {
          inherit pkgs;
          inherit (pkgs) lib;
        };
        homewort-v2-allocator = import ./services/homewort-v2/allocator-test.nix {
          inherit pkgs;
          inherit (pkgs) lib;
        };
        gaolbird-allocator = import ./services/gaolbird/allocator-test.nix {
          inherit pkgs;
          inherit (pkgs) lib;
        };
        xin-allocator = import ./services/xin/allocator-test.nix {
          inherit pkgs;
          inherit (pkgs) lib;
        };
      };
      devShells =
        nixpkgs.lib.genAttrs
          [
            "x86_64-linux"
            "aarch64-linux"
            "aarch64-darwin"
          ]
          (system: {
            default = clan-core.inputs.nixpkgs.legacyPackages.${system}.mkShell {
              packages = [ clan-core.packages.${system}.clan-cli ];
            };
          });
    };
}
