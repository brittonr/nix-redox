use nix_compat_derive::nix_serialize_remote;

use crate::nixhash;

nix_serialize_remote!(
    #[nix(display)]
    nixhash::HashAlgo
);
