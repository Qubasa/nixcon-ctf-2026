{
  inputs.clan-core.url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
  inputs.nixpkgs.follows = "clan-core/nixpkgs";

  # nixbot — standalone Nix CI (buildbot-nix's successor) for the nixbot
  # service. Provides nixosModules.nixbot; integrates with the clan's Gitea
  # via webhooks and commit statuses.
  inputs.nixbot.url = "github:Mic92/nixbot";
  inputs.nixbot.inputs.nixpkgs.follows = "nixpkgs";

  # The homewort CTF challenge (nixosConfigurations.mus). Hosted by the
  # `homewort` service; pins its own nixpkgs/home-manager on purpose, so it
  # deliberately does not follow this flake's nixpkgs.
  inputs.homewort.url = "git+ssh://gitea@git.immutable-byte.de/nixcon-ctf/homewort.git";

  # The CTFd plugin that proxies a challenge to chall-manager. Consumed as a
  # plain source tree: CTFd imports it from a bind mount, there is nothing to
  # build.
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
      };

      # `nixbot` builds these on every push.
      checks.x86_64-linux = {
        homewort-allocator = import ./services/homewort/allocator-test.nix {
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
