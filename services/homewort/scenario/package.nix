{
  lib,
  buildGoModule,
}:

let
  # Manually bumped, deliberately not derived from a store hash: the operator
  # pastes `127.0.0.1:5000/homewort:<version>` into the CTFd challenge once, so
  # this tag must stay put across nixpkgs bumps and unrelated rebuilds. Bump it
  # only when the scenario's behaviour changes, and re-push the artifact.
  version = "0.1.0";
in
buildGoModule {
  pname = "homewort-scenario";
  inherit version;

  # Only the scenario itself goes in. A wider fileset would drag unrelated
  # homewort files into the OCI artifact, which is pushed layer-per-file.
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

  # The binary leaves the Nix store: it travels through an OCI registry into
  # chall-manager's cache directory and is executed from there, so it must not
  # depend on anything outside itself.
  env.CGO_ENABLED = 0;

  # chall-manager's OCI loader pulls the artifact with an oras-go file store,
  # which writes each layer at <cache>/<layer title>, and then stats
  # <cache>/Pulumi.yaml and <cache>/main (pkg/services/oci/load.go, v0.6.6).
  # Layer titles are paths relative to this directory (pkg/scenario/encode.go),
  # so $out must hold exactly those two files and nothing else.
  postInstall = ''
    mv "$out/bin/homewort-scenario" "$out/main"
    rmdir "$out/bin"
    install -m444 "$src/Pulumi.yaml" "$out/Pulumi.yaml"
  '';

  # The push unit tags the OCI artifact with this.
  passthru = { inherit version; };

  meta = {
    description = "Pulumi deployment scenario allocating one homewort VM per chall-manager instance";
    platforms = lib.platforms.linux;
  };
}
