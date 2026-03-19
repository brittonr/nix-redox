use std::{io::{self, IoSliceMut}, mem::MaybeUninit, net::SocketAddr, sync::Mutex, time::Instant};
use super::{log_sendmsg_error, RecvMeta, Transmit, UdpSockRef, IO_ERROR_LOG_INTERVAL};
#[derive(Debug)]
pub struct UdpSocketState { last_send_error: Mutex<Instant> }
impl UdpSocketState {
    pub fn new(socket: UdpSockRef<'_>) -> io::Result<Self> {
        socket.0.set_nonblocking(true)?;
        let now = Instant::now();
        Ok(Self { last_send_error: Mutex::new(now.checked_sub(2 * IO_ERROR_LOG_INTERVAL).unwrap_or(now)) })
    }
    pub fn send(&self, socket: UdpSockRef<'_>, transmit: &Transmit<'_>) -> io::Result<()> {
        match send(socket, transmit) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Err(e),
            Err(e) => { log_sendmsg_error(&self.last_send_error, e, transmit); Ok(()) }
        }
    }
    pub fn try_send(&self, socket: UdpSockRef<'_>, transmit: &Transmit<'_>) -> io::Result<()> { send(socket, transmit) }
    pub fn recv(&self, socket: UdpSockRef<'_>, bufs: &mut [IoSliceMut<'_>], meta: &mut [RecvMeta]) -> io::Result<usize> {
        let buf_len = bufs[0].len();
        let mut buf: Vec<MaybeUninit<u8>> = vec![MaybeUninit::uninit(); buf_len];
        let (len, addr) = socket.0.recv_from(&mut buf)?;
        let addr: SocketAddr = addr.as_socket().ok_or_else(|| io::Error::new(io::ErrorKind::Other, "no socket address"))?;
        let initialized = unsafe { std::slice::from_raw_parts(buf.as_ptr() as *const u8, len) };
        bufs[0][..len].copy_from_slice(initialized);
        meta[0] = RecvMeta { len, stride: len, addr, ecn: None, dst_ip: None };
        Ok(1)
    }
    #[inline] pub fn max_gso_segments(&self) -> usize { 1 }
    #[inline] pub fn gro_segments(&self) -> usize { 1 }
    #[inline] pub fn may_fragment(&self) -> bool { true }
}
fn send(socket: UdpSockRef<'_>, transmit: &Transmit<'_>) -> io::Result<()> {
    socket.0.send_to(transmit.contents, &socket2::SockAddr::from(transmit.destination))?;
    Ok(())
}
pub(crate) const BATCH_SIZE: usize = 1;
