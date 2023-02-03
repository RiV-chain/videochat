package websocket

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"

	"github.com/flutter-webrtc/flutter-webrtc-server/pkg/logger"
	"github.com/gorilla/websocket"
)

type WebSocketServerConfig struct {
	Host           string
	Port           int
	CertFile       string
	KeyFile        string
	HTMLRoot       string
	WebSocketPath  string
	TurnServerPath string
}

func DefaultConfig() WebSocketServerConfig {
	return WebSocketServerConfig{
		Host:           "0.0.0.0",
		Port:           8086,
		HTMLRoot:       "web",
		WebSocketPath:  "/ws",
		TurnServerPath: "/api/turn",
	}
}

type WebSocketServer struct {
	handleWebSocket  func(ws *WebSocketConn, request *http.Request)
	handleTurnServer func(writer http.ResponseWriter, request *http.Request)
	// Websocket upgrader
	upgrader websocket.Upgrader
}

func NewWebSocketServer(
	wsHandler func(ws *WebSocketConn, request *http.Request),
	turnServerHandler func(writer http.ResponseWriter, request *http.Request)) *WebSocketServer {
	var server = &WebSocketServer{
		handleWebSocket:  wsHandler,
		handleTurnServer: turnServerHandler,
	}
	server.upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool {
			return true
		},
	}
	return server
}

func (server *WebSocketServer) handleWebSocketRequest(writer http.ResponseWriter, request *http.Request) {
	responseHeader := http.Header{}
	//responseHeader.Add("Sec-WebSocket-Protocol", "protoo")
	socket, err := server.upgrader.Upgrade(writer, request, responseHeader)
	if err != nil {
		logger.Panicf("%v", err)
	}
	wsTransport := NewWebSocketConn(socket)
	server.handleWebSocket(wsTransport, request)
	wsTransport.ReadMessage()
}

func (server *WebSocketServer) handleTurnServerRequest(writer http.ResponseWriter, request *http.Request) {
	server.handleTurnServer(writer, request)
}

// Bind .
func (server *WebSocketServer) Bind(cfg WebSocketServerConfig) {
	// Websocket handle func
	http.HandleFunc(cfg.WebSocketPath, server.handleWebSocketRequest)
	http.HandleFunc(cfg.TurnServerPath, server.handleTurnServerRequest)
	http.HandleFunc("/api/contacts", server.handleContactsRequest)
	var nocache = func(fs http.Handler) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			w.Header().Add("Cache-Control", "no-cache, no-store, must-revalidate")
			w.Header().Add("Pragma", "no-cache")
			w.Header().Add("Expires", "0")
			fs.ServeHTTP(w, r)
		}
	}
	http.Handle("/", nocache(http.FileServer(http.Dir(cfg.HTMLRoot))))
	logger.Infof("Flutter WebRTC Server listening on: %s:%d", cfg.Host, cfg.Port)
	// http.ListenAndServe(cfg.Host+":"+strconv.Itoa(cfg.Port), nil)
	panic(http.ListenAndServeTLS(cfg.Host+":"+strconv.Itoa(cfg.Port), cfg.CertFile, cfg.KeyFile, nil))
}

const meshep = "http://localhost:19019"

type ContactsRequest struct {
	Query string   `json:"query"`
	Peers []string `json:"peers"`
}
type Node struct {
	Name    string `json:"name"`
	Email   string `json:"email"`
	Address string `json:"address"`
	Key     string `json:"key"`
	Avatar  string `json:"avatar"`
}
type ContactsResponse struct {
	Matches []Node   `json:"matches"`
	Peers   []string `json:"peers"`
}

func getRemoteNodeinfo(key string) (n Node, err error) {
	type Nodes map[string]Node
	response, err := http.Get(meshep + "/api/remote/nodeinfo/" + key)
	if err != nil {
		return
	}
	if response.StatusCode != 200 {
		err = errors.New(response.Status)
		return
	}
	ns := Nodes{}
	err = json.NewDecoder(response.Body).Decode(&ns)
	if err != nil {
		return
	}
	n = ns[key]
	n.Key = key
	n.Address = net.IP(AddrForKey(key)[:]).String()

	return
}

func getRemotePeers(key string) (p []string, err error) {
	response, err := http.Get(meshep + "/api/remote/peers/" + key)
	if err != nil {
		return
	}
	if response.StatusCode != 200 {
		err = errors.New(response.Status)
		return
	}
	type Peer struct {
		Keys []string `json:"keys"`
	}
	type Peers map[string]Peer

	m := Peers{}
	if err = json.NewDecoder(response.Body).Decode(&m); err != nil {
		return
	}
	//It only one
	for _, v := range m {
		p = v.Keys
	}
	return
}

func getPeers() (p []string, err error) {
	response, err := http.Get(meshep + "/api/peers")
	if err != nil {
		return
	}
	if response.StatusCode != 200 {
		err = errors.New(response.Status)
		return
	}
	type Peer struct {
		Key string `json:"key"`
	}

	peers := []Peer{}
	if err = json.NewDecoder(response.Body).Decode(&peers); err != nil {
		return
	}
	for _, peer := range peers {
		p = append(p, peer.Key)
	}
	return
}

