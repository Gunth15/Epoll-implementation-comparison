use libc::{self, EPOLLERR, EPOLLET, EPOLLHUP, EPOLLRDHUP, c_int, epoll_event};
use std::alloc::{self, Layout};
use std::ffi::c_uint;
use std::io::{Error, ErrorKind, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::ptr::null_mut;
use std::thread::{self};
use std::{net, os::fd::AsRawFd};

#[derive(Debug, Clone)]
pub enum ConnectionState {
    Closed,
    Opened,
    Data,
}
#[derive(Debug)]
pub struct Connection {
    pub state: ConnectionState,
    pub stream: TcpStream,
    pub socket_addr: SocketAddr,
    pub id: u64,
}
impl Clone for Connection {
    fn clone(&self) -> Self {
        Self {
            state: self.state.clone(),
            stream: self.stream.try_clone().unwrap(),
            socket_addr: self.socket_addr,
            id: self.id,
        }
    }
}

pub struct Poller {
    epollfd: c_uint,
    max_events: c_uint,
    connections: Vec<Option<Connection>>,
}
impl Poller {
    pub fn new(max_events: u32, listener: &net::TcpListener) -> Result<Poller, Error> {
        unsafe {
            let epollfd = libc::epoll_create(1);
            if epollfd == -1 {
                return Err(Error::last_os_error());
            };

            let mut events = epoll_event {
                u64: 0,
                events: u32::try_from(libc::EPOLLIN | libc::EPOLLOUT).unwrap(),
            };

            let ptr: *mut epoll_event = &mut events;

            listener
                .set_nonblocking(true)
                .expect("Coud not set listener to non-blocking");
            let err = libc::epoll_ctl(epollfd, libc::EPOLL_CTL_ADD, listener.as_raw_fd(), ptr);
            if err == -1 {
                return Err(Error::last_os_error());
            };

            Ok(Poller {
                epollfd: u32::try_from(epollfd).unwrap(),
                max_events,
                connections: Vec::new(),
            })
        }
    }
    pub fn poll<F>(&mut self, timeout: i32, listener: &TcpListener, mut connection_closure: F)
    where
        F: FnMut(Connection),
    {
        let events = self.wait(timeout).expect("Could not get events");

        for event in events {
            if event.u64 == 0 {
                let mut conn: Connection = match listener.accept() {
                    Ok((stream, socket_addr)) => Connection {
                        id: 0,
                        socket_addr,
                        stream,
                        state: ConnectionState::Opened,
                    },
                    Err(err) if err.kind() == ErrorKind::WouldBlock => continue,
                    Err(err) => panic!("Could Not Poll {err:?}"),
                };

                let id: u64;

                if let Some((index, slot)) = self
                    .connections
                    .iter_mut()
                    .enumerate()
                    .find(|(_, slot)| slot.is_none())
                {
                    conn.id = u64::try_from(index).unwrap();
                    id = conn.id;
                    *slot = Some(conn);
                } else {
                    conn.id = u64::try_from(self.connections.len()).unwrap();
                    id = conn.id;
                    self.connections.push(Some(conn));
                }

                self.add_connection(
                    self.connections
                        .get(usize::try_from(id).unwrap())
                        .unwrap()
                        .as_ref()
                        .unwrap()
                        .stream
                        .as_raw_fd(),
                    id,
                )
                .unwrap();
                let conn = self
                    .connections
                    .get_mut(usize::try_from(id).unwrap())
                    .expect("Index is not the id of the connection")
                    .as_ref()
                    .expect("id should be valid at this point");
                conn.stream
                    .set_nonblocking(true)
                    .expect("Unable to set new connection to non-blocking");
                connection_closure(conn.clone());
            } else if (event.events & libc::EPOLLIN as u32) != 0 {
                let id = event.u64;
                let conn = self
                    .connections
                    .get_mut(usize::try_from(id).unwrap())
                    .expect("Invalid Id for connection")
                    .as_mut()
                    .unwrap();
                conn.state = ConnectionState::Data;
                connection_closure(conn.clone());
            }
            if event.events & (libc::EPOLLHUP | libc::EPOLLRDHUP | libc::EPOLLERR) as u32 != 0 {
                let id = usize::try_from(event.u64).unwrap();
                match self
                    .connections
                    .get_mut(id)
                    .expect("Invalid Id for connection")
                    .as_mut()
                {
                    Some(conn) => {
                        conn.state = ConnectionState::Closed;
                    }
                    None => panic!("Connection doe not exsit"),
                }
                let conn_slot = self.connections.get(id).unwrap().as_ref();
                self.delete_connection(conn_slot.unwrap().stream.as_raw_fd())
                    .unwrap();

                let conn = self.connections.get_mut(id).unwrap().take().unwrap();
                connection_closure(conn);
            }
        }
    }
    fn wait(&self, timeout: i32) -> Result<Vec<epoll_event>, Error> {
        unsafe {
            let max_events = usize::try_from(self.max_events).unwrap();
            let layout = Layout::array::<epoll_event>(max_events).unwrap();
            let events = alloc::alloc(layout) as *mut epoll_event;

            //Blocks process
            let size = libc::epoll_wait(
                i32::try_from(self.epollfd).unwrap(),
                events,
                i32::try_from(self.max_events).unwrap(),
                timeout,
            );
            if size == -1 {
                return Err(Error::last_os_error());
            }
            let size = usize::try_from(size).unwrap();
            Ok(Vec::from_raw_parts(events, size, max_events))
        }
    }
    fn add_connection(&self, fd: c_int, id: u64) -> Result<(), Error> {
        unsafe {
            let mut event = epoll_event {
                u64: id,
                events: (libc::EPOLLIN | EPOLLET | EPOLLHUP | EPOLLRDHUP | EPOLLERR) as u32,
            };
            let ptr: *mut epoll_event = &mut event;
            let err = libc::epoll_ctl(
                i32::try_from(self.epollfd).unwrap(),
                libc::EPOLL_CTL_ADD,
                fd,
                ptr,
            );
            if err == -1 {
                return Err(Error::last_os_error());
            }
        }
        Ok(())
    }
    fn delete_connection(&self, fd: c_int) -> Result<(), Error> {
        unsafe {
            let err = libc::epoll_ctl(
                i32::try_from(self.epollfd).unwrap(),
                libc::EPOLL_CTL_DEL,
                fd,
                null_mut(),
            );
            if err == -1 {
                return Err(Error::last_os_error());
            }
        }
        Ok(())
    }
}
impl Drop for Poller {
    fn drop(&mut self) {
        unsafe {
            libc::close(i32::try_from(self.epollfd).unwrap());
        }
    }
}

//Make request to poller
#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn poller_test() {
        let listener = TcpListener::bind("localhost:8080").unwrap();
        let mut poller = Poller::new(20, &listener).expect("Did not create poller");

        let (mut closed, mut opened, mut data) = (false, false, false);

        thread::spawn(|| {
            for _ in 0..5 {
                let mut stream =
                    TcpStream::connect("localhost:8080").expect("Could not connect to test server");
                stream
                    .write_all("Blah".as_bytes())
                    .expect("Error sending response");
            }
        });

        for _ in 0..5 {
            poller.poll(-1, &listener, |mut conn| match conn.state {
                ConnectionState::Data => {
                    let mut buff: Vec<u8> = vec![0; 6];
                    println!("Got Data");
                    let size = conn.stream.read(&mut buff[0..]).unwrap();
                    buff.resize(size, 0);
                    let str = String::from_utf8(buff).unwrap();
                    println!("The data is {str}");
                    data = true;
                }
                ConnectionState::Closed => {
                    println!("Connection closed");
                    closed = true;
                }
                ConnectionState::Opened => {
                    println!("Connection opened");
                    opened = true;
                }
            });
        }
        assert!(opened, "Connection never opened");
        assert!(data, "Conection never recieved data from socket");
        assert!(closed, "Connection never closed");
    }
}
