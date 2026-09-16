use crate::state::Gate;
use bytes::Bytes;
use futures_util::{Sink, Stream, ready};
use iroh_relay::{ExportKeyingMaterial, protos::streams::StreamError};
use n0_error::AnyError;
use std::{
    io,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_tungstenite::{WebSocketStream, tungstenite::Message};

pub struct GuardedIo<T> {
    pub inner: T,
    pub gate: Arc<Gate>,
    read_reserved: bool,
    write_reserved: usize,
}
impl<T> GuardedIo<T> {
    pub fn new(inner: T, gate: Arc<Gate>) -> Self {
        Self {
            inner,
            gate,
            read_reserved: false,
            write_reserved: 0,
        }
    }
}
impl<T: AsyncRead + Unpin> AsyncRead for GuardedIo<T> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        this.gate.reader.register(cx.waker());
        if output.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        let capacity = output.remaining().min(8192);
        if !this.read_reserved {
            this.gate.reserve(8192, false)?;
            this.read_reserved = true;
        }
        let mut bytes = [0u8; 8192];
        let mut read = ReadBuf::new(&mut bytes[..capacity]);
        let polled = this
            .gate
            .allowed(|| Pin::new(&mut this.inner).poll_read(cx, &mut read))?;
        match polled {
            Poll::Pending => Poll::Pending,
            Poll::Ready(result) => {
                this.read_reserved = false;
                if result.is_ok() {
                    this.gate.record_bytes(read.filled().len(), false);
                    output.put_slice(read.filled());
                }
                Poll::Ready(result)
            }
        }
    }
}

pub struct PrefixedIo<T> {
    pub prefix: Bytes,
    pub inner: T,
}
impl<T: AsyncRead + Unpin> AsyncRead for PrefixedIo<T> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if !this.prefix.is_empty() {
            let size = output.remaining().min(this.prefix.len());
            output.put_slice(&this.prefix.split_to(size));
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut this.inner).poll_read(cx, output)
    }
}
impl<T: AsyncWrite + Unpin> AsyncWrite for PrefixedIo<T> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, bytes)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}
impl<T: AsyncWrite + Unpin> AsyncWrite for GuardedIo<T> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        this.gate.writer.register(cx.waker());
        if bytes.is_empty() {
            return Poll::Ready(Ok(0));
        }
        if this.write_reserved == 0 {
            this.write_reserved = bytes.len().min(8192);
            this.gate.reserve(this.write_reserved, true)?;
        }
        let limit = bytes.len().min(this.write_reserved);
        let result = this
            .gate
            .allowed(|| Pin::new(&mut this.inner).poll_write(cx, &bytes[..limit]))?;
        match result {
            Poll::Pending => Poll::Pending,
            Poll::Ready(result) => {
                this.write_reserved = 0;
                if let Ok(size) = result {
                    this.gate.record_bytes(size, true);
                }
                Poll::Ready(result)
            }
        }
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        this.gate.writer.register(cx.waker());
        this.gate
            .allowed(|| Pin::new(&mut this.inner).poll_flush(cx))
            .unwrap_or_else(|e| Poll::Ready(Err(e)))
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        // Denied TLS buffers must be dropped rather than flushed during graceful shutdown.
        this.gate
            .allowed(|| Pin::new(&mut this.inner).poll_shutdown(cx))
            .unwrap_or_else(|e| Poll::Ready(Err(e)))
    }
}

pub struct WebSocketBytes<T> {
    pub inner: WebSocketStream<T>,
    pub gate: Arc<Gate>,
}
impl<T> ExportKeyingMaterial for WebSocketBytes<T> {
    fn export_keying_material<O: AsMut<[u8]>>(
        &self,
        _out: O,
        _label: &[u8],
        _context: Option<&[u8]>,
    ) -> Option<O> {
        // The upstream handshake falls back to a signed random challenge.
        None
    }
}
impl<T: AsyncRead + AsyncWrite + Unpin> Stream for WebSocketBytes<T> {
    type Item = Result<Bytes, StreamError>;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        this.gate.reader.register(cx.waker());
        if let Err(error) = this.gate.allowed(|| ()) {
            return Poll::Ready(Some(Err(AnyError::from_std(error))));
        }
        loop {
            match ready!(Pin::new(&mut this.inner).poll_next(cx)) {
                Some(Ok(Message::Binary(bytes))) => return Poll::Ready(Some(Ok(bytes))),
                Some(Ok(Message::Close(_))) | None => return Poll::Ready(None),
                Some(Ok(Message::Ping(_) | Message::Pong(_))) => continue,
                Some(Ok(_)) => {
                    return Poll::Ready(Some(Err(AnyError::from_std(io::Error::other(
                        "binary relay records required",
                    )))));
                }
                Some(Err(error)) => return Poll::Ready(Some(Err(AnyError::from_std(error)))),
            }
        }
    }
}
impl<T: AsyncRead + AsyncWrite + Unpin> Sink<Bytes> for WebSocketBytes<T> {
    type Error = StreamError;
    fn start_send(self: Pin<&mut Self>, bytes: Bytes) -> Result<(), Self::Error> {
        let this = self.get_mut();
        this.gate.allowed(|| ()).map_err(AnyError::from_std)?;
        Pin::new(&mut this.inner)
            .start_send(Message::Binary(bytes))
            .map_err(AnyError::from_std)
    }
    fn poll_ready(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        let this = self.get_mut();
        this.gate.writer.register(cx.waker());
        this.gate.allowed(|| ()).map_err(AnyError::from_std)?;
        Pin::new(&mut this.inner)
            .poll_ready(cx)
            .map_err(AnyError::from_std)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        let this = self.get_mut();
        this.gate.writer.register(cx.waker());
        this.gate.allowed(|| ()).map_err(AnyError::from_std)?;
        Pin::new(&mut this.inner)
            .poll_flush(cx)
            .map_err(AnyError::from_std)
    }
    fn poll_close(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        let this = self.get_mut();
        this.gate.allowed(|| ()).map_err(AnyError::from_std)?;
        Pin::new(&mut this.inner)
            .poll_close(cx)
            .map_err(AnyError::from_std)
    }
}
