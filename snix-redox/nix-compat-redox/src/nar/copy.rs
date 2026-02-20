use std::io;

use super::reader;
use super::reader::Reader;
use super::writer;

/// Reads through the entire NAR, and writes it back to a writer.
/// This verifies its syntactical correctness.
pub fn copy<W>(r: &mut Reader<'_>, w: &mut W) -> io::Result<()>
where
    W: std::io::Write,
{
    let node_r = reader::open(r)?;
    let node_w = writer::open(w)?;

    copy_node(node_r, node_w)
}

fn copy_node<W>(node_r: reader::Node<'_, '_>, node_w: writer::Node<'_, W>) -> io::Result<()>
where
    W: std::io::Write,
{
    match node_r {
        reader::Node::Symlink { target } => node_w.symlink(&target)?,
        reader::Node::File { executable, reader } => node_w.file(
            executable,
            reader.len(),
            &mut std::io::BufReader::new(reader),
        )?,
        reader::Node::Directory(mut dir_reader) => {
            let mut directory_w = node_w.directory()?;
            while let Some(entry) = dir_reader.next()? {
                let node_w = directory_w.entry(entry.name)?;
                copy_node(entry.node, node_w)?;
            }

            directory_w.close()?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use rstest::rstest;
    use std::path::PathBuf;

    #[rstest]
    fn roundtrip(#[files("src/nar/tests/*.nar")] path: PathBuf) {
        let nar_src = std::fs::read(path).expect("must succeed");

        let mut out_buf = Vec::new();

        assert!(super::copy(&mut std::io::Cursor::new(&nar_src), &mut out_buf).is_ok());
        assert_eq!(nar_src, out_buf, "must roundtrip");
    }
}
