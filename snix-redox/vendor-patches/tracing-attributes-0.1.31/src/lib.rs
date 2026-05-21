//! Minimal Redox self-hosting replacement for tracing-attributes.
//!
//! The upstream macro is used only for diagnostics/instrumentation in snix. Redox
//! rustc currently spins compiling the full proc-macro dependency stack in the
//! self-hosted guest, so this patched crate preserves source compatibility by
//! leaving instrumented items unchanged.

extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro_attribute]
pub fn instrument(_args: TokenStream, item: TokenStream) -> TokenStream {
    item
}
