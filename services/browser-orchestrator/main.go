package main

import (
	"log"
	"net/http"
)

func main() {
	srv := NewServer(nil)
	log.Fatal(http.ListenAndServe(":8080", srv.Handler()))
}
