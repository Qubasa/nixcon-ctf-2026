{
  lib,
  buildGoModule,
}:

let
  # pastes `127.0.0.1:5000/homewort:<version>` into the CTFd challenge once, so
  version = "0.1.0";
in
buildGoModule {
  pname = "homewort-scenario";
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
    mv "$out/bin/homewort-scenario" "$out/main"
    rmdir "$out/bin"
    install -m444 "$src/Pulumi.yaml" "$out/Pulumi.yaml"
  '';

  passthru = { inherit version; };

  meta = {
    description = "Pulumi deployment scenario allocating one homewort VM per chall-manager instance";
    platforms = lib.platforms.linux;
  };
}
