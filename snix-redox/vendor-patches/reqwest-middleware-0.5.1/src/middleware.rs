use http::Extensions;
use reqwest::{Client, Request, Response};

use crate::error::{Error, Result};

use std::sync::Arc;

/// When attached to a [`ClientWithMiddleware`] (generally using [`with`]), middleware is run
/// whenever the client issues a request, in the order it was attached.
///
/// # Example
///
/// ```
/// use reqwest::{Client, Request, Response};
/// use reqwest_middleware::{ClientBuilder, Middleware, Next, Result};
/// use http::Extensions;
///
/// struct TransparentMiddleware;
///
/// #[async_trait::async_trait]
/// impl Middleware for TransparentMiddleware {
///     async fn handle(
///         &self,
///         req: Request,
///         extensions: &mut Extensions,
///         next: Next<'_>,
///     ) -> Result<Response> {
///         next.run(req, extensions).await
///     }
/// }
/// ```
///
/// [`ClientWithMiddleware`]: crate::ClientWithMiddleware
/// [`with`]: crate::ClientBuilder::with
pub trait Middleware: 'static + Send + Sync {
    /// Invoked with a request before sending it. If you want to continue processing the request,
    /// you should explicitly call `next.run(req, extensions)`.
    ///
    /// If you need to forward data down the middleware stack, you can use the `extensions`
    /// argument.
    fn handle<'a>(
        &'a self,
        req: Request,
        extensions: &'a mut Extensions,
        next: Next<'a>,
    ) -> BoxFuture<'a, Result<Response>>;
}

impl<F> Middleware for F
where
    F: Send
        + Sync
        + 'static
        + for<'a> Fn(Request, &'a mut Extensions, Next<'a>) -> BoxFuture<'a, Result<Response>>,
{
    fn handle<'a>(
        &'a self,
        req: Request,
        extensions: &'a mut Extensions,
        next: Next<'a>,
    ) -> BoxFuture<'a, Result<Response>> {
        (self)(req, extensions, next)
    }
}

/// Next encapsulates the remaining middleware chain to run in [`Middleware::handle`]. You can
/// forward the request down the chain with [`run`].
///
/// [`Middleware::handle`]: Middleware::handle
/// [`run`]: Self::run
#[derive(Clone)]
pub struct Next<'a> {
    client: &'a Client,
    middlewares: &'a [Arc<dyn Middleware>],
}

#[cfg(not(target_arch = "wasm32"))]
pub type BoxFuture<'a, T> = std::pin::Pin<Box<dyn std::future::Future<Output = T> + Send + 'a>>;
#[cfg(target_arch = "wasm32")]
pub type BoxFuture<'a, T> = std::pin::Pin<Box<dyn std::future::Future<Output = T> + 'a>>;

impl<'a> Next<'a> {
    pub(crate) fn new(client: &'a Client, middlewares: &'a [Arc<dyn Middleware>]) -> Self {
        Next {
            client,
            middlewares,
        }
    }

    pub fn run(
        mut self,
        req: Request,
        extensions: &'a mut Extensions,
    ) -> BoxFuture<'a, Result<Response>> {
        if let Some((current, rest)) = self.middlewares.split_first() {
            self.middlewares = rest;
            current.handle(req, extensions, self)
        } else {
            Box::pin(async move { self.client.execute(req).await.map_err(Error::from) })
        }
    }
}