// request: {"query":"email|addr", "peers":["addr", ...]}
// response:{"matches":[{"key":"pub_key", "email":"email@riv.org", "address":"ipv6"}, ...], "peers": ["key", ...]}

func (server *WebSocketServer) handleContactsRequest(w http.ResponseWriter, r *http.Request) {

	switch r.Method {
	case "POST":
		w.Header().Set("Access-Control-Allow-Origin", "*")
		var rbody ContactsRequest
		err := json.NewDecoder(r.Body).Decode(&rbody)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		var resp = ContactsResponse{[]Node{}, []string{}}
		if node, err := getRemoteNodeinfo(rbody.Query); err == nil { //Query by Key
			resp.Matches = append(resp.Matches, node)
			//TBD
			//} else if net.ParseIP(rbody.Query) == nil { //query by IP
		} else if len(rbody.Peers) == 0 {
			peers, err := getPeers()
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			resp.Peers = peers
		}
		for _, p := range rbody.Peers {
			if node, err := getRemoteNodeinfo(p); err == nil {
				if strings.Contains(node.Email, rbody.Query) || strings.Contains(node.Name, rbody.Query) {
					resp.Matches = append(resp.Matches, node)
				}
				if peers, err := getRemotePeers(p); err == nil {
					resp.Peers = peers
				}
			}
		}
		b, err := json.Marshal(resp)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Add("Content-Type", "application/json; charset=utf-8")
		fmt.Fprint(w, string(b))
	case "OPTIONS":
		headers := w.Header()
		headers.Add("Access-Control-Allow-Origin", "*")
		headers.Add("Vary", "Origin")
		headers.Add("Vary", "Access-Control-Request-Method")
		headers.Add("Vary", "Access-Control-Request-Headers")
		headers.Add("Access-Control-Allow-Headers", "Content-Type, Accept, token")
		headers.Add("Access-Control-Allow-Methods", "POST,OPTIONS")
		w.WriteHeader(http.StatusOK)
	default:
		http.Error(w, http.StatusText(http.StatusMethodNotAllowed), http.StatusMethodNotAllowed)
	}
}

// AddrForKey takes an ed25519.PublicKey as an argument and returns an *Address.
// This function returns nil if the key length is not ed25519.PublicKeySize.
// This address begins with the contents of GetPrefix(), with the last bit set to 0 to indicate an address.
// The following 8 bits are set to the number of leading 1 bits in the bitwise inverse of the public key.
// The bitwise inverse of the key, excluding the leading 1 bits and the first leading 0 bit, is truncated to the appropriate length and makes up the remainder of the address.
func AddrForKey(key string) *[16]byte {
	// 128 bit address
	// Begins with prefix
	// Next bit is a 0
	// Next 7 bits, interpreted as a uint, are # of leading 1s in the NodeID
	// Leading 1s and first leading 0 of the NodeID are truncated off
	// The rest is appended to the IPv6 address (truncated to 128 bits total)
	var publicKey []byte
	var err error
	if publicKey, err = hex.DecodeString(key); err != nil {
		return nil
	}
	const PublicKeySize = 32
	if len(publicKey) != PublicKeySize {
		return nil
	}
	var buf [PublicKeySize]byte
	copy(buf[:], publicKey)
	for idx := range buf {
		buf[idx] = ^buf[idx]
	}
	var addr [16]byte
	var temp = make([]byte, 0, 32)
	done := false
	ones := byte(0)
	bits := byte(0)
	nBits := 0
	for idx := 0; idx < 8*len(buf); idx++ {
		bit := (buf[idx/8] & (0x80 >> byte(idx%8))) >> byte(7-(idx%8))
		if !done && bit != 0 {
			ones++
			continue
		}
		if !done && bit == 0 {
			done = true
			continue // FIXME? this assumes that ones <= 127, probably only worth changing by using a variable length uint64, but that would require changes to the addressing scheme, and I'm not sure ones > 127 is realistic
		}
		bits = (bits << 1) | bit
		nBits++
		if nBits == 8 {
			nBits = 0
			temp = append(temp, bits)
		}
	}
	prefix := GetPrefix()
	copy(addr[:], prefix[:])
	addr[len(prefix)] = ones
	copy(addr[len(prefix)+1:], temp)
	return &addr
}

// GetPrefix returns the address prefix used by mesh.
// The current implementation requires this to be a multiple of 8 bits + 7 bits.
// The 8th bit of the last byte is used to signal nodes (0) or /64 prefixes (1).
// Nodes that configure this differently will be unable to communicate with each other using IP packets, though routing and the DHT machinery *should* still work.
func GetPrefix() [1]byte {
	p, err := hex.DecodeString("fc")
	if err != nil {
		panic(err)
	}
	var prefix [1]byte
	copy(prefix[:], p[:1])
	return prefix
}
