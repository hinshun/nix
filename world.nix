# CppNix as a world repo: the meson build restated as languages.cc intent. The module
# ecosystem comes from the local community.world checkout (which carries the cc module).
{ world, system }:
let
  pins = world.pins ./.world/pins.json;
in
world.new {
  version = 0;
  src = ./.;
  inherit pins;
  pkgs = import pins.nixpkgs { inherit system; };
  worlds = [ /home/hinshun/git/world-build/community.world ];
}
