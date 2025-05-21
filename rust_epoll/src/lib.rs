use std::{
    net::{TcpListener, ToSocketAddrs},
    sync::Arc,
};

use polller::{Connection, Poller};
use pool::{ThreadErr, ThreadFunc, ThreadPool};

pub mod polller;
pub mod pool;

pub struct AsyncListener<const S: usize> {
    server: TcpListener,
    poller: Poller,
    thread_pool: Arc<ThreadPool<S>>,
}
impl<const S: usize> AsyncListener<S> {
    pub fn new<A: ToSocketAddrs>(addr: A, max_events: u32) -> Self {
        let server = TcpListener::bind(addr).unwrap();
        let poller = Poller::new(max_events, &server).unwrap();
        Self {
            server,
            poller,
            thread_pool: Arc::new(ThreadPool::new()),
        }
    }
    pub fn serve<F>(&mut self, timeout: i32, conn_closure: F)
    where
        F: FnMut(usize, Connection) -> Result<(), ThreadErr> + 'static + Send + Sync,
    {
        let pool = Arc::clone(&self.thread_pool);
        pool.dispatch();
        let eq = Arc::clone(&self.thread_pool);
        self.poller.poll(timeout, &self.server, move |conn| {
            let cl: ThreadFunc = Arc::new(move |id| conn_closure(id, conn));
            eq.enqueue(cl);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {}
}
