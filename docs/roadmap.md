# zzcaster — Roadmap

**Última atualização:** 2026-06-26

---

## 1 — Estabilidade no Windows real

O netplay ainda não foi testado de ponta a ponta em Windows nativo.

- [ ] Testar netplay host/join em Windows nativo
- [ ] Testar rollback + spectator em Windows nativo
- [ ] Corrigir bugs encontrados
- [ ] Testar com 2+ players reais pela internet (direto) no windows

**Critério de done:** dois jogadores em máquinas diferentes completam uma partida online sem desync.

---

## v2 — NAT traversal (hole-puncher + room codes)

Permitir que jogadores atrás de NAT consigam hospedar sem port forwarding,
via um relay server que faz matchmaker + STUN + hole-punch signaling.
Conexão direta por IP fica como fallback (a comunidade inteira usa).

**Plano detalhado:** [`docs/nat-traversal-protocol.md`](nat-traversal-protocol.md) (wire format spec, authoritative)
**Plano de port do CCCaster:** veja `ZZCASTER_NAT_TRAVERSAL_PLAN.md` no diretório de análise

### Slices incrementais

- [x] **Slice 1 — Server skeleton** (`server/`)
  - Go module, protocol.go (wire format), room.go (state), tcp_listener.go, udp_listener.go
  - Dockerfile + docker-compose.yml + README com instruções de deploy
  - Wire format spec em `docs/nat-traversal-protocol.md`
  - **Status:** pronto para build + test manual em VPS
  - **Próximo passo:** usuário roda `docker compose up -d` numa VPS e valida com `nc` + Python probe

- [x] **Slice 2 — Client: relay protocol + config + STUN probe** (`src/net/`)
  - Novos arquivos: `relay_protocol.zig`, `relay_config.zig`, `nat_probe.zig`
  - Modifica `src/common/config.zig` para adicionar `relayServers=` no `config.ini`
  - Modifica `src/net/mod.zig` para exportar os novos módulos
  - Modifica `build.zig` para rodar testes do módulo `net`
  - Cria `relay_list.txt` na raiz do repo com defaults (CCCaster live + zzcaster placeholder)
  - **Dual-protocol support:** o client fala tanto o protocolo zzcaster (room codes)
    quanto o protocolo CCCaster (IP-based matching). Default list tem CCCaster
    live primeiro como fallback — NAT traversal funciona no day 1 sem deploy.
  - Failover: client itera pela lista de relays em ordem; em TCP disconnect ou
    timeout, avança para o próximo.
  - **Status:** APIs prontas, sem UI ainda. Próximo passo é Slice 3.

- [ ] **Slice 3 — Client: relay handshake state machine** (`src/net/relay_client.zig`)
  - TCP signaling + UDP hole-punch, state machine passo-a-passo
  - step()-based (mesmo padrão do `NetplaySession` existente)
  - Devolve peer_addr para o caller handoff ao ENet
  - Suporta tanto flavor zzcaster quanto cccaster (decidido pelo RelayEntry)

- [ ] **Slice 4 — Client: integração com NetplaySession**
  - Novos SessionState: `relay_hosting`, `relay_joining`, `relay_hole_punching`
  - Modifica `session.zig`, `ui_waiting_for_peer.zig`
  - Mantém 100% do fluxo direto por IP intacto

- [ ] **Slice 5 — UI: mode toggle + room code**
  - Modifica `ui_pages.zig`: toggle "Direct IP" / "Room Code"
  - Em modo Room Code: campo de 4 letras + botão Generate
  - Tela de espera mostra código grande + botão Copy

- [ ] **Slice 6 — Testes cross-NAT + release**
  - Mesma LAN, cross-NAT cone, cross-NAT symmetric (deve falhar com mensagem clara)
  - Relay down → fallback para direct mode
  - Bump versão, tag release, update changelog

**Critério de done:** dois jogadores atrás de NAT cone se conectam via room code e jogam uma partida. Direct IP continua funcionando como antes.

---

## v3 — Melhorias de UX na tela de netplay

- [ ] Botão accept/reject quando alguém conecta (host side)
- [ ] Mostrar nome + tipo de conexão do oponente nos dois lados
- [ ] Indicador visual de qualidade de conexão (ping/loss) durante a partida
- [ ] Auto-reconnect se desconectar durante jogo

---

## v4 — Comunidade

- [ ] Log de partidas (resultado, duracao, desyncs)
- [ ] Atalhos de teclado pra ações comuns (host, join, spectator)
- [ ] Lobby pública (lista de salas abertas) — base já existe no relay server

---

## Depois — Ideias futuras

Sem compromisso, apenas anotadas:

- Presença online (quem está disponível)
- Replay gravado e compartilhável
- Suporte a mais de 2 players (lobby de espectadores com chat)
- Suporte a outros jogos (abstrair o hook layer)
- Relay mode real (server encaminha UDP entre peers se hole-punch falhar) — fallback para symmetric NAT
