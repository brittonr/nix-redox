use proc_macro::TokenStream;

#[proc_macro_attribute]
pub fn auto_impl(_args: TokenStream, input: TokenStream) -> TokenStream {
    let src = input.to_string();
    let impls = if src.contains("trait BlobService") {
        blob_service_impls()
    } else if src.contains("trait DirectoryService") {
        directory_service_impls()
    } else if src.contains("trait NarCalculationService") {
        nar_calculation_service_impls()
    } else if src.contains("trait PathInfoService") {
        path_info_service_impls()
    } else {
        String::new()
    };
    format!("{}\n{}", src, impls).parse().unwrap_or(input)
}

fn blob_service_impls() -> String {
    let body = r#"
    async fn has(&self, digest: &B3Digest) -> io::Result<bool> { __AUTO_IMPL_TARGET__.has(digest).await }
    async fn open_read(&self, digest: &B3Digest) -> io::Result<Option<Box<dyn BlobReader>>> { __AUTO_IMPL_TARGET__.open_read(digest).await }
    async fn open_write(&self) -> Box<dyn BlobWriter> { __AUTO_IMPL_TARGET__.open_write().await }
    async fn chunks(&self, digest: &B3Digest) -> io::Result<Option<Vec<ChunkMeta>>> { __AUTO_IMPL_TARGET__.chunks(digest).await }
"#;
    impl_for("BlobService", body)
}

fn directory_service_impls() -> String {
    let body = r#"
    async fn get(&self, digest: &B3Digest) -> Result<Option<Directory>, Error> { __AUTO_IMPL_TARGET__.get(digest).await }
    async fn put(&self, directory: Directory) -> Result<B3Digest, Error> { __AUTO_IMPL_TARGET__.put(directory).await }
    fn get_recursive(&self, root_directory_digest: &B3Digest) -> BoxStream<'_, Result<Directory, Error>> { __AUTO_IMPL_TARGET__.get_recursive(root_directory_digest) }
    fn put_multiple_start(&self) -> Box<dyn DirectoryPutter + '_> { __AUTO_IMPL_TARGET__.put_multiple_start() }
"#;
    impl_for("DirectoryService", body)
}

fn nar_calculation_service_impls() -> String {
    let body = r#"
    async fn calculate_nar(&self, root_node: &Node) -> Result<(u64, [u8; 32]), pathinfoservice::Error> { __AUTO_IMPL_TARGET__.calculate_nar(root_node).await }
"#;
    impl_for("NarCalculationService", body)
}

fn path_info_service_impls() -> String {
    let body = r#"
    async fn get(&self, digest: [u8; 20]) -> Result<Option<PathInfo>, Error> { __AUTO_IMPL_TARGET__.get(digest).await }
    async fn has(&self, digest: [u8; 20]) -> Result<bool, Error> { __AUTO_IMPL_TARGET__.has(digest).await }
    async fn put(&self, path_info: PathInfo) -> Result<PathInfo, Error> { __AUTO_IMPL_TARGET__.put(path_info).await }
    fn list(&self) -> BoxStream<'static, Result<PathInfo, Error>> { __AUTO_IMPL_TARGET__.list() }
    fn nar_calculation_service(&self) -> Option<Box<dyn NarCalculationService>> { __AUTO_IMPL_TARGET__.nar_calculation_service() }
"#;
    impl_for("PathInfoService", body)
}

fn impl_for(trait_name: &str, body_template: &str) -> String {
    let arc_body = body_template.replace("__AUTO_IMPL_TARGET__", "(**self)");
    let ref_body = body_template.replace("__AUTO_IMPL_TARGET__", "(**self)");
    let mut_body = body_template.replace("__AUTO_IMPL_TARGET__", "(**self)");
    let box_body = body_template.replace("__AUTO_IMPL_TARGET__", "(**self)");
    format!(
        r#"
impl<T: {trait_name} + ?Sized> {trait_name} for std::sync::Arc<T> {{ {arc_body} }}
impl<T: {trait_name} + ?Sized> {trait_name} for Box<T> {{ {box_body} }}
impl<T: {trait_name} + ?Sized> {trait_name} for &T {{ {ref_body} }}
impl<T: {trait_name} + ?Sized> {trait_name} for &mut T {{ {mut_body} }}
"#,
        trait_name = trait_name,
        arc_body = arc_body,
        box_body = box_body,
        ref_body = ref_body,
        mut_body = mut_body,
    )
}
