use rust_epoll::AsyncListener;

fn main() {
    let mut server: AsyncListener<3> = AsyncListener::new("127.0.0.1:8080", 50);

    server.serve(-1, |id, _conn| {
        println!("Got connection {id}");
        Ok(())
    });
    println!("Cool");
}
