# PhantomLink (https://github.com/robinohs/phantomlink) emulates a bottlenecked,
# delay-varying link. Its `setup`/`exec`/`teardown` build their own namespaces and
# veths, duplicating nixnet; only `start` is used here, which relays frames between
# the link node's "sim-veth1"/"sim-veth2" via raw sockets.
#
# `src` is the `phantomlink` flake input, so a local checkout can be built with
# `--override-input phantomlink git+file:/path/to/phantomlink`.
{
  lib,
  rustPlatform,
  src,
}:
let
  cargoToml = lib.importTOML (src + "/Cargo.toml");
in
rustPlatform.buildRustPackage {
  pname = cargoToml.package.name;
  inherit (cargoToml.package) version;
  inherit src;
  cargoLock.lockFile = src + "/Cargo.lock";
}
