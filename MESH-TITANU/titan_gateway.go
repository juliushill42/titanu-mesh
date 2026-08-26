// TitanU API Gateway
// Single public entrypoint for the WeCanMesh sovereign AI cluster.
// Load balances across registered mesh nodes, exposes OpenAI-compatible API,
// enforces API-key auth, tracks node health, fails over automatically.
//
// Build:   go build -o titan-gateway gateway.go
// Run:     TITAN_GATEWAY_KEY=secret ./titan-gateway
// Default listen: 0.0.0.0:9000

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// ---------------------------------------------------------------------------
// CONFIG
// ---------------------------------------------------------------------------

var (
	listenAddr     = envOr("TITAN_GATEWAY_ADDR", "0.0.0.0:9000")
	gatewayKey     = envOr("TITAN_GATEWAY_KEY", "")
	nodeFile       = envOr("TITAN_NODES_FILE", "nodes.json")
	healthPeriod   = 10 * time.Second
	requestTimeout = 120 * time.Second
)

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ---------------------------------------------------------------------------
// NODE REGISTRY
// ---------------------------------------------------------------------------

type Node struct {
	Hostname string   `json:"hostname"`
	MeshIP   string   `json:"mesh_ip"`
	ShimPort int      `json:"shim_port"`
	Role     string   `json:"role"`
	Models   []string `json:"models"`

	healthy   atomic.Bool
	inflight  atomic.Int64
	totalReqs atomic.Int64
	failures  atomic.Int64
	lastCheck atomic.Int64 // unix seconds
}

func (n *Node) URL() string {
	return fmt.Sprintf("http://%s:%d", n.MeshIP, n.ShimPort)
}

func (n *Node) ServesModel(model string) bool {
	if model == "" {
		return true
	}
	for _, m := range n.Models {
		if m == model {
			return true
		}
	}
	return false
}

type Registry struct {
	mu    sync.RWMutex
	nodes []*Node
}

func NewRegistry() *Registry {
	return &Registry{nodes: []*Node{}}
}

