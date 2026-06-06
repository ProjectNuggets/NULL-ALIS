package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Metrics collectors for the browser control plane (spec §9 observability).
var (
	metricSessionsActive = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "browser_sessions_active", Help: "Currently registered browser sessions.",
	})
	metricSessionCreate = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "browser_session_create_total", Help: "Session create attempts by result.",
	}, []string{"result"})
	metricCreateDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name: "browser_session_create_seconds", Help: "Session create (pod provision) latency.",
		Buckets: []float64{0.5, 1, 2, 5, 10, 20, 40},
	})
	metricExec = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "browser_exec_total", Help: "Exec calls by result.",
	}, []string{"result"})
	metricPersistFailures = promauto.NewCounter(prometheus.CounterOpts{
		Name: "browser_persist_failures_total", Help: "Vault persist failures on session close.",
	})
)
