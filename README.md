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

### Mistakes

There was a lot of mistakes I made. Some of the most notable was not using `* const` when I should have and not utilizing Zig generics to their full potential until I really got the hang of them while I was implementing my thread pool and trying to avoid using dynamic dispatch.
One mistake that hurt my implementation greatly was the leveraging the standard library Server object when I should have just rolled my own version. Because of this, I could not accept request in edge-triggered mode because if the request failed in anyway, the poller would remain blocked.

### Summary

I'm very happy with the Zig implementation overall. I was able to express undefined behavior and unreachable states very easy which made it easy for prototyping. More memory efficient than expected as well.
The idea that "everything is a struct" was hard to wrap my head around at first, but when I cam to understand it, my abstractions became easier to make.
The language has a strong belief in using as little memory as possible, and I watch some of the talks by Andre Kelly witch influenced my designs.
Zig looks ugly at first, but when you actually start programming, it's really intuitive.
Can't wait to program with it more.
The focus on passing allocators is also a huge bonus when it come to dynamic memory management.
IN the future I want to explore Zig's build system.

## Rust implementation

## Go runner

Thank You for taking the time for looking at my repo. Please leave feed back if meaningful.

## Conclusion

The performance does not actually matter very much because most of the time both programs will be limited by I/O.