func (r *Registry) Load(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var raw []struct {
		Hostname string   `json:"hostname"`
		MeshIP   string   `json:"mesh_ip"`
		ShimPort int      `json:"shim_port"`
		Role     string   `json:"role"`
		Models   []string `json:"models"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.nodes = nil
	for _, n := range raw {
		node := &Node{Hostname: n.Hostname, MeshIP: n.MeshIP, ShimPort: n.ShimPort, Role: n.Role, Models: n.Models}
		node.healthy.Store(true)
		r.nodes = append(r.nodes, node)
	}
	return nil
}

func (r *Registry) All() []*Node {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]*Node, len(r.nodes))
	copy(out, r.nodes)
	return out
}

// Pick the least-loaded healthy node that can serve the requested model.
func (r *Registry) PickNode(model string) (*Node, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	var best *Node
	var bestLoad int64 = -1

	for _, n := range r.nodes {
		if !n.healthy.Load() {
			continue
		}
		if !n.ServesModel(model) {
			continue
		}
		load := n.inflight.Load()
		if bestLoad == -1 || load < bestLoad {
			best = n
			bestLoad = load
		}
	}
	if best == nil {
		return nil, fmt.Errorf("no healthy node available for model %q", model)
	}
	return best, nil
}

// ---------------------------------------------------------------------------
// HEALTH CHECKER
// ---------------------------------------------------------------------------

func healthLoop(reg *Registry) {
	client := &http.Client{Timeout: 4 * time.Second}
	check := func() {
		for _, n := range reg.All() {
			resp, err := client.Get(n.URL() + "/health")
			ok := err == nil && resp != nil && resp.StatusCode == 200
			if resp != nil {
				resp.Body.Close()
			}
			wasHealthy := n.healthy.Load()
			n.healthy.Store(ok)
			n.lastCheck.Store(time.Now().Unix())
			if ok && !wasHealthy {
				log.Printf("[health] %s (%s) back ONLINE", n.Hostname, n.MeshIP)
			} else if !ok && wasHealthy {
				log.Printf("[health] %s (%s) went OFFLINE: %v", n.Hostname, n.MeshIP, err)
			}
		}
	}
	check()
	ticker := time.NewTicker(healthPeriod)
	for range ticker.C {
		check()
	}
}

// ---------------------------------------------------------------------------
// AUTH MIDDLEWARE
// ---------------------------------------------------------------------------

func requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if gatewayKey == "" {
			next(w, r)
			return
		}
		auth := r.Header.Get("Authorization")
		expected := "Bearer " + gatewayKey
		if auth != expected {
			writeError(w, 401, "invalid_api_key", "Missing or invalid Authorization header")
			return
		}
		next(w, r)
	}
}

func cors(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		if r.Method == "OPTIONS" {
			w.WriteHeader(204)
			return
		}
		next(w, r)
	}
}

func writeError(w http.ResponseWriter, code int, typ, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]string{"type": typ, "message": msg},
	})
}

// ---------------------------------------------------------------------------
// PROXY HANDLERS
// ---------------------------------------------------------------------------

type ChatRequest struct {
	Model    string `json:"model"`
	Messages []any  `json:"messages"`
	Stream   bool   `json:"stream"`
}

func handleChatCompletions(reg *Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			writeError(w, 400, "invalid_request", "cannot read body")
			return
		}

		var req ChatRequest
		if err := json.Unmarshal(body, &req); err != nil {
			writeError(w, 400, "invalid_request", "malformed JSON")
			return
		}

		node, err := reg.PickNode(req.Model)
		if err != nil {
			writeError(w, 503, "no_capacity", err.Error())
			return
		}

		node.inflight.Add(1)
		node.totalReqs.Add(1)
		defer node.inflight.Add(-1)

		ctx, cancel := context.WithTimeout(r.Context(), requestTimeout)
		defer cancel()

		client := &http.Client{Timeout: requestTimeout}
		resp, err := client.Do(mustClone(ctx, node.URL()+"/v1/chat/completions", body))

		if err != nil {
			node.failures.Add(1)
			node.healthy.Store(false)
			log.Printf("[proxy] upstream %s failed: %v — attempting failover", node.Hostname, err)

			fallback, ferr := reg.PickNode(req.Model)
			if ferr != nil || fallback.Hostname == node.Hostname {
				writeError(w, 502, "upstream_unavailable", "node unreachable, no failover available")
				return
			}
			fallback.inflight.Add(1)
			fallback.totalReqs.Add(1)
			defer fallback.inflight.Add(-1)
			resp, err = client.Do(mustClone(ctx, fallback.URL()+"/v1/chat/completions", body))
			if err != nil {
				writeError(w, 502, "upstream_unavailable", "failover node also unreachable")
				return
			}
			node = fallback
		}
		defer resp.Body.Close()

		respBody, _ := io.ReadAll(resp.Body)

		// Inject gateway metadata
		var parsed map[string]any
		if json.Unmarshal(respBody, &parsed) == nil {
			parsed["_titanu_gateway"] = map[string]any{
				"routed_to": node.Hostname,
				"mesh_ip":   node.MeshIP,
				"sovereign": true,
			}
			respBody, _ = json.Marshal(parsed)
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		w.Write(respBody)
	}
}

func mustClone(ctx context.Context, url string, body []byte) *http.Request {
	req, _ := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	return req
}

func handleModels(reg *Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		seen := map[string]bool{}
		var models []map[string]string
		for _, n := range reg.All() {
			if !n.healthy.Load() {
				continue
			}
			for _, m := range n.Models {
				if !seen[m] {
					seen[m] = true
					models = append(models, map[string]string{"id": m, "object": "model"})
				}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"object": "list", "data": models})
	}
}

func handleClusterStatus(reg *Registry) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		type nodeStatus struct {
			Hostname  string   `json:"hostname"`
			MeshIP    string   `json:"mesh_ip"`
			Role      string   `json:"role"`
			Healthy   bool     `json:"healthy"`
			Inflight  int64    `json:"inflight_requests"`
			Total     int64    `json:"total_requests"`
			Failures  int64    `json:"failures"`
			Models    []string `json:"models"`
			LastCheck int64    `json:"last_health_check"`
		}
		var out []nodeStatus
		online := 0
		for _, n := range reg.All() {
			if n.healthy.Load() {
				online++
			}
			out = append(out, nodeStatus{
				n.Hostname, n.MeshIP, n.Role, n.healthy.Load(),
				n.inflight.Load(), n.totalReqs.Load(), n.failures.Load(),
				n.Models, n.lastCheck.Load(),
			})
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"gateway":      "titanu-wecanmesh",
			"nodes_online": online,
			"nodes_total":  len(out),
			"nodes":        out,
		})
	}
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok", "service": "titanu-gateway"})
}

// ---------------------------------------------------------------------------
// MAIN
// ---------------------------------------------------------------------------

func main() {
	reg := NewRegistry()

	if _, err := os.Stat(nodeFile); err == nil {
		if err := reg.Load(nodeFile); err != nil {
			log.Fatalf("failed to load %s: %v", nodeFile, err)
		}
		log.Printf("loaded %d nodes from %s", len(reg.All()), nodeFile)
	} else {
		log.Printf("no %s found — starting with empty registry. Create it like:", nodeFile)
		log.Printf(`[{"hostname":"juschill-pro","mesh_ip":"100.110.238.3","shim_port":8000,"role":"control","models":["llama3.2"]}]`)
	}

	go healthLoop(reg)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/v1/chat/completions", cors(requireAuth(handleChatCompletions(reg))))
	mux.HandleFunc("/v1/models", cors(requireAuth(handleModels(reg))))
	mux.HandleFunc("/cluster/status", cors(handleClusterStatus(reg)))

	log.Printf("TitanU Gateway listening on %s", listenAddr)
	if gatewayKey == "" {
		log.Printf("WARNING: TITAN_GATEWAY_KEY not set — gateway is OPEN, no auth enforced")
	}

	if err := http.ListenAndServe(listenAddr, mux); err != nil {
		log.Fatal(err)
	}
}
