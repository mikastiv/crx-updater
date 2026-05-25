{
  linkFarm,
  fetchzip,
  fetchgit,
}:
linkFarm "zig-packages" [
  {
    name = "mksv-0.0.1-SesxeIg4AAAxnAqrX4eSfBB-mFjYmbWpbgdfOWOZ2UU_";
    path = fetchgit {
      url = "https://codeberg.org/mikastiv/mksv.git";
      rev = "30c8d2fc97ba3d09764a3990b4f1516768fa6927";
      hash = "sha256-ThaqFunjhGmi3XrJnF299GSGgfUAfyeXnPda8OLc9JU=";
    };
  }
]
