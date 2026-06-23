# Plano: Servidor de NAT Traversal para zzcaster

**Data:** 2026-06-22
**Status:** Planejamento

---

## Resumo

Criar um servidor em **Go** que funciona como **STUN-like endpoint discoverer + matchmaker**, permitindo que jogadores atrás de CGNAT/NAT simétrico consigam hospedar partidas no zzcaster. O servidor **não faz relay de dados de jogo** — apenas descobre os endpoints públicos e permite hole-punching direto (igual ao CCCaster original).

O servidor será **containerizado com Docker** (multi-stage build, imagem final em `scratch` ~5MB). Qualquer pessoa com uma VPS pode subir o server com um único `docker run`.

O client zzcaster terá a **configuração do endereço do servidor editável** no `config.ini`. Se vazio, usa um default hardcoded do projeto. Se preenchido, usa o valor do config.

---

## Arquitetura

```
┌──────────────┐         TCP          ┌──────────────────────┐
│  zzcaster     │◄──────────────────►│  zzcaster-server      │
│  (Host)       │                      │  (Go, Docker)         │
└──────┬───────┘                      │  TCP :3939 (interno)  │
       │                               │  UDP :3940 (interno)  │
       │  1. Host manda port + code   │  TCP :3939 (host)     │
       │  2. Client manda code         │  UDP :3940 (host)     │
       │  3. Server responde peer IP   └──────────────────────┘
       │  4. Hole-punching UDP direto
       ▼
┌──────────────┐  ──►  ENet direto  ◄──  ┌──────────────┐
│  zzcaster     │                         │  zzcaster    │
│  (Host)       │                         │  (Client)    │
└──────────────┘                         └──────────────┘
```

### Protocolo (baseado no CCCaster original, simplificado)

**Todas as mensagens TCP: length-prefix (4 bytes big-endian) + payload JSON.**

| Direção | Tipo | Payload | Descrição |
|---------|------|---------|-----------|
| Host → Server | `host_register` | `{"port": 46318, "code": "ABCD"}` | Host registra sala |
| Client → Server | `client_join` | `{"code": "ABCD"}` | Client pede para entrar |
| Server → Client | `host_info` | `{"server_ip": "x.x.x.x", "server_port": 46318}` | Endpoint público do host |
| Server → Host | `client_joined` | `{"client_ip": "x.x.x.x", "client_port": 12345}` | Endpoint público do client |
| Server → qualquer | `error` | `{"message": "..."}` | Erro |

#### Fluxo

1. **Host** conecta TCP ao servidor, envia `host_register` (port local + room code 4 letras)
2. **Client** conecta TCP ao servidor, envia `client_join` (room code)
3. **Servidor** faz match: envia `host_info` ao client, `client_joined` ao host
4. **Servidor** fecha conexões TCP
5. **Ambos** iniciam hole-punching UDP simultâneo com ENet
6. **ENet** conecta direto → dados do jogo fluem peer-to-peer

### CGNAT Detection (bonus do servidor)

O mesmo servidor pode servir como STUN probe para detectar CGNAT:

1. Peer envia UDP para o servidor no port 3940 (separado do TCP)
2. Servidor responde com o IP:port público que viu (8 bytes: 4 IP + 2 port + 2 padding)
3. Peer compara: se o port que o servidor vê é diferente do port local → está atrás de NAT
4. Peer repete de outro port local → se o port público mudou → NAT simétrico/CGNAT

---

## Estrutura de Diretórios

```
server/
├── Dockerfile                    # Multi-stage: build Go → scratch/alpine
├── docker-compose.yml            # Deploy completo (TCP + UDP ports)
├── go.mod
├── go.sum
├── main.go                       # Entry point, parse config, start listeners
├── config.go                     # Config struct (portas, timeouts, log level)
│
├── protocol/
│   ├── message.go                # Tipos, encode/decode JSON + length-prefix
│   └── handler.go                # Roteamento de mensagens → room manager
│
├── tcp/
│   ├── listener.go               # TCP accept loop + dispatch
│   └── conn.go                   # Conn wrapper com buffered read/write
│
├── stun/
│   └── probe.go                  # UDP STUN echo (CGNAT detection)
│
└── room/
    ├── manager.go                # Salas: register, join, match, TTL cleanup
    └── room.go                   # Struct Room
```

