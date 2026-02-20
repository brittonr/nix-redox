use std::{
    io::Result,
    pin::Pin,
    task::{Poll, ready},
};

use bytes::{BufMut, BytesMut};
use pin_project_lite::pin_project;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use crate::worker_protocol::STDERR_READ;

#[derive(Debug)]
struct U64WriteState {
    bytes: [u8; 8],
    written: usize,
}

impl U64WriteState {
    fn remaining(&self) -> &[u8] {
        &self.bytes[self.written..]
    }
}

/// State machine for [`StderrReadFramedReader`].
///
/// As the reader progresses it linearly cycles through the states.
#[derive(Debug)]
enum StderrReaderState {
    /// Represents the state indicating that we are about to request a new frame.
    ///
    /// When poll_read is called, it writes STDERR_READ into the writer and
    /// progresses to the [`StderrReaderState::RequestingFrameLen`] state
    ///
    /// The reader always starts in this state and is reached after every frame has
    /// been fully read.
    RequestingNextFrame { write_state: U64WriteState },
    /// At this point the reader writes the desired payload length we want to receive
    /// based on read_buf.remaining().
    RequestingFrameLen {
        // We need to write 8 bytes of the length u64 value,
        // this variable stores how many we've written so far.
        write_state: U64WriteState,
    },
    /// At this point the reader just flushes the writer and gets ready to receive
    /// the actual payload size that is about to be sent to us by transitioning to
    /// the [`StderrReaderState::ReadingSize`] state.
    FrameLenRequested,
    /// The size is a u64 which is 8 bytes long, while it's likely that we will receive
    /// the whole u64 in one read, it's possible that it will arrive in smaller chunks.
    /// So in this state we read up to 8 bytes and transition to
    /// [`StderrReaderState::ReadingPayload`] when done.
    ReadingSize { buf: [u8; 8], filled: usize },
    /// This is where we read the actual payload that is sent to us.
    /// All of the previous states were just internal bookkeeping where we did not return
    /// any data to the conumer, and only returned Poll::Pending.
    ///
    /// Having read the full payload, progresses to the [`StderrReaderState::RequestingNextFrame`]
    /// state to read the next frame when/if requested.
    ReadingPayload {
        /// Represents the remaining number of bytes we expect to read based on the value
        /// read in the previous state.
        remaining: u64,
        /// Represents the remaining of padding we expect to read before switching back
        /// to the RequestingNextFrame state.
        pad: usize,
        /// In an ideal case this reader does not allocate, but in the scenario where
        /// we've read the whol payload frame but still have padding remaining, it's not
        /// safe to return the payload to the consumer as there is risk that the reader
        /// won't be called again, leaving dangling padding. In this case we store the
        /// payload in this buffer until we've read the padding, and then return the data
        /// from here.
        tmp_buf: BytesMut,
    },
}

impl StderrReaderState {
    fn request_next_frame() -> Self {
        Self::RequestingNextFrame {
            write_state: U64WriteState {
                bytes: STDERR_READ.to_le_bytes(),
                written: 0,
            },
        }
    }

    fn read_written(len: u64) -> Self {
        Self::RequestingFrameLen {
            write_state: U64WriteState {
                bytes: len.to_le_bytes(),
                written: 0,
            },
        }
    }
}

pin_project! {
    /// Implements the reader protocol for STDERR_READ in nix protocol version 1.21..1.23.
    ///
    /// See logging.md#stderr_read and [`StderrReaderState`] for details.
    ///
    /// FUTUREWORK: As per the nix protocol, it should be possible to send logging messages
    /// concurrently with reads, however this reader currently monopolizes the writer until eof is
    /// reached or the writer is dropped. It's important we don't allow certain interleavings of
    /// log writes, i.e. it's not ok to issue a log message right after we've requested
    /// STDERR_READ, but before requesting the length.
    pub struct StderrReadFramedReader<R, W> {
        #[pin]
        reader: R,
        #[pin]
        writer: W,
        state: StderrReaderState
    }
}

impl<R, W> StderrReadFramedReader<R, W> {
    pub fn new(reader: R, writer: W) -> Self {
        Self {
            reader,
            writer,
            state: StderrReaderState::request_next_frame(),
        }
    }
}

