{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

let
  # (ctfd-chall-manager v0.10.1) is tested against this backend version, and
  # the plugin speaks the HTTP gateway's v1 API without any version
  version = "0.6.6";
in
buildGoModule {
  pname = "chall-manager";
  inherit version;

  src = fetchFromGitHub {
    owner = "ctfer-io";
    repo = "chall-manager";
    tag = "v${version}";
    hash = "sha256-HmRZkAw8X3XQeYYxzhTE6t7lZp9koZfOLThN/lCgBII=";
  };

  vendorHash = "sha256-dlAsW5NEF8t4N+RhMy8P6dDcPbnDcwN03oaOQx+Mu4k=";

  postPatch = ''
    rm -f go.work go.work.sum
  '';

  subPackages = [
    "cmd/chall-manager"
    "cmd/chall-manager-janitor"
  ];

  ldflags = [
    "-s"
    "-w"
    "-X=main.Version=${version}"
    "-X=main.Commit=6c94f9c1af2bb962bd9fd2cee0b13b97dd39d969"
    "-X=main.BuiltBy=nix"
  ];

  meta = {
    description = "Challenge instances on demand for CTF platforms";
    homepage = "https://github.com/ctfer-io/chall-manager";
    license = lib.licenses.asl20;
    mainProgram = "chall-manager";
  };
}
