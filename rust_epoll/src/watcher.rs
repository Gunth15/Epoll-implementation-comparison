use std::{
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
    pub fn watch_connection() {}
    pub fn stop_watching_connection() {}
    pub fn get_data() {}
}
