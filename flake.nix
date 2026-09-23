{
  inputs.clan-core.url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
  inputs.nixpkgs.follows = "clan-core/nixpkgs";

  # nixbot is the standalone Nix CI (buildbot-nix's successor) behind the
  # nixbot service. It provides nixosModules.nixbot and integrates with the
  # clan's Gitea through webhooks and commit statuses.
  inputs.nixbot.url = "github:Mic92/nixbot";
  inputs.nixbot.inputs.nixpkgs.follows = "nixpkgs";

  # The `homewort` service hosts this CTF challenge (nixosConfigurations.mus).
  # It pins its own nixpkgs/home-manager on purpose, so it does not follow
  # this flake's nixpkgs.
  inputs.homewort.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/homewort.git";

  # The homewort-v2 CTF challenge (nixosConfigurations.mus / mus-vm) pins its
  # inputs the same way. It also pins a patched home-manager fork the
  # challenge cannot work without.
  inputs.homewort-v2.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/homewort-v2.git";

  # The `baas` challenge is a plain source tree, not a flake: the service
  # builds the Express app from it and the repo has no flake.nix of its own.
  inputs.baas.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/baas.git";
  inputs.baas.flake = false;

  # The `rtunreal` challenge ("Pimp my PHP") is a source tree, not a flake
  # input that gets evaluated: the service grades submissions against the
  # tree as published and hands players the same bytes as a tarball.
  inputs.rtunreal.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/rtunreal-challenge.git";
  inputs.rtunreal.flake = false;

  # This is the nixpkgs that the rtunreal challenge's own flake.lock pins,
  # fetched by the URL the lock resolved to. The grading guest has no egress,
  # so it ships this tree and overrides the challenge's input with it.
  # `services/rtunreal/guest.nix` throws if the two ever drift apart.
  inputs.rtunreal-nixpkgs.url = "https://releases.nixos.org/nixpkgs/nixpkgs-26.11pre1073483.c7def046b9a8/nixexprs.tar.zst";

  # The CTFd plugin that proxies a challenge to chall-manager is consumed as a
  # plain source tree: CTFd imports it from a bind mount, so nothing needs
  # building.
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

      # Usage see: https://clan.lol/docs
      clan = clan-core.lib.clan {
        inherit self;
        imports = [ (import ./clan.nix { inherit inputs; }) ];
        specialArgs = { inherit inputs; };

        # Customize nixpkgs
        # pkgsForSystem =
        #   system:
        #   import nixpkgs {
        #     inherit system;
        #     config = {
        #       allowUnfree = true;
        #     };
        #     overlays = [];
        #   };
      };
    in
    {
      inherit (clan.config) nixosConfigurations nixosModules clanInternals;
      clan = clan.config;

      packages.x86_64-linux = {
        chall-manager = pkgs.callPackage ./pkgs/chall-manager.nix { };
        homewort-scenario = pkgs.callPackage ./services/homewort/scenario/package.nix { };
        homewort-v2-scenario = pkgs.callPackage ./services/homewort-v2/scenario/package.nix { };
        baas = pkgs.callPackage ./services/baas/package.nix { src-baas = inputs.baas; };

        # The grading guest, bootable on its own: `nix run .#rtunreal-vm`
        # brings up the check runner on 127.0.0.1:43002 with no deploy and no
        # flag anywhere near it.
        rtunreal-vm = import ./services/rtunreal/vm.nix {
          inherit pkgs;
          src-rtunreal = inputs.rtunreal;
          challengeNixpkgs = inputs.rtunreal-nixpkgs;
        };
      };

      # `nixbot` builds these on every push.
      checks.x86_64-linux = {
        homewort-allocator = import ./services/homewort/allocator-test.nix {
          inherit pkgs;
          inherit (pkgs) lib;
        };
        homewort-v2-allocator = import ./services/homewort-v2/allocator-test.nix {
          inherit pkgs;
          inherit (pkgs) lib;
        };
      };
      # Add the Clan cli tool to the dev shell.
      # Use "nix develop" to enter the dev shell.
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
