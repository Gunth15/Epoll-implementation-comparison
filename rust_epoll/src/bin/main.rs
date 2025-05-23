use rust_epoll::{AsyncListener, polller::ConnectionState};

fn main() {
    let mut server: AsyncListener<3> = AsyncListener::new("127.0.0.1:8080", 50);

    server.serve(-1, |_, conn| {
        match conn.state {
            ConnectionState::Opened => println!("Connecion Opened"),
            ConnectionState::Data => println!("Connection recived data"),
            ConnectionState::Closed => println!("Connection closed"),
        }
        Ok(())
    });
    println!("Cool");
}
