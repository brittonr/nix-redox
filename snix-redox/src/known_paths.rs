//! Tracking of derivations during evaluation
//!
//! This module implements a registry for derivations encountered during
//! Nix evaluation, tracking their store paths, hash derivation modulos,
//! and output→drv mappings.
//!
//! Simplified from upstream snix — fetch support removed (no URL fetching).

use nix_compat::{derivation::Derivation, store_path::StorePath};
use std::collections::HashMap;

/// Registry of derivations encountered during evaluation
#[derive(Debug, Default)]
pub struct KnownPaths {
    /// Map from derivation store path to (hash_derivation_modulo, derivation)
    derivations: HashMap<StorePath<String>, ([u8; 32], Derivation)>,
    /// Reverse lookup: output path → derivation path
    outputs_to_drvpath: HashMap<StorePath<String>, StorePath<String>>,
}

impl KnownPaths {
    /// Get the hash derivation modulo for a derivation path
    pub fn get_hash_derivation_modulo(
        &self,
        drv_path: &StorePath<String>,
    ) -> Option<&[u8; 32]> {
        self.derivations.get(drv_path).map(|(h, _)| h)
    }

    /// Get a derivation by its store path
    pub fn get_drv_by_drvpath(&self, drv_path: &StorePath<String>) -> Option<&Derivation> {
        self.derivations.get(drv_path).map(|(_, drv)| drv)
    }

    /// Get the derivation path for an output path
    pub fn get_drv_path_for_output_path(
        &self,
        output_path: &StorePath<String>,
    ) -> Option<&StorePath<String>> {
        self.outputs_to_drvpath.get(output_path)
    }

    /// Register a derivation
    ///
    /// # Panics
    ///
    /// Panics in debug builds if any input derivations are not already registered.
    pub fn add_derivation(&mut self, drv_path: StorePath<String>, drv: Derivation) {
        // Verify all input derivations are already known (debug only)
        #[cfg(debug_assertions)]
        {
            for input_drv_path in drv.input_derivations.keys() {
                debug_assert!(
                    self.derivations.contains_key(input_drv_path),
                    "input derivation {} not yet registered",
                    input_drv_path
                );
            }
        }

        // Compute hash derivation modulo
        let hash_derivation_modulo = drv.hash_derivation_modulo(|drv_path| {
            *self
                .get_hash_derivation_modulo(&drv_path.to_owned())
                .expect("input derivation not in known_paths")
        });

        // Update output→drv lookup table
        for output in drv.outputs.values() {
            if let Some(ref path_store_path) = output.path {
                self.outputs_to_drvpath
                    .insert(path_store_path.clone(), drv_path.clone());
            }
        }

        // Insert the derivation
        self.derivations
            .insert(drv_path, (hash_derivation_modulo, drv));
    }

    /// Get all registered derivations
    pub fn get_derivations(&self) -> impl Iterator<Item = (&StorePath<String>, &Derivation)> {
        self.derivations.iter().map(|(k, (_, v))| (k, v))
    }
}
