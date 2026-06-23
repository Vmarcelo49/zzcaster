# zzcaster — Roadmap

**Última atualização:** 2026-06-22

---

## 1 — Estabilidade no Windows real

O netplay ainda não foi testado de ponta a ponta em Windows nativo.

- [ ] Testar netplay host/join em Windows nativo
- [ ] Testar rollback + spectator em Windows nativo
- [ ] Corrigir bugs encontrados
- [ ] Testar com 2+ players reais pela internet (direto) no windows

**Critério de done:** dois jogadores em máquinas diferentes completam uma partida online sem desync.

---

## v2 — Servidor de NAT traversal

Permitir que jogadores atrás de CGNAT/NAT consigam hospedar sem port forwarding.

- [ ] Servidor Go (matchmaker + STUN probe)
- [ ] Docker + docker-compose
- [ ] Integração client: relay host/join por room code
- [ ] Detecção de NAT type (STUN probe) + indicador na UI
- [ ] Config editável no `config.ini` (fallback hardcoded)

> Detalhes: [nat-traversal-server-plan.md](nat-traversal-server-plan.md)

**Critério de done:** dois jogadores atrás de NAT se conectam via relay e jogam uma partida.

---

## v3 — Melhorias de UX na tela de netplay

- [ ] Botão accept/reject quando alguém conecta (host side)
- [ ] Mostrar nome + tipo de conexão do oponente nos dois lados
- [ ] Indicador visual de qualidade de conexão (ping/loss) durante a partida
- [ ] Auto-reconnect se desconectar durante jogo

---

## v4 — Comunidade

- [ ] Room code compartilhável (copiar/colar)
- [ ] Log de partidas (resultado, duracao, desyncs)
- [ ] Atalhos de teclado pra ações comuns (host, join, spectator)

---

## Depois — Ideias futuras

Sem compromisso, apenas anotadas:

- Lobby pública (lista de salas abertas)
- Presença online (quem está disponível)
- Replay gravado e compartilhável
- Suporte a mais de 2 players (lobby de espectadores com chat)
- Suporte a outros jogos (abstrair o hook layer)
