# Análise de APIs para Hosting de Torneios

**Concorrentes avaliados:** Challonge e Start.gg
**Foco:** Integração em jogos para hosting de torneios, reporte automático de placares e uso de usuários da plataforma como identidade no jogo.
**Data da análise:** Junho de 2026

---

## 📑 Sumário

1. [Resumo executivo](#1-resumo-executivo)
2. [Visão geral comparativa](#2-visão-geral-comparativa)
3. [**Challonge — API detalhada (foco principal)**](#3-challonge--api-detalhada-foco-principal)
   - 3.1 Visão geral e versões
   - 3.2 Autenticação
   - 3.3 Endpoints de Torneios
   - 3.4 Endpoints de Participantes
   - 3.5 Endpoints de Matches (reporte de placares)
   - 3.6 Usuários e SSO
   - 3.7 Webhooks (e alternativas)
   - 3.8 Limites, quotas e considerações comerciais
   - 3.9 SDKs e ferramentas
   - 3.10 Arquitetura recomendada para gamedev
   - 3.11 Casos de uso viáveis no free
4. [Start.gg — API detalhada (comparativo)](#4-startgg--api-detalhada-comparativo)
5. [Comparação direta Challonge vs Start.gg](#5-comparação-direta-challonge-vs-startgg)
6. [Recomendação para o seu cenário](#6-recomendação-para-o-seu-cenário)
7. [Apêndice — Referências](#7-apêndice--referências)

---

## 1. Resumo executivo

Este documento consolida o estudo técnico das APIs públicas do **Challonge** e do **Start.gg** com o objetivo de avaliar a viabilidade de integrá-las em um jogo para:

1. **Hosting de torneios** (criar e gerenciar brackets automaticamente)
2. **Reporte automático de placares** (o jogo/sistema reporta resultados sem intervenção humana)
3. **Uso da conta da plataforma como identidade no jogo** (SSO / "Login with Challonge" ou "Login with Start.gg")

### Conclusão principal

| Necessidade | Melhor escolha |
|-------------|----------------|
| Criar torneios automaticamente via API | **Challonge** (único que permite CRUD completo) |
| Jogo reporta placares automaticamente | Ambos funcionam — **Start.gg** tem dados mais ricos (personagem, stage), **Challonge** é mais simples |
| Login com conta da plataforma | **Start.gg** tem identidade competitiva real (gamerTag, rankings); **Challonge** tem login básico (username, email) |
| Volume alto de API sem estourar quota | **Start.gg** (80 req/min, sem limite mensal) >> Challonge (500 req/mês no v2.1 free) |

**Para o cenário do solicitante** (jogo com hosting automatizado de torneios), o **Challonge é a escolha mais adequada** por ser a única das duas que permite criar torneios programaticamente. O Start.gg permanece como complemento opcional para identidade competitiva e dados de gameplay avançados.

---

## 2. Visão geral comparativa

| Critério | Challonge | Start.gg |
|----------|-----------|----------|
| **Tipo de API** | REST (JSON:API ou JSON/XML) | GraphQL exclusivo |
| **URL base** | `https://api.challonge.com/v2.1` (v2.1) ou `https://api.challonge.com/v1/` (v1) | `https://api.start.gg/gql/alpha` |
| **Versões** | v2.1 (atual), v2.0 (dep.), v1 (dep.) | Apenas `alpha` |
| **Criar torneio via API** | ✅ Sim (`POST /tournaments.json`) | ❌ **Não existe mutation** |
| **Editar / excluir torneio** | ✅ Sim (`PUT`/`DELETE /tournaments/{id}`) | ❌ Não |
| **Mudar estado do torneio** | ✅ Sim (`change_state.json`) | ❌ Não |
| **Adicionar participantes** | ✅ Sim (CRUD + `bulk_add`) | ✅ Sim (`registerForTournament`) |
| **Reportar placar via API** | ✅ Sim (vencedor + scores por jogo) | ✅ **Sim, rico** (vencedor + personagem + stage + stocks por game) |
| **Login OAuth (SSO)** | ✅ Authorization Code + Device + Client Credentials | ⚠️ Apenas Authorization Code |
| **Perfil competitivo do usuário** | ⚠️ Só `username`/`email`/`avatar` | ✅ `gamerTag`, `prefix`, `rankings`, `recentStandings`, histórico de sets |
| **Webhooks** | ❌ Não (free) | ❌ Não |
| **Limite free** | v2.1: 500 req/mês / v1: 5.000 req/mês | 80 req/min, sem limite mensal documentado |
| **SDK oficial** | ❌ Não | ❌ Não |
| **SDKs comunitários** | `achallonge`, `pychallonge` (Python); `challonge-node` (Node); `challonge-api` (PHP) | `ggapi`, `pysmashgg` (Python); clientes GraphQL genéricos |
| **Comunidade alvo** | Genérico / brackets rápidos | Esports / FGC (Smash, Tekken, Street Fighter) |
| **Plano pago** | Sim, acima do limite free (via `connect.challonge.com`) | Não documentado para API; taxa de 6% sobre inscrições pagas (produto, não API) |

---

## 3. Challonge — API detalhada (foco principal)

> **Fontes oficiais consultadas:**
> - Documentação consolidada: https://challonge.apidog.io
> - Páginas: *Getting Started*, *Authorization*, *About (v1)*, *Scopes*, *Tournament States*, *Tournaments*, *Participants*, *Matches*, *Get User*, *Register Me*, *Change Match State*, *Change Tournament State*, *Grant Request*
> - Página comercial do **Challonge Connect**: https://challonge.com/connect
> - Referência comunitária da API v1 (Python `achallonge`): https://achallonge.readthedocs.io/en/latest/api.html

### 3.1 Visão geral e versões

O Challonge mantém **três versões** de API, todas documentadas no portal único `challonge.apidog.io`:

| Versão | Status | Base URL | Formato | Autenticação |
|--------|--------|----------|---------|--------------|
| **v2.1** | **Atual (recomendada)** | `https://api.challonge.com/v2.1` | JSON:API (`application/vnd.api+json`) | OAuth 2.0 **ou** chave v1 |
| v2.0 | *Deprecated* | `https://api.challonge.com/v2` | JSON:API | OAuth 2.0 |
| **v1** | *Deprecated* (sem suporte a torneios de 2 estágios) | `https://api.challonge.com/v1/` | JSON **ou** XML | HTTP Basic (usuário + API key) |

> ⚠️ **Mudança comercial importante (2026):** a API passou a exigir **plano pago** acima de um limite mensal de requisições.
> - **v2.1**: gratuito até **500 requisições/mês**; período de tolerância termina em **01/07/2026** — após isso, excedentes recebem **`429 Too Many Requests`**.
> - **v1**: gratuito até **5.000 requisições/mês** (valor "sujeito a alterações antes do anúncio oficial"), exigindo plano pago acima disso a partir de maio/2026.

#### Tipos de torneio suportados

- Single elimination
- Double elimination
- Round robin
- Swiss
- Free for all (FFA)
- Race
- Leaderboard
- Grand prix
- Time trial

> **Nota:** torneios de **2 estágios** (ex.: pools + bracket final) só são suportados na **v2.1**. A v1 não possui suporte.

#### Estados de torneio (Tournament States)

| Estado | Significado |
|--------|-------------|
| `pending` | Criado, ainda não iniciado |
| `checking_in` | Em check-in (janela aberta) |
| `checked_in` | Check-in finalizado |
| `accepting_predictions` | Aceitando palpites (feature de comunidade) |
| `group_stages_underway` | Fase de grupos em andamento |
| `group_stages_finalized` | Fase de grupos finalizada |
| `underway` | Bracket principal em andamento |
| `awaiting_review` | Aguardando revisão do organizador |
| `complete` | Finalizado |

### 3.2 Autenticação

A v2.1 aceita **dois modelos de autenticação**, com headers obrigatórios:

#### Modelo 1 — OAuth 2.0 (recomendado para apps de terceiros)

Headers obrigatórios:
```http
Authorization-Type: v2
Authorization: Bearer <access_token>
```

Fluxos OAuth suportados:
- **Authorization Code** — padrão web/SSO
- **Device Grant** — útil para consoles/TVs sem teclado
- **Client Credentials** — acesso aplicacional sem usuário
- **Refresh Token** — renovação de access token

Endpoints OAuth:
- Autorização: `https://api.challonge.com/oauth/authorize`
- Token: `https://api.challonge.com/oauth/token`

**Access token expira em 1 semana.** Refresh token suportado.

#### Modelo 2 — Chave v1 (HTTP Basic ou query param)

```http
Authorization-Type: v1
Authorization: Basic <base64(usuario:api_key)>
```

Ou alternativamente via query string:
```
GET /tournaments.json?api_key=SUA_CHAVE
```

A chave v1 pode ser obtida nas configurações de conta do Challonge. **Este modelo é mais simples e tem quota free 10x maior (5.000 vs 500 req/mês).**

#### Scopes OAuth (v2.1)

| Scope | Permissão |
|-------|-----------|
| `me` | Ler dados do próprio usuário (`GET /me.json`) |
| `tournaments:read` | Listar/ler torneios |
| `tournaments:write` | Criar/editar torneios |
| `matches:read` | Ler partidas |
| `matches:write` | Reportar/editar partidas |
| `participants:read` | Ler participantes |
| `participants:write` | Adicionar/editar participantes |
| `attachments:*` | Anexos de match (uploads, links) |
| `communities:manage` | Gerenciar comunidades |
| `application:organizer` | App age como organizador |
| `application:player` | App age como jogador (inscrição self-service) |
| `application:manage` | App com permissões totais |

### 3.3 Endpoints de Torneios

#### Criar torneio
```http
POST /tournaments.json
Authorization-Type: v2
Authorization: Bearer <token>
Content-Type: application/vnd.api+json

{
  "data": {
    "type": "tournaments",
    "attributes": {
      "name": "Torneio Semanal X",
      "url": "torneio-semanal-x-2026-06",
      "tournament_type": "single elimination",
      "description": "Torneio aberto da comunidade",
      "open_signup": false,
      "hold_third_place_match": true,
      "pts_for_match_win": 1,
      "pts_for_match_tie": 0.5,
      "pts_for_game_win": 0,
      "pts_for_game_tie": 0,
      "pts_for_bye": 1,
      "swiss_rounds": 0,
      "ranked_by": "match wins",
      "rr_pts_for_match_win": 1,
      "rr_pts_for_match_tie": 0.5,
      "rr_pts_for_game_win": 0,
      "rr_pts_for_game_tie": 0,
      "accept_attachments": false,
      "game_name": "Meu Jogo",
      "participants_count": 16,
      "start_at": "2026-07-01T18:00:00-03:00",
      "check_in_duration": 60
    }
  }
}
```

#### Listar torneios
```http
GET /tournaments.json?state=in_progress
```

#### Obter, atualizar e excluir
```http
GET    /tournaments/{id}.json
PUT    /tournaments/{id}.json
DELETE /tournaments/{id}.json
```

#### Mudar estado do torneio
```http
PUT /tournaments/{id}/change_state.json
Content-Type: application/vnd.api+json

{ "data": { "attributes": { "state": "start" } } }
```

Valores de `state`: `check_in`, `abort_check_in`, `start`, `finalize`, `reset`, `open_predictions`, `close_predictions`.

### 3.4 Endpoints de Participantes

#### Adicionar participante único
```http
POST /tournaments/{tournament_id}/participants.json

{
  "data": {
    "type": "participants",
    "attributes": {
      "name": "PlayerX",
      "seed": 1,
      "misc": "metadata_livre",     // ex.: player_id interno do seu jogo
      "email": "player@exemplo.com",
      "username": "playerX_challonge"  // vincula a conta real do Challonge
    }
  }
}
```

> 💡 **Vinculação a conta real do Challonge:** ao enviar `username` ou `email`, o Challonge convida/vincula o usuário real do Challonge automaticamente. O participante passa a aparecer com avatar e nome reais no bracket público.

#### Adicionar participantes em lote (1 requisição para N jogadores — economiza quota)
```http
POST /tournaments/{tournament_id}/participants/bulk_add.json

{
  "data": {
    "type": "participants",
    "attributes": {
      "participants": [
        { "name": "Player1", "seed": 1 },
        { "name": "Player2", "seed": 2 },
        { "name": "Player3", "seed": 3 },
        { "name": "Player4", "seed": 4 }
      ]
    }
  }
}
```

#### Auto-inscrição (jogador se inscreve sozinho via OAuth)
```http
POST /tournaments/{tournament_id}/register_me.json
Authorization-Type: v2
Authorization: Bearer <token_do_jogador>
```
> Requer scope `application:player`. Excelente para UX: o usuário logado no seu jogo clica em "Inscrever-se" e é inscrito automaticamente no torneio do Challonge.

#### Outras operações
```http
GET    /tournaments/{id}/participants.json        # listar
GET    /tournaments/{id}/participants/{pid}.json  # obter
PUT    /tournaments/{id}/participants/{pid}.json  # atualizar
DELETE /tournaments/{id}/participants/{pid}.json  # remover
POST   /tournaments/{id}/participants/clear.json  # remover todos
POST   /tournaments/{id}/participants/randomize.json  # randomizar seeds
```

### 3.5 Endpoints de Matches (reporte de placares) — **o ponto central**

Esta é a funcionalidade que permite ao **jogo reportar resultados automaticamente**.

#### Listar partidas
```http
GET /tournaments/{id}/matches.json
GET /tournaments/{id}/matches/{match_id}.json
```

#### Reportar placar (v2.1)
```http
PUT /tournaments/{tournament_id}/matches/{match_id}.json
Content-Type: application/vnd.api+json

{
  "data": {
    "attributes": {
      "match": [
        {
          "participant_id": 12345,
          "score_set": "4,2,4",
          "rank": 1,
          "advancing": true
        },
        {
          "participant_id": 67890,
          "score_set": "2,4,2",
          "rank": 2,
          "advancing": false
        }
      ],
      "tie": false,
      "location": "Estação 1",
      "scheduled_time": "2026-07-01T18:30:00-03:00"
    }
  }
}
```

#### Reportar placar (v1 — mais simples)
```http
PUT /tournaments/{tournament_id}/matches/{match_id}.json
?api_key=SUA_CHAVE

match[scores_csv]=1-3,3-0,3-2
&match[winner_id]=12345
```

> `scores_csv` no formato `"placar1-placar2,placar1-placar2,..."` (cada par é um jogo do set). `winner_id` é o `participant_id` do vencedor.

#### Estados de match
| Estado | Significado |
|--------|-------------|
| `open` / `pending` | Aguardando para ser jogado |
| `underway` | Em andamento |
| `complete` | Reportado e finalizado |

#### Reabrir match (corrigir placar errado)
```http
PUT /tournaments/{id}/matches/{match_id}/change_state.json

{ "data": { "attributes": { "state": "reopen" } } }
```

### 3.6 Usuários e SSO

#### Obter dados do usuário autenticado
```http
GET /me.json
Authorization-Type: v2
Authorization: Bearer <token>
```

Resposta:
```json
{
  "data": {
    "id": "12345",
    "type": "users",
    "attributes": {
      "email": "player@exemplo.com",
      "username": "playerX_challonge",
      "image_url": "https://cdn.challonge.com/avatars/12345.png"
    }
  }
}
```

> Requer scope `me`.

#### Usar Challonge como SSO (identidade no jogo)

O fluxo OAuth 2.0 *Authorization Code* funciona como "entrar com Challonge":

1. Usuário clica em "Entrar com Challonge" no seu jogo
2. É redirecionado para `https://api.challonge.com/oauth/authorize?response_type=code&client_id=...&scope=me&redirect_uri=...`
3. Usuário faz login no Challonge e aprova
4. Challonge redireciona para `redirect_uri?code=...`
5. Seu backend troca o `code` por `access_token` em `POST /oauth/token`
6. Backend chama `GET /me.json` → obtém `id`, `username`, `email`, `avatar`
7. Backend cria/atualiza usuário no seu banco, mapeando `challonge_user_id` ↔ `jogo_user_id`

#### Limitações do SSO Challonge

- ✅ Dá para fazer: login básico, identidade (id/username/email/avatar), vinculação como participante via `username`
- ❌ **Não dá para fazer** (na API pública):
  - Endpoint público de perfil/histórico de usuários arbitrários (só `/me` do próprio usuário)
  - SSO corporativo / SAML / SCIM (exclusivo do Challonge Connect pago)
  - Listar "todos os torneios que o usuário X participou" sem ser o próprio usuário autenticado
  - Não há perfil competitivo com rankings/gamerTag (o Challonge não tem esse conceito)

### 3.7 Webhooks (e alternativas)

#### Status: ❌ Não disponíveis na API pública

O Challonge **não oferece webhooks** no plano gratuito/público (feature request aberto desde 2019). Webhooks só existem no **Challonge Connect** (camada comercial paga).

#### Workaround: polling com ETag

Use `If-None-Match` nas chamadas `GET` para reduzir custo:
- Se nada mudou desde a última chamada, o Challonge retorna `304 Not Modified` (corpo vazio, mais rápido)
- Ainda conta como 1 requisição no limite mensal, mas reduz processamento e banda

#### Outro workaround: iframe do bracket

Para exibir o bracket público sem consumir API:
```html
<iframe
  src="https://challonge.com/{tournament_id}/module"
  width="100%"
  height="500"
  frameborder="0">
</iframe>
```
- Atualização em tempo real **sem consumir quota de API**
- Pode ser estilizado via parâmetros de URL (`theme`, `show_final_results`, `subdomain`, etc.)
- É o "truque" para economizar quota: **deixe o Challonge renderizar o bracket, você só envia os placares**

### 3.8 Limites, quotas e considerações comerciais

| Item | v2.1 | v1 |
|------|------|----|
| **Quota free** | 500 req/mês | 5.000 req/mês |
| **Após quota** | `429 Too Many Requests` (após 01/07/2026) | Pago |
| **Auth** | OAuth 2.0 ou chave v1 | HTTP Basic + API key |
| **Torneios de 2 estágios** | ✅ Suportado | ❌ Não |
| **SDKs comunitários** | Praticamente nenhum | Vários disponíveis |
| **Formato** | JSON:API rígido | JSON ou XML, mais simples |

#### Custo de quota por torneio (estimativa)

Para um torneio single elimination com 16 participantes:
- Criar torneio: 1 req
- Adicionar 16 participantes em bulk: 1 req
- Iniciar torneio: 1 req
- Reportar 15 partidas: 15 req
- Finalizar torneio: 1 req
- **Total: ~19 requisições**

Implicações práticas:
- **v2.1 free (500/mês):** comporta ~26 torneios/mês
- **v1 free (5.000/mês):** comporta ~263 torneios/mês

#### Dica de economia de quota
- Sempre use `bulk_add` para inserir N participantes com 1 requisição
- Mantenha o estado autoritativo no seu banco; só sincronize escrita com o Challonge
- Use iframe do bracket para exibição pública (não consome API)
- Use polling com ETag se precisar ler mudanças

### 3.9 SDKs e ferramentas

#### SDKs oficiais
❌ Não há SDK oficial Challonge em nenhuma linguagem.

#### SDKs comunitários (cobrem majoritariamente v1)

| Projeto | Linguagem | Observação |
|---------|-----------|------------|
| `achallonge` | Python | Async, mantido. https://achallonge.readthedocs.io |
| `pychallonge` | Python | Histórico, ainda referenciado |
| `challonge-node` / `node-challonge` / `challonge-js-sdk` | Node.js | Vários, qualidade variável |
| `challonge-api` | PHP | Mantido pela comunidade |

> Para **v2.1**, é provável que você precise implementar o client HTTP você mesmo — mas é trivial (chamadas REST com header `Authorization: Bearer`).

#### Ferramentas oficiais
- **Developer Portal**: https://connect.challonge.com — registrar app OAuth, obter `client_id`/`client_secret`, gerar API key v1
- **Documentação Apidog**: https://challonge.apidog.io — não interativa, mas completa
- **Challonge Connect** (camada comercial paga): webhooks, SSO corporativo, "User Database Mapping"

### 3.10 Arquitetura recomendada para gamedev

```
┌─────────────┐      ┌──────────────────────────────┐      ┌──────────────┐
│   Seu Jogo  │ ───► │  Seu Backend (autoritativo)  │ ───► │  Challonge   │
│  (client)   │      │  - estado do torneio         │      │  API v2.1    │
│             │      │  - mapeia match_id interno ↔ │      │  (público)   │
│             │      │    match_id Challonge        │      └──────────────┘
│             │      │  - cacheia tokens OAuth          │            │
└─────────────┘      └──────────────────────────────┘            ▼
                              │                                  ┌──────────────┐
                              ▼                                  │ Bracket      │
                       Seu banco de dados                        │ público via  │
                       (PostgreSQL, etc.)                        │ iframe       │
                                                                └──────────────┘
```

#### Princípios de design

1. **Backend é autoritativo** — nunca consulte o Challonge para saber estado atual; mantenha no seu banco
2. **Challonge é vitrine pública** — só escreva, nunca leia (exceto no setup inicial)
3. **Iframe para o bracket** — não custa quota e dá UX melhor que qualquer renderização própria
4. **Bulk operations** — use `bulk_add` para inserir N participantes com 1 req
5. **Cache de tokens OAuth** — refresh token dura +1 semana, não force re-login

#### Fluxo completo típico

1. **Login do jogador** (opcional)
   - OAuth Authorization Code → `GET /me.json` → cria/atualiza usuário no seu banco
2. **Criação do torneio** (backend com token do organizador)
   - `POST /tournaments.json` → guarda `tournament_id` no banco
3. **Inscrição de participantes**
   - Admin adiciona via `bulk_add` **ou** jogador se inscreve via `register_me` (com próprio token OAuth)
4. **Início do torneio**
   - `PUT /tournaments/{id}/change_state.json` → `{"state": "start"}`
5. **Execução das partidas**
   - Jogo conhece `match_id` (do seu banco, que foi obtido quando o bracket foi gerado)
   - Ao final da partida, jogo envia placar para seu backend
   - Backend chama `PUT /matches/{id}.json` com `scores_csv` e `winner_id`
6. **Avanço automático do bracket**
   - O Challonge avança o bracket automaticamente ao reportar o vencedor
7. **Finalização**
   - `PUT /tournaments/{id}/change_state.json` → `{"state": "finalize"}`
8. **Exibição pública**
   - Iframe do bracket no seu site/Discord (sem custo de API)

### 3.11 Casos de uso viáveis no free

#### ✅ Cenário A: Jogo indie multiplayer pequeno (50-500 DAU)
- Login com Challonge via OAuth
- Backend cria torneio diário/semanal
- Jogo reporta placar de cada partida (1 PUT/partida)
- Bracket embed no site via iframe (grátis)
- **Consumo típico: 200-800 req/mês → v1 OK, v2.1 apertado**

#### ✅ Cenário B: Comunidade organiza liga (Discord, fórum)
- Admin cria torneio via painel próprio (1 POST)
- Players entram via `register_me` (OAuth) (1 POST cada)
- Admin ou bot reporta resultados (1 PUT por partida)
- Bracket público no Discord via iframe
- **Consumo: ~50 req/mês por torneio → folga no v1**

#### ✅ Cenário C: Jogo com matchmaking próprio, Challonge só como "vitrine"
- Você mantém o torneio internamente
- Sincroniza só o resultado final pro Challonge (1 PUT por partida concluída)
- Players acompanham no challonge.com (grátis)
- **Consumo: mínimo → v2.1 aguenta bem**

#### ❌ Cenários NÃO viáveis no free
- Webhooks / tempo real (só no Challonge Connect pago)
- SSO corporativo / SAML (pago)
- Histórico público de usuários (não existe nem no pago)
- Torneios de 2 estágios na v1 (precisa v2.1, cai pra 500 req/mês)
- API com volume alto (esports, milhares de partidas/dia)

---

## 4. Start.gg — API detalhada (comparativo)

> **Fontes oficiais consultadas:**
> - Developer Portal: https://developer.start.gg/
> - Docs (Docusaurus): https://developer.start.gg/docs/intro e subpáginas
> - Schema GraphQL completo: https://developer.start.gg/reference/query.doc.html e `mutation.doc.html`
> - API Explorer (GraphiQL online): https://developer.start.gg/explorer
> - Developer Settings (emitir tokens): https://start.gg/admin/profile/developer

### 4.1 Visão geral

| Aspecto | Detalhe |
|---------|---------|
| **Tipo de API** | **GraphQL exclusivamente** (houve REST no passado, hoje está aposentado) |
| **Endpoint único** | `https://api.start.gg/gql/alpha` |
| **Versão** | `alpha` (no path da URL) |
| **Auth** | Token pessoal (Bearer) **ou** OAuth 2.0 Authorization Code + Refresh |
| **Rate limit** | **80 req / 60 s** (média) + **1.000 objetos por requisição** (incl. aninhados) |
| **Plano pago?** | Não. A API pública é **gratuita**; não há tiers pagos documentados |
| **Criar torneio via API?** | ❌ **NÃO.** Torneios são criados só pela UI web |
| **Reportar placar via API?** | ✅ Sim — mutation `reportBracketSet` (vencedor + game data por jogo) |
| **Login com Start.gg (SSO)?** | ✅ Sim — OAuth 2.0 Authorization Code |
| **Webhooks nativos?** | ❌ **NÃO.** Comunidade usa polling + Discord webhooks |
| **SDK oficial?** | ❌ Não |
| **Foco** | Esports / Fighting Game Community (Smash, FGC, Rocket League) |

### 4.2 Autenticação

#### Modelo 1 — Token pessoal (Bearer)
1. Acesse https://start.gg/admin/profile/developer
2. Clique em "Create new token"
3. Copie imediatamente (não pode ser visualizado de novo)
4. ⏳ Expira em **1 ano**

```http
Authorization: Bearer <SEU_TOKEN>
```

#### Modelo 2 — OAuth 2.0 (Authorization Code + Refresh)

Endpoints:
- Autorização: `https://start.gg/oauth/authorize`
- Token: `https://api.start.gg/oauth/access_token`
- Refresh: `https://api.start.gg/oauth/refresh`

Fluxo padrão de 5 passos. Access token expira em **7 dias** (igual ao Challonge).

> ⚠️ Start.gg **não suporta** Device Code nem Client Credentials (o Challonge oferece ambos).

#### Scopes OAuth

| Scope | Permissão |
|-------|-----------|
| `user.identity` | Habilita `currentUser` e lê campos públicos do usuário |
| `user.email` | Habilita campo `email` em `currentUser` (exige `user.identity` junto) |
| `tournament.manager` | Acesso a seeding e setup de bracket em torneios que administra |
| `tournament.reporter` | Acesso a reportar sets em torneios que tem acesso |

### 4.3 Operações disponíveis

#### ✅ O que VOCÊ PODE fazer via API
- Ajustar/swap de seeds (`updatePhaseSeeding`, `swapSeeds`, `resolveScheduleConflicts`)
- Criar/atualizar fases dentro de evento existente (`upsertPhase`)
- Criar/atualizar grupos de fase (`updatePhaseGroups`)
- Criar/atualizar/excluir estações e waves (`upsertStation`, `deleteStation`, `upsertWave`, `deleteWave`)
- Excluir fase (`deletePhase`)
- Inscrever participantes (`registerForTournament`, com token gerado via `generateRegistrationToken`)
- **Reportar e resetar sets** (`reportBracketSet`, `updateBracketSet`, `resetSet`)
- Mudar estado do set (`markSetCalled`, `markSetInProgress`)
- Atribuir estação/stream (`assignStation`, `assignStream`)
- Atualizar VOD (`updateVodUrl`)

#### ❌ O que NÃO EXISTE (limitação crítica)
- `createTournament` — não dá para criar torneio pela API
- `updateTournament` — não dá para editar metadados do torneio
- `deleteTournament` — não dá para excluir
- `startTournament` / `changeTournamentState` — não há mutation de estado do torneio
- `createEvent` / `createPhase` autônomo — só `upsertPhase` vinculado a `eventId`

> Em outras palavras: o torneio, o evento e a fase "pai" precisam existir (criados pela UI web). A API entra para **seeding**, **reportar sets**, **chamar sets**, **atribuir estação/stream**, **resolver conflitos de agenda**, **inscrever participantes** e **atualizar VOD**.

### 4.4 Reporte de placares (mutation `reportBracketSet`)

```graphql
mutation reportSet($setId: ID!, $winnerId: ID!, $gameData: [BracketSetGameDataInput]) {
  reportBracketSet(setId: $setId, winnerId: $winnerId, gameData: $gameData) {
    id
    state
  }
}
```

Variáveis (completo):
```json
{
  "setId": 65089253,
  "winnerId": 14259653,
  "gameData": [
    {
      "winnerId": 14259653,
      "gameNum": 1,
      "entrant1Score": 0,
      "entrant2Score": 2,
      "stageId": 3,
      "selections": [
        { "entrantId": 14259653, "characterId": 3 },
        { "entrantId": 14250090, "characterId": 1 }
      ]
    }
  ]
}
```

#### Campos do `BracketSetGameDataInput`

| Campo | Tipo | Significado |
|-------|------|-------------|
| `winnerId` | ID | ID do entrant vencedor deste jogo |
| `gameNum` | Int | Número do jogo dentro do set (1, 2, 3...) |
| `entrant1Score` | Int | Placar do entrant 1 (stocks restantes no Smash) |
| `entrant2Score` | Int | Placar do entrant 2 |
| `stageId` | ID | Stage escolhido |
| `selections` | `[BracketSetGameSelectionInput]` | Lista de `{ entrantId, characterId }` |

> 💡 Para Smash e outros *platform fighters*, `entrantNScore` equivale a **stocks restantes**.

### 4.5 Usuários e SSO (perfil competitivo)

Start.gg separa `User` (conta) de `Player` (perfil competitivo). O `Player` contém os dados de interesse esportivo:

```graphql
type Player {
  id: ID
  gamerTag: String               # nickname competitivo
  prefix: String                 # prefixo (sponsor/org tag)
  rankings(limit: Int, videogameId: ID): [PlayerRank]
  sets(page: Int, perPage: Int, filters: SetFilters): SetConnection
  recentStandings(videogameId: ID, limit: Int): [Standing]
  user: User
}
```

Com scope `user.identity` (e `user.email` se quiser email), o fluxo de SSO fornece:
- `currentUser.id`, `slug`, `discriminator` — identificador estável
- `currentUser.name`, `bio`, `genderPronoun`, `birthday` (se público)
- `currentUser.location` — cidade/país
- `currentUser.player.gamerTag`, `player.prefix`, `player.rankings` — **gamertag competitivo e rankings**
- `currentUser.email` — apenas com scope `user.email`
- `currentUser.authorizations` — contas vinculadas (Twitch, Twitter)
- `currentUser.tournaments/leagues/events` — histórico competitivo paginado

> 🎮 Diferencial decisivo vs Challonge: "Login with Start.gg" dá acesso imediato ao `gamerTag` + rankings do jogador — algo que o Challonge **não tem** (Challonge não tem conceito de perfil competitivo global com ranking por jogo).

### 4.6 Limitações e plano gratuito

| Limite | Valor |
|--------|-------|
| Requisições | média de **80 req / 60 s** (janela deslizante) |
| Objetos por requisição | **1.000** (incl. aninhados) |
| Limite mensal | **Não documentado** (aparentemente inexistente) |
| Penalidade ao exceder | Requisição rejeitada com `{success:false, message:"Rate limit exceeded"}` |

#### Comparação de volume

- Start.gg: 80 req/min × 60 min × 24 h = potencial de **~115k req/dia** teórico
- Challonge v2.1 free: **500 req/mês total** (~16 req/dia)
- Challonge v1 free: **5.000 req/mês** (~166 req/dia)

> Em volume absoluto, o Start.gg é **muito mais generoso** que o Challonge free.

### 4.7 SDKs e ferramentas

#### SDKs comunitários
| Projeto | Linguagem | URL |
|---------|-----------|-----|
| `PyroPM/ggapi` | Python | https://github.com/PyroPM/ggapi |
| `pysmashgg` | Python | Wrapper histórico |
| Clientes GraphQL genéricos | JS/TS/Python/etc | `graphql-request`, `Apollo Client`, `urql`, `gql` |

#### Ferramentas oficiais
- **API Explorer** (GraphiQL hosted): https://developer.start.gg/explorer
- **Schema reference** (graphdoc): https://developer.start.gg/reference/query.doc.html
- **Developer Settings**: https://start.gg/admin/profile/developer
- **Discord oficial de devs**: https://discord.com/invite/startgg
- **GitHub do portal**: https://github.com/smashgg/developer-portal (docs open source)

### 4.8 Quando usar Start.gg

✅ **Use Start.gg se:**
- Torneios são criados por humanos (organizadores, admins) e seu jogo só precisa operá-los
- Você quer dados competitivos ricos (gamerTag, rankings, histórico)
- Seu jogo reporta placares com dados de gameplay (personagem, stage)
- Quer fazer overlay de stream / dashboard ao vivo
- Volume alto de polling/reporte sem se preocupar com quota mensal
- Foco em FGC / esports

❌ **NÃO use Start.gg se:**
- Seu jogo precisa criar torneios programaticamente em massa
- Precisa de Device Code flow (console/TV sem teclado)
- Quer webhooks (nenhum dos dois tem)

---

## 5. Comparação direta Challonge vs Start.gg

### 5.1 O que Challonge faz MELHOR

| Recurso | Challonge | Start.gg |
|---------|-----------|----------|
| Criar torneio via API | ✅ `POST /tournaments.json` | ❌ Impossível |
| Editar/excluir torneio via API | ✅ `PUT`/`DELETE` | ❌ Não há mutation |
| Mudar estado do torneio | ✅ `change_state.json` | ❌ Sem mutation |
| Formatos suportados na criação | Single/Double elim, RR, swiss, FFA, race, leaderboard, grand prix, time trial | Limitados aos que a UI expõe |
| Fluxos OAuth | Authorization Code + **Device Code** + **Client Credentials** | Apenas Authorization Code |
| Caching condicional | ✅ ETag + `If-None-Match` | ❌ Sem ETag |
| Multi-versão de API | v2.1 + v2.0 + v1 | Só `alpha` |
| SDKs comunitários | Vários (v1) | GraphQL genérico |

### 5.2 O que Start.gg faz MELHOR

| Recurso | Start.gg | Challonge |
|---------|----------|-----------|
| Modelo de API | GraphQL (pede só o que precisa) | REST (respostas fixas) |
| Dados esportivos ricos | ✅ `gamerTag`, `prefix`, `rankings`, `recentStandings`, personagens/stages por game | ❌ Sem perfil competitivo |
| Reporte de set detalhado | ✅ `gameData` com `characterId`, `stageId`, stocks por game | ⚠️ Só placar (vencedor + scores) |
| Limite de API gratuito | ✅ 80 req/min, sem limite mensal | ❌ 500/mês (v2.1) / 5.000/mês (v1) |
| Perfil de jogador (SSO) | ✅ `gamerTag` + rankings | ⚠️ Só `username`/`email` |
| Stream queues / stations / waves | ✅ Modelado nativamente | ⚠️ `station_options` existe, mas sem `streamQueue` |
| Comunidade FGC/esports | ✅ Plataforma padrão | Foco genérico |
| Schema navegável | ✅ graphdoc + GraphiQL online | ❌ Apidog (não interativo) |
| Doc open source | ✅ GitHub aceita PRs | ❌ Fechada |

### 5.3 Recursos exclusivos

#### Exclusivos do Start.gg
- `reportBracketSet` com game data completo (personagem + stage + stocks por jogo)
- Modelo de Player global com rankings (`PlayerRank` por videogame) — identidade competitiva portável
- `streamQueue` e gerenciamento de estações/waves como cidadãos de primeira classe
- `generateRegistrationToken` + `registerForTournament` — inscrição programática em nome do usuário
- Schema GraphQL com introspecção — descobre tudo da API em runtime
- League (liga) — conjuntos de torneios com classificação agregada

#### Exclusivos do Challonge
- CRUD completo de torneio via API (criar/editar/excluir/mudar estado)
- Múltiplos formatos de torneio suportados via API
- OAuth Device Code (para consoles/TVs)
- OAuth Client Credentials (acesso aplicacional sem usuário)
- ETag + `If-None-Match` para reduzir custo de polling
- Iframe de bracket público (sem consumir API)
- Múltiplas versões de API simultâneas (v1, v2.0, v2.1)

---

## 6. Recomendação para o seu cenário

Pelos requisitos identificados nas perguntas feitas:

1. **Integrar API para hosting de torneios** → necessita criar torneios programaticamente
2. **Jogo reporta placares automaticamente** → necessita endpoint de reporte
3. **Usar conta da plataforma como identidade no jogo** → necessita SSO

### 6.1 Veredito por requisito

| Requisito | Melhor escolha | Justificativa |
|-----------|----------------|---------------|
| Hosting de torneios com criação automática | **Challonge** | Único que permite CRUD completo de torneios via API |
| Reporte automático de placares | **Ambos** (Challonge mais simples, Start.gg mais rico) | Challonge: `PUT /matches/{id}` com `scores_csv`. Start.gg: `reportBracketSet` com `gameData` (personagem, stage, stocks). |
| Login com conta da plataforma | **Start.gg** (identidade competitiva) ou **Challonge** (login básico) | Start.gg expõe `gamerTag` + rankings; Challonge só `username`/`email`. Para jogo competitivo, Start.gg é superior; para login básico, Challonge é suficiente. |
| Volume alto de API sem estourar quota | **Start.gg** (80 req/min >> 500 req/mês) | Start.gg permite polling agressivo; Challonge exige otimização rigorosa |

### 6.2 Recomendação principal

**Para o cenário de "jogo com hosting automatizado de torneios", o Challonge é a escolha mais adequada**, por ser a única das duas plataformas que permite criar torneios programaticamente. Sem isso, todo torneio exigiria criação manual na UI web — inviável para sistemas que geram brackets sob demanda (ex.: ranked por temporada, torneios diários automáticos).

### 6.3 Arquitetura híbrida (opcional, recomendada para jogos competitivos)

Se o jogo tem componente competitivo forte e quer o melhor dos dois mundos:

```
┌──────────────────────────────────────────────────────────┐
│  Login do jogador                                        │
│  → OAuth Start.gg → pega gamerTag, rankings, histórico   │
│  → (alternativa: OAuth Challonge → username/email)       │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────┐
│  Seu Backend (autoritativo)                              │
│  → Cria torneio no Challonge (POST /tournaments)         │
│  → Mapeia player_id interno ↔ challonge_participant_id   │
│  → Guarda estado do torneio internamente                 │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────┐
│  Durante partida                                         │
│  → Jogo envia placar + (opcional) gameplay data p/ backend│
│  → Backend reporta no Challonge (PUT /matches/{id})      │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────┐
│  Bracket público                                         │
│  → iframe do Challonge (grátis, não consome API)         │
└──────────────────────────────────────────────────────────┘
```

#### Vantagens do híbrido
- Provisionamento automático de torneios (via Challonge API)
- Identidade competitiva rica (via Start.gg SSO)
- Sem custo de API (Challonge v1 free com 5.000 req/mês + Start.gg free ilimitado por minuto)
- Bracket público gratuito via iframe

#### Desvantagem
- Dois sistemas para integrar e manter
- Usuário precisa ter conta nas duas plataformas (ou só na que você escolher como SSO principal)

### 6.4 Próximos passos sugeridos

1. **Decidir entre v1 e v2.1 do Challonge**:
   - Se precisar de torneios de 2 estágios ou OAuth avançado → v2.1
   - Se quiser simplicidade, mais SDKs prontos e 10x mais quota free → v1
2. **Registrar app no Developer Portal do Challonge** (`connect.challonge.com`) para obter `client_id`/`client_secret` (v2.1) ou API key (v1)
3. **Implementar PoC do fluxo mínimo**:
   - Criar torneio via API
   - Adicionar participantes (bulk_add)
   - Iniciar torneio
   - Reportar placar de uma partida
   - Exibir bracket via iframe
4. **Se optar pelo híbrido**, registrar app também no Developer Portal do Start.gg (`start.gg/admin/profile/developer`) e implementar o fluxo OAuth para captura de `gamerTag` + `rankings`
5. **Planejar estratégia de cache/polling** já que nenhuma das duas plataformas oferece webhooks no free

---

## 7. Apêndice — Referências

### 7.1 Challonge — links oficiais

| Recurso | URL |
|---------|-----|
| Documentação (Apidog) | https://challonge.apidog.io |
| Developer Portal (registrar app, obter chave) | https://connect.challonge.com |
| Página comercial Challonge Connect | https://challonge.com/connect |
| Iframe de bracket público | `https://challonge.com/{tournament_id}/module` |
| Referência comunitária v1 (Python) | https://achallonge.readthedocs.io/en/latest/api.html |

### 7.2 Start.gg — links oficiais

| Recurso | URL |
|---------|-----|
| Developer Portal | https://developer.start.gg/ |
| Docs (Docusaurus) | https://developer.start.gg/docs/intro |
| API Explorer (GraphiQL) | https://developer.start.gg/explorer |
| Schema reference (Query) | https://developer.start.gg/reference/query.doc.html |
| Schema reference (Mutation) | https://developer.start.gg/reference/mutation.doc.html |
| Developer Settings (tokens) | https://start.gg/admin/profile/developer |
| GitHub do portal (docs open source) | https://github.com/smashgg/developer-portal |
| Discord oficial de devs | https://discord.com/invite/startgg |

### 7.3 Exemplo mínimo — Challonge v1 (curl)

```bash
# Criar torneio
curl -X POST "https://api.challonge.com/v1/tournaments.json" \
  -u "USUARIO:API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "tournament": {
      "name": "Torneio Teste",
      "url": "torneio-teste-001",
      "tournament_type": "single elimination"
    }
  }'

# Adicionar participantes em bulk
curl -X POST "https://api.challonge.com/v1/tournaments/torneio-teste-001/participants/bulk_add.json" \
  -u "USUARIO:API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "participants": [
      {"name": "Player1", "seed": 1},
      {"name": "Player2", "seed": 2},
      {"name": "Player3", "seed": 3},
      {"name": "Player4", "seed": 4}
    ]
  }'

# Iniciar torneio
curl -X POST "https://api.challonge.com/v1/tournaments/torneio-teste-001/start.json" \
  -u "USUARIO:API_KEY"

# Listar matches (para descobrir match_id)
curl "https://api.challonge.com/v1/tournaments/torneio-teste-001/matches.json" \
  -u "USUARIO:API_KEY"

# Reportar placar de uma match
curl -X PUT "https://api.challonge.com/v1/tournaments/torneio-teste-001/matches/MATCH_ID.json" \
  -u "USUARIO:API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "match": {
      "scores_csv": "3-1,3-2,3-0",
      "winner_id": PARTICIPANT_ID_VENCEDOR
    }
  }'

# Finalizar torneio
curl -X POST "https://api.challonge.com/v1/tournaments/torneio-teste-001/finalize.json" \
  -u "USUARIO:API_KEY"
```

### 7.4 Exemplo mínimo — Start.gg (curl)

```bash
# Buscar torneio por slug
curl -X POST "https://api.start.gg/gql/alpha" \
  -H "Authorization: Bearer $STARTGG_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "query ($slug: String) { tournament(slug: $slug) { id name startAt events { id name } } }",
    "variables": { "slug": "genesis-9-1" }
  }'

# Listar sets de um evento
curl -X POST "https://api.start.gg/gql/alpha" \
  -H "Authorization: Bearer $STARTGG_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "query ($eventId: ID!) { event(id: $eventId) { sets(perPage: 50) { nodes { id state slots { entrant { id name } } } } } }",
    "variables": { "eventId": "EVENT_ID" }
  }'

# Reportar placar (simples — só vencedor)
curl -X POST "https://api.start.gg/gql/alpha" \
  -H "Authorization: Bearer $STARTGG_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation ($setId: ID!, $winnerId: ID!) { reportBracketSet(setId: $setId, winnerId: $winnerId) { id state } }",
    "variables": { "setId": "SET_ID", "winnerId": "ENTRANT_ID_VENCEDOR" }
  }'

# Reportar placar (rico — com personagem, stage, stocks)
curl -X POST "https://api.start.gg/gql/alpha" \
  -H "Authorization: Bearer $STARTGG_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "mutation ($setId: ID!, $winnerId: ID!, $gameData: [BracketSetGameDataInput]) { reportBracketSet(setId: $setId, winnerId: $winnerId, gameData: $gameData) { id state } }",
    "variables": {
      "setId": "SET_ID",
      "winnerId": "ENTRANT_ID_VENCEDOR",
      "gameData": [
        {
          "winnerId": "ENTRANT_ID_VENCEDOR",
          "gameNum": 1,
          "entrant1Score": 0,
          "entrant2Score": 2,
          "stageId": 3,
          "selections": [
            {"entrantId": "ENTRANT_ID_1", "characterId": 3},
            {"entrantId": "ENTRANT_ID_2", "characterId": 1}
          ]
        }
      ]
    }
  }'

# Obter usuário autenticado (currentUser)
curl -X POST "https://api.start.gg/gql/alpha" \
  -H "Authorization: Bearer $STARTGG_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "query": "{ currentUser { id slug name email player { gamerTag prefix rankings { rank title } } } }"
  }'
```

---

*Documento gerado a partir da documentação oficial das duas plataformas e da análise comparativa das duas APIs para o caso de uso de hosting de torneios em jogos.*
