use std::{
    array,
    collections::VecDeque,
    error::Error,
    fmt::Debug,
    sync::{Arc, Condvar, Mutex},
    thread::JoinHandle,
};

#[derive(Debug)]
pub enum RingBufferError {
    BuffferFull,
    BuffferEmpty,
}

#[derive(Debug, Clone)]
struct RingBuffer<T, const S: usize> {
    head: Option<usize>,
    tail: Option<usize>,
    data: [Option<T>; S],
}

impl<T: Clone, const S: usize> Default for RingBuffer<T, S> {
    fn default() -> Self {
        Self {
            head: None,
            tail: None,
            data: array::from_fn(|_| None),
        }
    }
}
impl<T: Clone, const S: usize> RingBuffer<T, S> {
    pub fn enqueue(&mut self, payload: T) -> Result<(), RingBufferError> {
        if self.is_full() {
            return Err(RingBufferError::BuffferFull);
        }
        let next = if self.tail.is_some() {
            (self.tail.unwrap() + 1) % self.data.len()
        } else {
            0
        };
        self.data[next] = Some(payload);
        self.tail = Some(next);
        if self.is_empty() {
            self.head = self.tail;
        }
        Ok(())
    }
    pub fn dequeue(&mut self) -> Result<T, RingBufferError> {
        if self.is_empty() {
            return Err(RingBufferError::BuffferEmpty);
        }
        let temp = self.data[self.head.unwrap()].take().to_owned().unwrap();

        if self.head == self.tail {
            self.head = None;
            self.tail = None;
        } else {
            self.head = Some((self.head.unwrap() + 1) % self.data.len());
        }

        Ok(temp)
    }
    pub fn steal(&mut self) -> Result<T, RingBufferError> {
        if self.is_empty() {
            return Err(RingBufferError::BuffferEmpty);
        }

        let temp = self.data[self.tail.unwrap()].take().to_owned().unwrap();
        if self.head == self.tail {
            self.head = None;
            self.tail = None;
        } else {
            self.tail = Some((self.tail.unwrap() + (self.data.len() - 1)) % self.data.len());
        }

        Ok(temp)
    }
    pub fn is_empty(&self) -> bool {
        self.head.is_none()
    }
    pub fn is_full(&self) -> bool {
        (self.head.is_some() && self.tail.is_some())
            && ((self.tail.unwrap() + 1) % self.data.len() == self.head.unwrap())
    }
}

#[derive(Debug, Clone, Copy)]
enum ThreadStatus {
    Waiting,
    Abort,
    Working,
}

pub type ThreadErr = Box<dyn 'static + Error + Send>;
pub type ThreadFunc = Arc<dyn Fn(usize) -> Result<(), ThreadErr> + Send + Sync>;

pub struct ThreadPool<const S: usize> {
    global_queue: Mutex<VecDeque<ThreadFunc>>,
    local_queues: [Mutex<RingBuffer<ThreadFunc, S>>; S],
    threads: Mutex<Option<[JoinHandle<()>; S]>>,
    thread_status: [Mutex<ThreadStatus>; S],
    thread_cond: Condvar,
}
impl<const S: usize> ThreadPool<S> {
    pub fn new() -> Self {
        Self {
            global_queue: Mutex::new(VecDeque::new()),
            local_queues: std::array::from_fn(|_| Mutex::new(RingBuffer::default())),
            threads: Mutex::new(None),
            thread_status: std::array::from_fn(|_| Mutex::new(ThreadStatus::Waiting)),
            thread_cond: Condvar::new(),
        }
    }

