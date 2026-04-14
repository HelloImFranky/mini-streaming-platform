package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests",
		},
		[]string{"method", "path", "status"},
	)

	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request duration in seconds",
			Buckets: []float64{0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5},
		},
		[]string{"method", "path"},
	)

	serviceInfo = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "service_info",
			Help: "Service information",
		},
		[]string{"version", "service_name"},
	)

	activeSessions = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "active_sessions",
		Help: "Number of currently active playback sessions",
	})
)

type Session struct {
	SessionID string    `json:"session_id"`
	UserID    string    `json:"user_id"`
	ContentID string    `json:"content_id"`
	Status    string    `json:"status"`
	Bitrate   string    `json:"bitrate"`
	StartedAt time.Time `json:"started_at"`
}

type SessionStore struct {
	mu       sync.RWMutex
	sessions map[string]*Session
}

func (s *SessionStore) Add(sess *Session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[sess.SessionID] = sess
	activeSessions.Inc()
}

func (s *SessionStore) Get(id string) (*Session, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sess, ok := s.sessions[id]
	return sess, ok
}

var store = &SessionStore{sessions: make(map[string]*Session)}

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func newResponseWriter(w http.ResponseWriter) *responseWriter {
	return &responseWriter{w, http.StatusOK}
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

var latencySpikePercent int

func init() {
	pct := os.Getenv("LATENCY_SPIKE_PCT")
	if pct == "" {
		latencySpikePercent = 5
		return
	}
	v, err := strconv.Atoi(pct)
	if err != nil || v < 0 || v > 100 {
		latencySpikePercent = 5
		return
	}
	latencySpikePercent = v
}

func maybeInjectLatency() {
	if rand.Intn(100) < latencySpikePercent {
		spike := 500 + rand.Intn(1500)
		log.Printf("injecting latency spike: %dms", spike)
		time.Sleep(time.Duration(spike) * time.Millisecond)
	}
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		requestID := r.Header.Get("X-Request-ID")
		if requestID == "" {
			requestID = uuid.New().String()
		}
		w.Header().Set("X-Request-ID", requestID)

		rw := newResponseWriter(w)
		next.ServeHTTP(rw, r)

		duration := time.Since(start).Seconds()
		status := strconv.Itoa(rw.statusCode)

		httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, status).Inc()
		httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)

		log.Printf("method=%s path=%s status=%d duration=%.4fs request_id=%s",
			r.Method, r.URL.Path, rw.statusCode, duration, requestID)
	})
}

type StartRequest struct {
	UserID    string `json:"user_id"`
	ContentID string `json:"content_id"`
}

func startPlaybackHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	maybeInjectLatency()

	var req StartRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "invalid request body"})
		return
	}
	if req.UserID == "" {
		req.UserID = "anonymous"
	}
	if req.ContentID == "" {
		req.ContentID = "content-001"
	}

	bitrates := []string{"4K", "1080p", "720p", "480p"}
	bitrate := bitrates[rand.Intn(len(bitrates))]

	sess := &Session{
		SessionID: uuid.New().String(),
		UserID:    req.UserID,
		ContentID: req.ContentID,
		Status:    "streaming",
		Bitrate:   bitrate,
		StartedAt: time.Now().UTC(),
	}
	store.Add(sess)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(sess)
}

func statusPlaybackHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	maybeInjectLatency()

	parts := strings.Split(r.URL.Path, "/")
	sessionID := parts[len(parts)-1]

	sess, ok := store.Get(sessionID)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(map[string]string{"error": "session not found"})
		return
	}

	elapsed := int(time.Since(sess.StartedAt).Seconds())
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"session_id":      sess.SessionID,
		"user_id":         sess.UserID,
		"content_id":      sess.ContentID,
		"status":          sess.Status,
		"bitrate":         sess.Bitrate,
		"elapsed_seconds": elapsed,
		"started_at":      sess.StartedAt,
	})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "ok",
		"service": "playback-service",
	})
}

func main() {
	serviceInfo.WithLabelValues("1.0.0", "playback-service").Set(1)

	log.Printf("playback-service starting — latency_spike_pct=%d%%", latencySpikePercent)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/playback/start", startPlaybackHandler)
	mux.HandleFunc("/playback/status/", statusPlaybackHandler)

	port := getEnv("PORT", "8083")
	addr := fmt.Sprintf(":%s", port)
	log.Printf("playback-service listening on %s", addr)

	if err := http.ListenAndServe(addr, loggingMiddleware(mux)); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}
