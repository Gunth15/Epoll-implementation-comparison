use std::collections::HashMap;
use std::fs::File;
use std::io::{Error, Read, Write};
use std::sync::{Arc, Mutex};
use std::thread::sleep;
use std::time::Duration;
use std::{env, fs, thread};

use rust_epoll::watcher::Telementry;
use rust_epoll::{AsyncListener, polller::ConnectionState};

struct AppData {
    watcher: Mutex<Telementry>,
    connection_to_time: Mutex<HashMap<u64, usize>>,
}

fn main() {
    let app_data = Arc::new(AppData {
        watcher: Mutex::new(Telementry::default()),
        connection_to_time: Mutex::new(HashMap::new()),
    });
    let mut server: AsyncListener<3> = AsyncListener::new("127.0.0.1:8080", 50);

    let watcher_rec = Arc::clone(&app_data);
    let writer = thread::spawn(move || {
        let results_dir = env::current_dir()
            .unwrap()
            .parent()
            .unwrap()
            .with_file_name("results");

        fs::create_dir(&results_dir).unwrap_or_default();

        let mut csv = File::create_new(results_dir.with_file_name("rust.csv"))
            .or_else(|_| File::open(results_dir.with_file_name("rust.csv")))
            .unwrap();
        csv.write_all("total,finished,average,min,max\n".as_bytes())
            .unwrap();
        csv.flush().unwrap();

        loop {
            let (connections, finished, avrg, min, max) =
                watcher_rec.watcher.lock().unwrap().get_data();
            println!(
                "\x1b[2J\x1b[H\x1b[36mConnections: {connections}/sec\n Finished Connections: {finished}/sec\n Average Latency: {avrg}ms\n Lowest Latency: {min}ms\n Highest latency {max}ms\n\x1b[0m",
            );

            csv.write_all(format!("{connections},{finished},{avrg},{min},{max}\n").as_bytes())
                .unwrap();
            csv.flush().unwrap();

            sleep(Duration::from_secs(1));
        }
    });

    server.serve(-1, move |_, conn| {
        let shared = Arc::clone(&app_data);
        let mut conn = conn.lock().unwrap();
        match conn.state {
            ConnectionState::Opened => {
                let id = shared.watcher.lock().unwrap().watch_connection();
                let mut map = shared.connection_to_time.lock().unwrap();
                map.insert(conn.id, id);
                conn.stream.write_all("HI\n".as_bytes()).unwrap();
            }
            ConnectionState::Closed => {
                let mut map = shared.connection_to_time.lock().unwrap();
                let id = map.get(&conn.id).unwrap().to_owned();
                map.remove(&conn.id);
                shared.watcher.lock().unwrap().stop_watching_connection(id);
            }
            ConnectionState::Data => {
                let mut buff: [u8; 124] = [0; 124];
                loop {
                    let size = conn.stream.read(buff.as_mut_slice()).unwrap();
                    if size == 0 {
                        break;
                    }
                }
            }
        }
        Ok(())
    });
}
