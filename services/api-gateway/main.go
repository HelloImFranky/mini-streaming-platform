package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
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
)

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

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		requestID := r.Header.Get("X-Request-ID")
		if requestID == "" {
			requestID = uuid.New().String()
		}
		r.Header.Set("X-Request-ID", requestID)
		w.Header().Set("X-Request-ID", requestID)

		rw := newResponseWriter(w)
		next.ServeHTTP(rw, r)

		duration := time.Since(start).Seconds()
		path := r.URL.Path
		status := strconv.Itoa(rw.statusCode)

		httpRequestsTotal.WithLabelValues(r.Method, path, status).Inc()
		httpRequestDuration.WithLabelValues(r.Method, path).Observe(duration)

		log.Printf("method=%s path=%s status=%d duration=%.4fs request_id=%s",
			r.Method, path, rw.statusCode, duration, requestID)
	})
}

func newReverseProxy(target string) *httputil.ReverseProxy {
	targetURL, err := url.Parse(target)
	if err != nil {
		log.Fatalf("failed to parse upstream URL %s: %v", target, err)
	}
	proxy := httputil.NewSingleHostReverseProxy(targetURL)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("proxy error for %s: %v", r.URL.Path, err)
		w.WriteHeader(http.StatusBadGateway)
		if err := json.NewEncoder(w).Encode(map[string]string{
			"error":      "upstream service unavailable",
			"path":       r.URL.Path,
			"request_id": r.Header.Get("X-Request-ID"),
		}); err != nil {
			log.Printf("failed to encode error response: %v", err)
		}
	}
	return proxy
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]string{
		"status":  "ok",
		"service": "api-gateway",
	}); err != nil {
		log.Printf("failed to encode health response: %v", err)
	}
}

func main() {
	serviceInfo.WithLabelValues("1.0.0", "api-gateway").Set(1)

	userServiceURL := getEnv("USER_SERVICE_URL", "http://user-service:8081")
	contentServiceURL := getEnv("CONTENT_SERVICE_URL", "http://content-service:8082")
	playbackServiceURL := getEnv("PLAYBACK_SERVICE_URL", "http://playback-service:8083")

	userProxy := newReverseProxy(userServiceURL)
	contentProxy := newReverseProxy(contentServiceURL)
	playbackProxy := newReverseProxy(playbackServiceURL)

	mux := http.NewServeMux()

	mux.HandleFunc("/health", healthHandler)
	mux.Handle("/metrics", promhttp.Handler())

	mux.HandleFunc("/users/", func(w http.ResponseWriter, r *http.Request) {
		userProxy.ServeHTTP(w, r)
	})
	mux.HandleFunc("/users", func(w http.ResponseWriter, r *http.Request) {
		userProxy.ServeHTTP(w, r)
	})

	mux.HandleFunc("/content/", func(w http.ResponseWriter, r *http.Request) {
		contentProxy.ServeHTTP(w, r)
	})
	mux.HandleFunc("/content", func(w http.ResponseWriter, r *http.Request) {
		contentProxy.ServeHTTP(w, r)
	})

	mux.HandleFunc("/playback/", func(w http.ResponseWriter, r *http.Request) {
		playbackProxy.ServeHTTP(w, r)
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		if err := json.NewEncoder(w).Encode(map[string]string{"error": "route not found"}); err != nil {
			log.Printf("failed to encode 404 response: %v", err)
		}
	})

	handler := loggingMiddleware(mux)

	port := getEnv("PORT", "8080")
	addr := fmt.Sprintf(":%s", port)
	log.Printf("api-gateway starting on %s", addr)
	log.Printf("upstream: users=%s content=%s playback=%s",
		userServiceURL, contentServiceURL, playbackServiceURL)

	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}
