#[derive(Debug)]
pub enum RingBufferError {
    BuffferFull,
    BuffferEmpty,
}

#[derive(Debug)]
pub struct RingBuffer<T, const S: usize> {
    head: Option<usize>,
    tail: Option<usize>,
    data: [Option<T>; S],
}

impl<T: Copy, const S: usize> Default for RingBuffer<T, S> {
    fn default() -> Self {
        Self {
            head: None,
            tail: None,
            data: [None; S],
        }
    }
}
impl<T: Copy, const S: usize> RingBuffer<T, S> {
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
        let temp = self.data[self.head.unwrap()].unwrap();
        self.data[self.head.unwrap()] = None;

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

        let temp = self.data[self.tail.unwrap()].unwrap();

        self.data[self.tail.unwrap()] = None;
        if self.head == self.tail {
            self.head = None;
            self.tail = None;
        } else {
            self.tail = Some((self.tail.unwrap() + (self.data.len() - 1)) % self.data.len());
        }

        Ok(temp)
    }
    fn is_empty(&self) -> bool {
        self.head.is_none()
    }
    fn is_full(&self) -> bool {
        (self.head.is_some() && self.tail.is_some())
            && ((self.tail.unwrap() + 1) % self.data.len() == self.head.unwrap())
    }
}

#[cfg(test)]
mod test {
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
        ring_buff.enqueue(1).expect_err("Did enqued past limit");
        println!("DATA: {:?}", ring_buff.data);

        assert_eq!(3, ring_buff.dequeue().unwrap());
        println!("DATA: {:?}", ring_buff.data);
        assert_eq!(2, ring_buff.dequeue().unwrap());
        println!("DATA: {:?}", ring_buff.data);
        assert_eq!(1, ring_buff.dequeue().unwrap());
        println!("DATA: {:?}", ring_buff.data);

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
}
