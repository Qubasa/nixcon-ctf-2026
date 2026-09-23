# The two halves of the service. Both are plain stdlib Python: no framework, no
# dependency, and nothing that needs to be pinned for an event that runs for two
# days.
{ writers }:
{
  # Runs inside the challenge VM. It needs `nix`, `git`, and `patch` on its
  # PATH. The unit puts them there rather than a wrapper, so the guest's own
  # `nix.package` is the client that talks to its daemon.
  builder = writers.writePython3Bin "rtunreal-builder" {
    # ruff formats at 88 columns, flake8 insists on 79.
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./builder.py);

  # Runs on the host. It holds the flag and evaluates nothing.
  gateway = writers.writePython3Bin "rtunreal-gateway" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./gateway.py);
}
