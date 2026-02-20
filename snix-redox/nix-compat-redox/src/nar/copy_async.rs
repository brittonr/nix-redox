use std::io;

use tokio::io::{AsyncBufRead, AsyncWrite};

use super::reader::r#async as reader;
use super::writer::r#async as writer;

/// Reads through the entire NAR, and writes it back to a writer.
/// This verifies its syntactical correctness.
pub async fn copy<R, W>(mut r: R, mut w: W) -> io::Result<()>
where
    R: AsyncBufRead + Send + Unpin,
    W: AsyncWrite + Send + Unpin,
{
    let node_r = reader::open(&mut r).await?;
    let node_w = writer::open(&mut w).await?;

    copy_node(node_r, node_w).await
}

async fn copy_node(node_r: reader::Node<'_, '_>, node_w: writer::Node<'_, '_>) -> io::Result<()> {
    match node_r {
        reader::Node::Symlink { target } => node_w.symlink(&target).await?,
        reader::Node::File {
            executable,
            mut reader,
        } => node_w.file(executable, reader.len(), &mut reader).await?,
        reader::Node::Directory(mut dir_reader) => {
            let mut directory_w = node_w.directory().await?;
            while let Some(entry) = dir_reader.next().await? {
                let node_w = directory_w.entry(entry.name).await?;
                Box::pin(copy_node(entry.node, node_w)).await?;
            }

            directory_w.close().await?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use rstest::rstest;
    use std::path::PathBuf;

    #[rstest]
    #[tokio::test]
    async fn roundtrip(#[files("src/nar/tests/*.nar")] path: PathBuf) {
        let nar_src = std::fs::read(path).expect("must succeed");

        let mut out_buf = Vec::new();

        assert!(
            super::copy(&mut std::io::Cursor::new(&nar_src), &mut out_buf)
                .await
                .is_ok()
        );
        assert_eq!(nar_src, out_buf, "must roundtrip");
    }
}