---

## Docker

### Dockerfile (multi-stage, imagem ~5MB)

```dockerfile
# Stage 1: Build
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /zzcaster-server .

# Stage 2: Runtime (zero overhead)
FROM scratch
COPY --from=builder /zzcaster-server /zzcaster-server
EXPOSE 3939/tcp 3940/udp
ENTRYPOINT ["/zzcaster-server"]
```

### docker-compose.yml

```yaml
services:
  zzcaster-server:
    build: .
    container_name: zzcaster-server
    ports:
      - "3939:3939/tcp"   # TCP matchmaker
      - "3940:3940/udp"   # UDP STUN probe
    restart: unless-stopped
    # Config via environment variables (também suporta YAML)
    environment:
      - TCP_PORT=3939
      - UDP_STUN_PORT=3940
      - ROOM_TTL=30s
      - LOG_LEVEL=info
```

Para usar: basta `docker compose up -d` na VPS.

---

## Config Dinâmico no Client zzcaster

### Arquivo `config.ini` (já existe no projeto)

```ini
[Network]
; Endereço do servidor de NAT traversal (matchmaker + STUN).
; Formato: host:port (ex: nat.zzcaster.com:3939 para TCP,
;   nat.zzcaster.com:3940 para STUN UDP)
; Se vazio ou ausente, usa o default do projeto.
RelayServer=
StunServer=
```

### Lógica de resolução (em Zig)

```zig
// src/net/relay_config.zig
const DEFAULT_RELAY_HOST = "nat.zzcaster.com";
const DEFAULT_RELAY_PORT: u16 = 3939;
const DEFAULT_STUN_PORT: u16 = 3940;

pub fn getRelayAddress(allocator: Allocator, config: *Config) ![]u8 {
    // 1. Se config.ini tem RelayServer preenchido, usa ele
    if (config.relay_server.len > 0) {
        return allocator.dupe(u8, config.relay_server);
    }
    // 2. Senão, monta o default hardcoded
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{
        DEFAULT_RELAY_HOST, DEFAULT_RELAY_PORT,
    });
}
```

**Prioridade:** config.ini > hardcoded default. Sempre tem um fallback.

---

## Implementação por Fase

### Fase 1: Servidor Go — Protocolo + TCP + Matchmaker (~2-3h)

**Arquivos:** `server/main.go`, `server/protocol/`, `server/tcp/`, `server/room/`

1. **`protocol/message.go`** — Tipos Go com JSON tags:
   - `MessageKind`: `host_register`, `client_join`, `host_info`, `client_joined`, `error`
   - Encode/decode com length-prefix (4 bytes big-endian)
   - Testes unitários de marshal/unmarshal

2. **`tcp/listener.go`** — TCP accept loop:
   - `net.Listen("tcp", ":3939")`
   - Goroutine por conexão
   - Read loop → decode → dispatch para handler

3. **`room/manager.go`** — Gerenciador de salas:
   - `map[string]*Room` com `sync.RWMutex`
   - `Register(code, port, conn)` — cria sala
   - `Join(code, conn)` — match, envia endpoints, fecha conns
   - TTL: goroutine de cleanup a cada 10s, remove salas > 30s

4. **`protocol/handler.go`** — Roteamento:
   - `host_register` → `room.Register()`
   - `client_join` → `room.Join()`
   - Envia respostas, loga tudo

### Fase 2: Servidor Go — STUN Probe + Docker (~1-2h)

**Arquivos:** `server/stun/probe.go`, `Dockerfile`, `docker-compose.yml`

1. **`stun/probe.go`** — UDP STUN echo:
   - `net.ListenPacket("udp", ":3940")`
   - Recebe datagrama → responde com 8 bytes (IP[4] + port[2] + padding[2])

