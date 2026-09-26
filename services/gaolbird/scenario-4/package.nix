{
  lib,
  buildGoModule,
}:

let
  # Manually bumped, deliberately not derived from a store hash: the operator
  # pastes `127.0.0.1:5000/gaolbird-4:<version>` into the CTFd challenge once, so
  # this tag must stay put across nixpkgs bumps and unrelated rebuilds. Bump it
  # only when the scenario's behaviour changes, and re-push the artifact.
  version = "0.1.0";
in
buildGoModule {
  pname = "gaolbird-4-scenario";
  inherit version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Pulumi.yaml
      ./go.mod
      ./go.sum
      ./main.go
    ];
  };

  vendorHash = "sha256-wGOHIlwKHwSDECDTqhubT11UGMJd82FVK2lAOJvSQkg=";

  subPackages = [ "." ];

  env.CGO_ENABLED = 0;

  postInstall = ''
    mv "$out/bin/gaolbird-4-scenario" "$out/main"
    rmdir "$out/bin"
    install -m444 "$src/Pulumi.yaml" "$out/Pulumi.yaml"
  '';

  passthru = { inherit version; };

  meta = {
    description = "Pulumi deployment scenario allocating one gaolbird-4 VM per chall-manager instance";
    platforms = lib.platforms.linux;
  };
}
