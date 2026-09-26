{
  lib,
  buildGoModule,
}:

let
  # Bumped by hand: the operator pastes `127.0.0.1:5000/xin:<version>` into the
  # CTFd challenge once, so it must not move with unrelated rebuilds.
  version = "0.1.0";
in
buildGoModule {
  pname = "xin-scenario";
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

  # go.mod and go.sum are byte-identical copies of ../../homewort/scenario's.
  vendorHash = "sha256-wGOHIlwKHwSDECDTqhubT11UGMJd82FVK2lAOJvSQkg=";

  subPackages = [ "." ];

  env.CGO_ENABLED = 0;

  postInstall = ''
    mv "$out/bin/homewort-scenario" "$out/main"
    rmdir "$out/bin"
    install -m444 "$src/Pulumi.yaml" "$out/Pulumi.yaml"
  '';

  passthru = { inherit version; };

  meta = {
    description = "Pulumi deployment scenario allocating one xin VM per chall-manager instance";
    platforms = lib.platforms.linux;
  };
}