2. **`main.go`** — Start ambas listeners (TCP + UDP) em paralelo via goroutines
   - Parse config de environment variables ou flags
   - Graceful shutdown com `signal.NotifyContext`

3. **Dockerfile** — Multi-stage build (`golang:1.22-alpine` → `scratch`)
4. **docker-compose.yml** — Deploy com ports mapeados
5. **Teste manual:** `docker compose up`, conectar com netcat

### Fase 3: Client zzcaster — Relay Config + Protocol (~4-6h)

**Novos arquivos:** `src/net/relay.zig`, `src/net/nat_probe.zig`, `src/net/relay_config.zig`
**Modificados:** `src/launcher/session.zig`, `src/launcher/ui_pages.zig`, `src/common/config.zig`

1. **`src/common/config.zig`** — Adicionar campos:
   - `relay_server: [128]u8` — endereço TCP do relay
   - `stun_server: [128]u8` — endereço UDP do STUN
   - Parse do `[Network]` section

2. **`src/net/relay_config.zig`** — Lógica de resolução de endereço:
   - Se config preenchido → usa config
   - Se vazio → usa `DEFAULT_RELAY_HOST:DEFAULT_RELAY_PORT`

3. **`src/net/relay.zig`** — Cliente TCP para o servidor:
   - Conectar via Winsock (`ws2_32`, não ENet — TCP puro)
   - Enviar `host_register` / `client_join`
   - Receber endpoint do peer (JSON)
   - Retornar IP:port para o caller

4. **`src/net/nat_probe.zig`** — STUN probe client:
   - Abrir UDP socket → enviar probe → receber IP:port público
   - Detectar NAT type: comparar port local vs port público
   - Segundo probe de outro port → detectar NAT simétrico

5. **`src/launcher/session.zig`** — Integração:
   - Novo `SessionState`: `.relay_waiting`, `.relay_connecting`
   - `startRelayHost(code, port)` — registra no servidor, espera peer
   - `startRelayJoin(code)` — pede match, recebe endpoint
   - Após receber peer endpoint → ENet connect (hole-punch)
   - Fallback: se hole-punch falhar em 10s → mensagem de erro amigável

6. **UI em `ui_pages.zig`**:
   - Tela Host: campo "Room Code" (4 letras, auto-gerado) + botão "Host via Relay"
   - Tela Join: campo "Room Code" + botão "Join via Relay"
   - Indicador NAT: 🟢 Direct | 🟡 NAT | 🔴 CGNAT (baseado no STUN probe)

### Fase 4: Deploy + Testing (~2h)

1. **Deploy script** — `server/scripts/deploy.sh`:
   - Build local + `docker compose up -d`
   - Ou `docker build -t zzcaster-server . && docker run -d -p 3939:3939 -p 3940:3940/udp zzcaster-server`

2. **Testes:**
   - Docker local: duas instâncias launcher no mesmo PC via relay
   - Duas redes diferentes: testar hole-punching real
   - CGNAT: verificar detecção correta com STUN probe

---

## Ordem de Implementação

| Fase | O que | Tempo | Depende de |
|------|-------|-------|-----------|
| 1 | Servidor Go: protocolo TCP + matchmaker | 2-3h | Nada |
| 2 | Servidor Go: STUN UDP + Docker + docker-compose | 1-2h | Fase 1 |
| 3 | Client zzcaster: relay config dinâmico + protocolo + UI | 4-6h | Fase 1+2 |
| 4 | Deploy + testing | 2h | Fase 3 |
| **Total** | | **~9-13h** | |

Começar pela **Fase 1** (servidor Go) — independente do client, testável com netcat + Docker.

---

## Referências

- [Plano original de melhorias de networking](networking-improvements-plan.md)
- Protocolo original do CCCaster: `scripts/server.py` em [Rhekar/CCCaster](https://github.com/Rhekar/CCCaster)
- `lib/SmartSocket.cpp` — direct-connect com relay-tunnel fallback no CCCaster original
