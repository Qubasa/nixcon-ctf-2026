{ ... }:
{
  # Import this module into a machine to enable GNOME and GDM.
  #
  # Copy the snippet below into a machine's configuration:
  # `machines/<name>/configuration.nix`
  # ```nix
  # imports = [
  #   ../../modules/gnome.nix
  # ];
  # ```

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
}
