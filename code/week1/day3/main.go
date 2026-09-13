package main

import (
	"fmt"
	"log"
	"net/http"
)

func handler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "<h1>Hello DevOps</h1>")
	log.Println("request accepted")
}

func main() {
	http.HandleFunc("/", handler)

	log.Println("An simple http service running on :8080")
	http.ListenAndServe(":8080", nil)
}
