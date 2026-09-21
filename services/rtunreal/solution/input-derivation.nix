{
  lib,
  stdenvNoCC,
  src,
  php,
  pmp_patch,
}:
stdenvNoCC.mkDerivation {
  pname = "pmp";
  version = "1.0";

  inherit src;

  patches = [ pmp_patch ];

  postPatch = ''
    substituteInPlace main.php --replace-fail '// TODO' '
    if ($print_target) {
        echo $targetFile . "\n";
        exit(0);
    }
    '
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    {
      echo "#!${lib.getExe php}"
      tail -n +2 main.php
    } > $out/bin/pmp
    chmod +x $out/bin/pmp
    runHook postInstall
  '';

  meta.mainProgram = "pmp";
}
