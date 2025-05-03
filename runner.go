package main

import (
	"fmt"
	"net"
	"time"
)

const threads = 1000

const text = `
Lorem ipsum dolor sit amet consectetur adipiscing elit.
Quisque faucibus ex sapien vitae pellentesque sem placerat.
In id cursus mi pretium tellus duis convallis.
Tempus leo eu aenean sed diam urna tempor. 
Pulvinar vivamus fringilla lacus nec metus bibendum egestas. 
Iaculis massa nisl malesuada lacinia integer nunc posuere.
Ut hendrerit semper vel class aptent taciti sociosqu.
Ad litora torquent per conubia nostra inceptos himenaeos.

Lorem ipsum dolor sit amet consectetur adipiscing elit.
Quisque faucibus ex sapien vitae pellentesque sem placerat.
In id cursus mi pretium tellus duis convallis.
Tempus leo eu aenean sed diam urna tempor. 
Pulvinar vivamus fringilla lacus nec metus bibendum egestas. 
Iaculis massa nisl malesuada lacinia integer nunc posuere.
Ut hendrerit semper vel class aptent taciti sociosqu.
Ad litora torquent per conubia nostra inceptos himenaeos.

Lorem ipsum dolor sit amet consectetur adipiscing elit.
Quisque faucibus ex sapien vitae pellentesque sem placerat.
In id cursus mi pretium tellus duis convallis.
Tempus leo eu aenean sed diam urna tempor. 
Pulvinar vivamus fringilla lacus nec metus bibendum egestas. 
Iaculis massa nisl malesuada lacinia integer nunc posuere.
Ut hendrerit semper vel class aptent taciti sociosqu.
Ad litora torquent per conubia nostra inceptos himenaeos.

Lorem ipsum dolor sit amet consectetur adipiscing elit.
Quisque faucibus ex sapien vitae pellentesque sem placerat.
In id cursus mi pretium tellus duis convallis.
Tempus leo eu aenean sed diam urna tempor. 
Pulvinar vivamus fringilla lacus nec metus bibendum egestas. 
Iaculis massa nisl malesuada lacinia integer nunc posuere.
Ut hendrerit semper vel class aptent taciti sociosqu.
Ad litora torquent per conubia nostra inceptos himenaeos.

Lorem ipsum dolor sit amet consectetur adipiscing elit.
Quisque faucibus ex sapien vitae pellentesque sem placerat.
In id cursus mi pretium tellus duis convallis.
Tempus leo eu aenean sed diam urna tempor. 
Pulvinar vivamus fringilla lacus nec metus bibendum egestas. 
Iaculis massa nisl malesuada lacinia integer nunc posuere.
Ut hendrerit semper vel class aptent taciti sociosqu.
Ad litora torquent per conubia nostra inceptos himenaeos.
`

func run_request(sender chan<- time.Duration) {
	for {
		timer := time.Now()
		conn, err := net.Dial("tcp4", "localhost:8080")
		if err != nil {
			fmt.Printf("Error: %s", err)
			continue
		}

		_, err = conn.Write([]byte(text))
		if err != nil {
			fmt.Printf("Error: %s", err)
			continue
		}

		buff := make([]byte, 1024)
		_, err = conn.Read(buff)
		if err != nil {
			fmt.Printf("Error: %s", err)
			continue
		}
		sender <- time.Since(timer)
		conn.Close()
	}
}

func main() {
	channels := make([]chan time.Duration, threads)

	for i := range threads {
		channel := make(chan time.Duration, 1)
		go run_request(channel)
		channels[i] = channel
	}

	// TODO: maybe connection drop rate aswell
	// total connections
	// total connections that finished this time interval
	// Average roundtrip time
	// Max roundtrip time
	// Min roundtrip time
	for {
		processing := 0
		finished := 0
		var average int64
		var max_round int64 = 0
		var min_round int64 = 1_000_000_000
		for _, channel := range channels {
			select {
			case duration := <-channel:
				{
					stop_time := duration.Milliseconds()
					average += stop_time
					finished += 1

					if stop_time > max_round {
						max_round = stop_time
					}
					if stop_time < min_round {
						min_round = stop_time
					}
				}

			default:
				processing += 1
			}
		}

		if finished != 0 {
			average = average / int64(finished)
		} else {
			average = 0
		}

		fmt.Printf("\x1b[2J\x1b[H\x1b[33m"+`Connections: %d/sec
 Finished Connections:%d
 Processing Connections:%dms
 Average Roundtrip time: %dms
 Max Roundtrip: %dms
 Min Roundtrip %dms
`+"\x1b[0m", threads, finished, processing, average, max_round, min_round)
		time.Sleep(1 * time.Second)
	}
}
