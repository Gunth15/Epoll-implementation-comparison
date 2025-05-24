package main

import (
	"fmt"
	"net"
	"time"
)

const (
	ClearNCursor = "\x1b[2J\x1b[H"
	Yellow       = "\x1b[33m"
	White        = "\x1b[0m"
	threads      = 1000
)

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
		conn.SetDeadline(time.Now().Add(5 * time.Second))

		_, err = conn.Write([]byte(text))
		if err != nil {
			// fmt.Printf("Error: %s", err)
			conn.Close()
			continue
		}

		buff := make([]byte, 1024)
		_, err = conn.Read(buff)
		if err != nil {
			// fmt.Printf("Error: %s", err)
			conn.Close()
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
	for {
		processing := 0
		finished := 0
		var average float64
		var max_round int64 = 0
		var min_round int64 = 0
		for index, channel := range channels {
			select {
			case duration := <-channel:
				{
					stop_time := duration.Milliseconds()
					average += float64(stop_time)
					finished += 1

					if stop_time > max_round {
						max_round = stop_time
					}
					if index == 0 || stop_time < min_round {
						min_round = stop_time
					}
				}

			default:
				processing += 1
			}
		}

		if finished != 0 {
			average = average / float64(finished)
		} else {
			average = 0
		}

		fmt.Printf(ClearNCursor+Yellow+`Connections: %d/sec
 Average Roundtrip time: %f.3ms
 Max Roundtrip: %dms
 Min Roundtrip %dms
`+White, finished, average, max_round, min_round)
		time.Sleep(1 * time.Second)
	}
}