impl<R: AsyncRead, W: AsyncWrite> AsyncRead for StderrReadFramedReader<R, W> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        read_buf: &mut ReadBuf<'_>,
    ) -> Poll<Result<()>> {
        loop {
            let mut this = self.as_mut().project();
            match this.state {
                StderrReaderState::RequestingNextFrame { write_state } => {
                    write_state.written +=
                        ready!(this.writer.poll_write(cx, write_state.remaining()))?;
                    if write_state.written == 8 {
                        *this.state = StderrReaderState::read_written(read_buf.remaining() as u64);
                    }
                }
                StderrReaderState::RequestingFrameLen { write_state } => {
                    write_state.written +=
                        ready!(this.writer.poll_write(cx, write_state.remaining()))?;
                    if write_state.written == 8 {
                        *this.state = StderrReaderState::FrameLenRequested;
                    }
                }
                StderrReaderState::FrameLenRequested => {
                    ready!(this.writer.poll_flush(cx))?;
                    *this.state = StderrReaderState::ReadingSize {
                        buf: [0u8; 8],
                        filled: 0,
                    };
                }
                StderrReaderState::ReadingSize { buf, filled } => {
                    if *filled < buf.len() {
                        let mut size_buf = ReadBuf::new(buf);
                        size_buf.advance(*filled);

                        ready!(this.reader.poll_read(cx, &mut size_buf))?;
                        let bytes_read = size_buf.filled().len() - *filled;
                        if bytes_read == 0 {
                            // oef
                            return Poll::Ready(Ok(()));
                        }
                        *filled += bytes_read;
                        continue;
                    }
                    let size = u64::from_le_bytes(*buf);
                    if size == 0 {
                        // eof
                        *this.state = StderrReaderState::request_next_frame();
                        return Poll::Ready(Ok(()));
                    }
                    let pad = (8 - (size % 8) as usize) % 8;
                    *this.state = StderrReaderState::ReadingPayload {
                        remaining: size,
                        pad,
                        tmp_buf: BytesMut::new(),
                    };
                }
                StderrReaderState::ReadingPayload {
                    remaining,
                    pad,
                    tmp_buf,
                } => {
                    // Make sure we never try to read more than usize which is 4 bytes on 32-bit platforms.
                    let safe_remaining = if *remaining <= (usize::MAX - *pad) as u64 {
                        *remaining as usize + *pad
                    } else {
                        usize::MAX
                    };
                    if safe_remaining - *pad > 0 {
                        // The buffer is no larger than the amount of data that we expect.
                        // Otherwise we will trim the buffer below and come back here.
                        if read_buf.remaining() <= safe_remaining {
                            let filled_before = read_buf.filled().len();

                            ready!(this.reader.as_mut().poll_read(cx, read_buf))?;
                            let bytes_read = read_buf.filled().len() - filled_before;
                            let payload_size = std::cmp::min(bytes_read, safe_remaining - *pad);

                            // we don't want to include padding bytes in the result, so we remove them from read_buf.
                            read_buf.set_filled(filled_before + payload_size);

                            *remaining -= payload_size as u64;
                            if *remaining > 0 {
                                // We have more data to read so we just return ok, knowing that the consumer
                                // will read again.
                                return Poll::Ready(Ok(()));
                            }

                            // If we don't have any remaining data to read, consume any padding we may have just read.
                            *pad -= bytes_read - payload_size;
                            if *pad != 0 {
                                // We haven't read all the padding yet, so we stash it away to return to the caller
                                // once we've read the remaining padding.
                                tmp_buf.clear();
                                tmp_buf.put_slice(&read_buf.filled()[filled_before..payload_size]);
                                read_buf.set_filled(filled_before);
                                continue;
                            }
                            *this.state = StderrReaderState::request_next_frame();
                            return Poll::Ready(Ok(()));
                        }

                        // Don't read more than remaining + pad bytes, it avoids unnecessary allocations and makes
                        // internal bookkeeping simpler.
                        let mut smaller_buf = read_buf.take(safe_remaining);
                        ready!(self.as_mut().poll_read(cx, &mut smaller_buf))?;

                        let bytes_read = smaller_buf.filled().len();

                        // SAFETY: we just read this number of bytes into read_buf's backing slice above.
                        unsafe { read_buf.assume_init(bytes_read) };
                        read_buf.advance(bytes_read);
                        return Poll::Ready(Ok(()));
                    } else if *pad > 0 {
                        // if we've read the whole payload but there is still padding remaining,
                        // we read it into a stack allocated array
                        let mut pad_arr = [0u8; 7];
                        let mut pad_buf = ReadBuf::new(&mut pad_arr);
                        pad_buf.advance(7 - *pad);
                        ready!(this.reader.poll_read(cx, &mut pad_buf))?;
                        *pad = pad_buf.remaining();
                        if *pad != 0 {
                            continue;
                        }
                    }
                    // now it's finally time to hand out the read data to the caller and reset to the RequestingNextFrame state.
                    read_buf.put_slice(tmp_buf);
                    tmp_buf.clear();
                    *this.state = StderrReaderState::request_next_frame();
                    return Poll::Ready(Ok(()));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use hex_literal::hex;
    use tokio::io::{AsyncReadExt, BufReader, split};
    use tokio_test::io::Builder;

    use crate::{nix_daemon::framing::StderrReadFramedReader, worker_protocol::STDERR_READ};

    #[tokio::test]
    async fn test_single_two_byte_read_with_desired_size_ten() {
        let mock = Builder::new()
            // The reader should first write STDERR_READ and requested number of bytes into the writer
            .write(&STDERR_READ.to_le_bytes())
            .write(&10u64.to_le_bytes())
            .wait(Duration::ZERO)
            // The client sent not 10 but 2 bytes
            .read(&2u64.to_le_bytes())
            // Immediately followed by the bytes and padding
            .read("hi".as_bytes())
            .read(&hex!("0000 0000 0000"))
            .build();
        let (r, w) = split(mock);
        let mut reader = StderrReadFramedReader::new(r, w);

        let mut result = [0u8; 2];
        let mut buf_reader = BufReader::with_capacity(10, &mut reader);
        let n = buf_reader.read_exact(&mut result).await.unwrap();

        assert_eq!(2, n);
        assert_eq!("hi".as_bytes(), result);
    }

    #[tokio::test]
    async fn test_single_read_with_padding_delayed() {
        let mock = Builder::new()
            // The reader should first write STDERR_READ and requested number of bytes into the writer
            .write(&STDERR_READ.to_le_bytes())
            .write(&10u64.to_le_bytes())
            // The client sent 9 bytes not 10.
            .read(&9u64.to_le_bytes())
            // Immeditaly followed by bytes
            .read(&hex!("0202 0104 ffff ffaa 00"))
            // Followed by a delayed padding
            .wait(Duration::ZERO)
            .read(&hex!("0000 0000 0000 00"))
            .build();
        let (r, w) = split(mock);
        let mut reader = StderrReadFramedReader::new(r, w);

        let mut result = [0u8; 9];
        let mut buf_reader = BufReader::with_capacity(10, &mut reader);
        let n = buf_reader.read_exact(&mut result).await.unwrap();

        assert_eq!(9, n);
        assert_eq!(hex!("0202 0104 ffff ffaa 00"), result);
    }

    #[tokio::test]
    async fn test_multiple_consecutive_reads_with_arbitrary_delays() {
        let mock = Builder::new()
            // The reader should first write STDERR_READ and requested number of bytes into the writer
            .write(&STDERR_READ.to_le_bytes())
            .write(&8192u64.to_le_bytes())
            .wait(Duration::ZERO)
            // The client sends 6 bytes 'hello ' plus padding
            .read(&6u64.to_le_bytes())
            .wait(Duration::ZERO)
            .read("hello ".as_bytes())
            .read(&hex!("0000"))
            // The reader sends desired length again
            .write(&STDERR_READ.to_le_bytes())
            .write(&8192u64.to_le_bytes())
            // The client sends 11 bytes 'racerunners' with 's' and padding delayed
            .wait(Duration::ZERO)
            .read(&11u64.to_le_bytes())
            .read("racerunner".as_bytes())
            .wait(Duration::ZERO)
            .read("s".as_bytes())
            .read(&hex!("0000 0000"))
            .wait(Duration::ZERO)
            .read(&hex!("00"))
            .write(&STDERR_READ.to_le_bytes())
            .write(&8192u64.to_le_bytes())
            .wait(Duration::ZERO)
            .read(&0u64.to_le_bytes())
            .build();
        let (r, w) = split(mock);
        let mut reader = StderrReadFramedReader::new(r, w);

        let mut res = String::new();
        let mut buf_reader = BufReader::with_capacity(8192, &mut reader);
        let n = buf_reader.read_to_string(&mut res).await.unwrap();

        assert_eq!(17, n);
        assert_eq!("hello racerunners", &res);
    }

    #[tokio::test]
    async fn test_single_read_where_writing_stderr_and_desired_size_take_more_than_one_write() {
        let stderr_bytes = STDERR_READ.to_le_bytes();
        let length_bytes = 10u64.to_le_bytes();
        let mock = Builder::new()
            .write(&stderr_bytes[..4])
            .wait(Duration::ZERO)
            .write(&stderr_bytes[4..])
            .wait(Duration::ZERO)
            .write(&length_bytes[..4])
            .wait(Duration::ZERO)
            .write(&length_bytes[4..])
            .wait(Duration::ZERO)
            // The client sent not 10 but 2 bytes
            .read(&2u64.to_le_bytes())
            // Immediately followed by the bytes and padding
            .read("hi".as_bytes())
            .read(&hex!("0000 0000 0000"))
            .build();
        let (r, w) = split(mock);
        let mut reader = StderrReadFramedReader::new(r, w);

        let mut result = [0u8; 2];
        let mut buf_reader = BufReader::with_capacity(10, &mut reader);
        let n = buf_reader.read_exact(&mut result).await.unwrap();

        assert_eq!(2, n);
        assert_eq!("hi".as_bytes(), result);
    }

    #[tokio::test]
    async fn hello() {}
}