    pub fn dispatch(self: Arc<Self>) {
        *self.threads.lock().unwrap() = Some(std::array::from_fn(|index| {
            let ctxt = Arc::clone(&self);
            std::thread::spawn(move || {
                let id = index;
                let mut timeout: u32 = 0;
                let mut counter: u32 = 0;
                let local = &ctxt.local_queues[id];
                loop {
                    let mut status = ctxt.thread_status[id].lock().unwrap();
                    match *status {
                        ThreadStatus::Waiting => {
                            let mut t_stat = ctxt.thread_cond.wait(status).unwrap();
                            *t_stat = match *t_stat {
                                ThreadStatus::Abort => ThreadStatus::Abort,
                                _ => ThreadStatus::Working,
                            };
                        }
                        ThreadStatus::Working => {
                            if counter % 61 == 0 {
                                let mut queue = ctxt.global_queue.lock().unwrap();
                                let mut lq = local.lock().unwrap();
                                if !queue.is_empty() && !lq.is_full() {
                                    let task = queue
                                        .pop_front()
                                        .expect("global queue should not be empty");
                                    lq.enqueue(task).expect("local queue should not be full");
                                }
                            }
                            counter += 1;
                            {
                                let mut lq = local.lock().unwrap();
                                if !lq.is_empty() {
                                    let task =
                                        lq.dequeue().expect("Local queue should not be empty");
                                    timeout = 0;
                                    if let Err(err) = task(id) {
                                        println!("Error executing task {err}");
                                    };
                                    continue;
                                }
                            }
                            for t_id in 0..ctxt.local_queues.len() {
                                if t_id == id {
                                    continue;
                                };
                                if t_id < id {
                                    let mut tq = ctxt.local_queues[t_id].lock().unwrap();
                                    let mut local = local.lock().unwrap();
                                    if !local.is_full() && !tq.is_empty() {
                                        let task = tq
                                            .steal()
                                            .expect("foreign thread queue should not be empty");
                                        local.enqueue(task).expect("should not be full");
                                    }
                                } else {
                                    let mut local = local.lock().unwrap();
                                    let mut tq = ctxt.local_queues[t_id].lock().unwrap();
                                    if !local.is_full() && !tq.is_empty() {
                                        let task = tq
                                            .steal()
                                            .expect("foreign thread queue should not be empty");
                                        local.enqueue(task).expect("should not be full");
                                    }
                                }
                            }
                            timeout += 1;
                            if timeout == 100 {
                                *status = ThreadStatus::Waiting;
                            }
                        }
                        ThreadStatus::Abort => {
                            println!("Shutting Down");
                            break;
                        }
                    }
                }
            })
        }));
    }

    pub fn wait(&self) {
        let threads = self.threads.lock().unwrap().take().unwrap();
        for thread in threads {
            thread.join().unwrap();
        }
    }
    pub fn enqueue(&self, task: ThreadFunc) {
        let mut queue = self.global_queue.lock().unwrap();
        queue.push_back(task);
        self.thread_cond.notify_all();
    }
}

#[cfg(test)]
mod test {
    use std::{thread::sleep, time::Duration};

    use super::*;

    #[test]
    fn ring_buffer_test() {
        let mut ring_buff: RingBuffer<u32, 3> = RingBuffer::default();
        ring_buff.enqueue(3).unwrap();
        println!("DATA: {:?}", ring_buff.data);
        ring_buff.enqueue(2).unwrap();
        println!("DATA: {:?}", ring_buff.data);
        ring_buff.enqueue(1).unwrap();
        println!("DATA: {:?}", ring_buff.data);
        assert!(ring_buff.is_full());
        ring_buff.enqueue(1).expect_err("Did enqued past limit");
        println!("DATA: {:?}", ring_buff.data);

        assert_eq!(3, ring_buff.dequeue().unwrap());
        println!("DATA: {:?}", ring_buff.data);
        assert_eq!(2, ring_buff.dequeue().unwrap());
        println!("DATA: {:?}", ring_buff.data);
        assert_eq!(1, ring_buff.dequeue().unwrap());
        println!("DATA: {:?}", ring_buff.data);
        assert!(ring_buff.is_empty());

        ring_buff.enqueue(1).unwrap();
        assert_eq!(1, ring_buff.dequeue().unwrap());
        println!("DATA: {:?}", ring_buff.data);
        ring_buff.enqueue(2).unwrap();
        assert_eq!(2, ring_buff.dequeue().unwrap());
        println!("DATA: {:?}", ring_buff.data);
        ring_buff.enqueue(3).unwrap();
        assert_eq!(3, ring_buff.dequeue().unwrap());
        println!("DATA: {:?}", ring_buff.data);

        ring_buff.enqueue(2).unwrap();
        println!("DATA: {:?}", ring_buff.data);
        ring_buff.enqueue(3).unwrap();
        println!("DATA: {:?}", ring_buff.data);
        assert_eq!(3, ring_buff.steal().unwrap());
        println!("DATA: {:?}", ring_buff.data);
        assert_eq!(2, ring_buff.steal().unwrap());
        println!("DATA: {:?}", ring_buff.data);
    }

    #[test]
    fn thread_pool() {
        println!("Thread pool test");
        let pool: Arc<ThreadPool<3>> = Arc::new(ThreadPool::new());
        let dispatch = Arc::clone(&pool);
        dispatch.dispatch();

        for i in 0..500 {
            println!("Queueing task");
            pool.enqueue(Arc::new(move |_| {
                println!("Task {i}");
                assert_eq!(i, i);
                Ok(())
            }));
        }
        println!("Started Queueing");
        sleep(Duration::from_secs(1));
        assert!(pool.global_queue.lock().unwrap().is_empty());
        for _ in 0..3 {
            let status = Arc::clone(&pool);
            println!("Queueing task");
            pool.enqueue(Arc::new(move |id| {
                let mut status = status.thread_status[id].lock().unwrap();
                *status = ThreadStatus::Abort;

                Ok(())
            }))
        }
        //pool.wait();
    }
}
