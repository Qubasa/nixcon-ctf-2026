{ writers }:
{
  builder = writers.writePython3Bin "rtunreal-builder" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./builder.py);

  gateway = writers.writePython3Bin "rtunreal-gateway" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./gateway.py);
}
