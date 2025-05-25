use std::{
    process,
    sync::Mutex,
    time::{Duration, Instant},
};

pub struct Telementry {
    processing: Mutex<Vec<Option<Instant>>>,
    finished: Mutex<Vec<Option<Duration>>>,
}

impl Default for Telementry {
    fn default() -> Self {
        Self {
            processing: Mutex::new(Vec::new()),
            finished: Mutex::new(Vec::new()),
        }
    }
}
impl Telementry {
    pub fn watch_connection(&mut self) -> usize {
        let mut processing_list = self.processing.lock().unwrap();
        if let Some(id) = processing_list
            .iter_mut()
            .position(|timer_slot| timer_slot.is_none())
        {
            processing_list[id] = Some(Instant::now());
            id
        } else {
            processing_list.push(Some(Instant::now()));
            processing_list.len()
        }
    }
    pub fn stop_watching_connection(&mut self, id: usize) {
        let mut processing_list = self.processing.lock().unwrap();

        let timer = processing_list.get_mut(id);
        if timer.is_none() {
            println!("Lost Connection with id {id}");
            return;
        }

        let timer = timer.unwrap().take().unwrap();

        let mut finished_list = self.finished.lock().unwrap();

        if finished_list.len() > id {
            finished_list[id] = Some(timer.elapsed());
        } else {
            finished_list.push(Some(timer.elapsed()));
        }
    }
    pub fn get_data(&mut self) -> (u64, u64, f64, f64, f64) {
        let mut connections: u64 = 0;
        let mut finished_connections: u64 = 0;
        let mut total_lantency: u64 = 0;

        let mut finished_list = self.finished.lock().unwrap();
        let processing_list = self.processing.lock().unwrap();

        for timer in processing_list.iter() {
            if timer.is_some() {
                connections += 1;
            }
        }

        let mut min_duration: u64 = 0;
        let mut max_duration: u64 = 0;
        for (index, duration) in finished_list.iter_mut().enumerate() {
            if let Some(duration) = duration.take() {
                let duration = duration.as_secs();
                if index == 0 || duration < min_duration {
                    min_duration = duration;
                }
                if duration > max_duration {
                    max_duration = duration;
                }
                connections += 1;
                total_lantency += duration;
                finished_connections += 1
            }
        }
        let avrg_latency: f64 = if finished_connections != 0 {
            total_lantency as f64 / finished_connections as f64
        } else {
            0.0
        };
        (
            connections,
            finished_connections,
            avrg_latency,
            min_duration as f64,
            max_duration as f64,
        )
    }
}
