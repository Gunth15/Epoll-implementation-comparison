# Epoll-implementation-comparison

## Intro

This is an exercise in implementing a asynchronous Epoll server in newer low level languages, Zig and Rust.
I have been fascinated with asynchronous control flows for quite a while now but most of my endeavors have not been fruitful, so I decided to make an TCP server with event driven architecture to get a deeper understanding of one ways to achieve asynchrony.
<br/>
I also started recently learning Zig because I liked the idea of the language being the build system and the interop with C. I have been thoroughly impressed with the tooling around the language and the semantics itself. I had to know if this was just a honey moon phase or did I actually enjoy the language, so I decided to compare it to a language which I respect very much, Rust.
<br/>
In my mind Rust, achievements to be memory safe have been a overall force of good, and I greatly admire the language as a whole.
However, my last project in Rust really burned me out for a while.
I'm hoping that it was just the contents of that project, and not the language itself that caused it which I aim to figure out here.
<br/>
For personal projects where I often want use a C library or just don't have a lot of time, I honestly think the tooling of Zig makes memory very manageable(with obvious caveats that can be found through testing).

## Overall Design

The goal of this projects is to measure the response time from connection to server to closing of the request.
Along with that, I will monitor the memory usage of my implementation in Zig vs the memory efficiency of Rust.
This test will not be very practical, but I get see where my memory efficiency compares to Rust's borrow checker principals.
I will try to use all advantages to the each language when I can.

### Three Main Parts

1. Watcher: connections subscribe to the watcher and unsubscribe when the connection is closed. This how connections latency will be determined on the server side.
2. Thread Pool: This is where I believe Rust will shine. Concurrency problems are not something I usually deal with, but I thought it be fun to experiment. Rust type system would most likely help me avoid pitfalls.
3. Poller: An abstraction over the Epoll API for the TCP based connections I'll be using

## Zig implementation

It was very easy and enjoyable to write test in Zig. Especially since test is just a keyword.

### Mistakes

There was a lot of mistakes I made. Some of the most notable was not using `* const` when I should have and not utilizing Zig generics to their full potential until I really got the hang of them while I was implementing my thread pool and trying to avoid using dynamic dispatch.
One mistake that hurt my implementation greatly was the leveraging the standard library Server object when I should have just rolled my own version. Because of this, I could not accept request in edge-triggered mode because if the request failed in anyway, the poller would remain blocked.

### Summary

I'm very happy with the Zig implementation overall. I was able to express undefined behavior and unreachable states very easy which made it easy for prototyping. More memory efficient than expected as well.
The idea that "everything is a struct" was hard to wrap my head around at first, but when I cam to understand it, my abstractions became easier to make.
The language has a strong belief in using as little memory as possible, and I watch some of the talks by Andre Kelly witch influenced my designs.
Zig looks ugly at first, but when you actually start programming, it's really intuitive. Probably some of the best language syntax I have ever seen(which is not saying much).
Can't wait to program with it more.
The focus on passing allocators is also a huge bonus when it come to dynamic memory management.
In the future I want to explore Zig's build system.

## Rust implementation

One of the first concerns I had with rust implementation from my past experiences with rust was "do I need a dependency?". Unlike Zig, rust does not have a built-in C compiler nor is it as friendly to C code. I did not want to waste my time making my own interface, I decided to use the libC crate because it is maintained by the rust foundation, so It's as close as I'm willing to get as comparison.
<br/>
For the rust design of the thread pool, I decided to use closures because it is a feature of the language that zig does not have, and I thought it would make my implementation better than my zig version which has one function handle and the user manages the variations in types.
The closures did make the event loop look even better, so I will say this is a major plus for closures in rust.

### Unsafe Rust

One of the most enjoyable parts for me was unsafe rust. I think it's really well made and integrates with the rest of Rust beautifully.
Using libc within unsafe bounds was very easy and the memory strategy of implicitly laying out the memory felt natural to use when making things safe to the rest of rust.

### Fearless Concurrency

The thing I really like about rust was fearless concurrency, however it is not what I though it was.
As expected, the borrow checker works great to make mutexes are properly locked and unlocked, but there is are sometimes where I wish I had more manual control of unlocking the mutex.
Some may argue I should avoid those situations entirely, but I disagree.
Luckily a work around was to declare another scope most of the time.
The hardest part of my Rust implementation by far was concurrency because dealing with `Arc`, `Mutex`, and traits in rust is not enjoyable for me and feels like I'm writing a mathematical proof.
However I do see the value in proximity of critical infrastructure software.

### Testing and Traits

The best time I had programming in rust is using rust beautiful utility functions like the `take()` method.
One trait that I was glad to have was the `Drop` trait which allowed me to automatically close the epoll server when it went out of scope(similar to defer, but less manual)

The bad part about traits was figuring out which ones I needed when doing concurrency.

Testing in rust was just as good as I remembered; not to say testing in zig was bad, but it requires a lot more setup to make a full test suite. After a lot of reflection, I can confidently say Cargo is one of the best batteries included build systems out there.

## Go runner

The go runner simply spins up a bunch of go routines and measure time from connection to close(round-trip time).
Once again go proves to be a good time lol.

## Conclusion

I wrote the Zig version first as I plan to do more with that after I finish working on another side project(stay tuned).
With that in mind, it was incredibly simple to rewrite a lot of the functionality in rust showing a great overlap between both of these cool languages.

### Performance

The performance does not actually matter very much because most of the time both programs will be limited by I/O and I did this over localhost which has it's own optimizations.
<br/>
With that in mind, the rust version version served many more request at 10 threads and also served them faster, but it also had a high variance which means there is probably a lot of instability within my implementation which was also evident by all the dead time while running.
As expected, the Rust version used more memory because I used a lot more dynamic allocations; Although it was very efficient with the memory it did use starting at 2.1Mib and never going over 2.25.
<br/>
The Zig version had a more reasonable variance showing greater consistency and also used way less memory with a low of 284Kib and a high of 1.02Mib. As stated before, these implementations would probably have similar memory usage if I forced the same restrictions on the Rust server.
<br/>
Both had similar CPU usage of around 30%

Thank You for taking the time for looking at my repo. Please leave feed back if meaningful.
