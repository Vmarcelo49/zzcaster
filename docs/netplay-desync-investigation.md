# zzcaster Netplay Desync Investigation

> **Purpose:** Living investigation log for zzcaster's netplay desync bugs.
> Read this entirely before making changes — it captures the history, the
> current open issues, and the hard-won findings that must not be rediscovered.
>
> **Two open issues as of 2026-06-29:**
> 1. **chara_intro entry divergence** (PRIMARY — root cause of the freeze
>    users are seeing in delay mode) — documented in §A below
> 2. **rollback small drift at frame 149** (SECONDARY — rollback-mode-only,
>    on the `fix/small-drift-animation-states` branch, not yet finished) —
>    documented in §B below

---

## Contexto

ZZCaster é um port em Zig 0.16 do CCCaster (netplay launcher para MBAACC).
Estamos resolvendo desyncs de netplay. O trabalho foi feito na branch `main`
do repo `git@github.com:Vmarcelo49/zzcaster.git`.

**Antes de continuar:** clone o repo, leia `docs/rollback-desync-investigation.md`
e `docs/cccaster-vs-zzcaster-diffs.md` para contexto completo. O repo de
referência do CCCaster (C++) está em `https://github.com/Rhekar/CCCaster` —
clone se precisar comparar implementações.

## Setup

- **Repo zzcaster:** `git@github.com:Vmarcelo49/zzcaster.git`
- **Repo CCCaster ref:** `https://github.com/Rhekar/CCCaster.git`
- **SSH key:** o usuário fornece uma chave OpenSSH privada. Salve em
  `/home/z/my-project/.ssh/id_ed25519` com header/footer
  `-----BEGIN/END OPENSSH PRIVATE KEY-----`, chmod 600. Use o shim em
  `/home/z/my-project/.ssh/ssh-shim.py` (requer `paramiko`) já que não há
  `openssh-client` instalado. Configure:
  `git config core.sshCommand "/home/z/my-project/.ssh/ssh-shim.py -i /home/z/my-project/.ssh/id_ed25519 -o StrictHostKeyChecking=no"`
- **Build:** `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast`
  → `zig-out/bin/{zzcaster.exe,hook.dll}`
- **Toolchain:** Zig 0.16.0 de
  `https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz`
  (sha256: `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`)
- **Usuário:** `vmarcelo49 <vmarcelo49@gmail.com>` — todos os commits devem
  ser authored como este usuário.
- **TZ do usuário:** America/Sao_Paulo (fala português, responde em português)

---

## §A — chara_intro entry divergence (PRIMARY ISSUE)

> **Status:** open, under active investigation (2026-06-29)
> **Mode affected:** delay mode (rollback=0) — and likely rollback mode too,
> but most visible in delay mode because there's no rollback to paper over it
> **Symptom:** first online match after launching zzcaster freezes at the
> chara_intro → in_game transition. Game window stops rendering (no crash,
> like it activated sleep). Closing both instances + retrying sometimes works.

### Root cause (confirmed via dual-peer logs)

The two peers enter the `chara_intro` state at **different `world_timer`
values**, 1 frame apart. This 1-frame divergence at the loading→chara_intro
transition propagates through 207 frames of chara_intro (the per-frame
lockstep passes because both peers are at index=3, so they pass each other
regardless of underlying game-state drift), then bites at the
chara_intro→in_game transition where the index advances.

### Evidence (from `dll_512.log` host + `dll_640.log` client, 2026-06-29)

**Config (both peers, delay mode):**
```
Config: netplay=true host=true  ... delay=1 rollback=0 port=1234 local_udp_port=0
Config: netplay=true host=false ... delay=1 rollback=0 port=1234 local_udp_port=0
```

**The smoking gun — loading → chara_intro transition:**
```
HOST   (PID 512) line 49: DIAG: transition to chara_intro at world_timer=1082 (index=3)
CLIENT (PID 640) line 50: DIAG: transition to chara_intro at world_timer=1083 (index=3)
```
**1 frame difference.** Both peers transitioned to chara_intro at index=3,
but their game state was already 1 frame out of sync before chara_intro
even started.

**Consequence — chara_intro → in_game transition (207 frames later):**
```
HOST   line 261: Round start (counter 0 -> 1) — chara_intro -> InGame (frame=207, world_timer=1290)
HOST   line 262: DIAG: transition to in_game at world_timer=1290 (index=4)
HOST   line 265: RNG state sent (index=4, attempt=1)
HOST   line 266: RNG sync confirmed by peer ack (index=4)
HOST   (log ends — host is now in in_game waiting for remote's index-4 input)

CLIENT line 263: DIAG: lockstep passed for chara_intro (frame=207, index=3, remote_end_frame=208)
CLIENT line 264: DIAG: lockstep passed for chara_intro (frame=208, index=3, remote_end_frame=209)
CLIENT line 264: Remote transition index: 4 (remote_inputs.end_index now 5)
CLIENT line 265: Cached future remote RNG state (index=4, current=3)
CLIENT line 266: Sent RNG_ACK (index=4)
CLIENT line 267: Remote reached transition index 3 — starting 10s input-wait countdown
CLIENT line 268: [WARN] Waiting for remote input... (5s elapsed, enet_connected=true, remote_end_index=4, local_index=3)
```

**What happened:**
- HOST's game hit `round_start_counter 0→1` at frame 207, world_timer=1290
  → transitioned to in_game (index 4)
- CLIENT's game (1 frame behind from the start) was still at chara_intro
  frame 207-208 — it never saw `round_start_counter 0→1` because its game
  state was 1 frame behind
- CLIENT received HOST's index-4 RNG state ("Cached future remote RNG
  state (index=4, current=3)") but stayed at index=3 because its own game
  hadn't reached round-start yet
- CLIENT is now stuck waiting for HOST's index-3 input that doesn't exist
  anymore (HOST is at index 4)
- HOST is stuck waiting for CLIENT's index-4 input that will never come
  (CLIENT is stuck at index 3)
- **Deadlock. ENet still connected. No crash. Game window frozen.**

### Why the per-frame lockstep doesn't catch this

The per-frame lockstep (`DIAG: lockstep passed for chara_intro`) only checks
that both peers are at the same `index` (3 = chara_intro). It does NOT check
that their underlying `world_timer` values match. So the 1-frame divergence
at entry (1082 vs 1083) is invisible to the lockstep — both peers happily
report "lockstep passed" for 207 frames while their game states drift.

The drift only becomes visible at the chara_intro→in_game transition,
where `round_start_counter` (an ASM-driven counter incremented by the
`applyDetectRoundStart` code cave) fires for the host but not the client,
because the client's game state hasn't reached the round-start trigger
point yet.

### Key files to investigate

- `src/dll/netplay_manager.zig` — `onStateTransition` (loading → chara_intro),
  `checkRoundStart` (chara_intro → in_game via `round_start_counter`)
- `src/dll/asm_hacks.zig` — `applyDetectRoundStart` (the code cave that
  increments `round_start_counter`), `applyHijackIntroState` (NOPs the
  game's natural intro_state 1→0 progression)
- `src/dll/dllmain.zig` — `lazyInit` (applies `hijackIntroState` +
  `stage_animation_off` BEFORE `waitForConfig` to eliminate the race where
  the game reaches chara_intro before the hack is applied)
- `src/dll/frame_step.zig` — `frameStepNetplay` (per-frame lockstep wait loop)

### Hypotheses for the 1-frame entry divergence (NOT YET VERIFIED)

1. **`hijackIntroState` timing** — applied in `lazyInit` before `waitForConfig`,
   but the two peers might reach the chara_intro state machine point at
   different frames due to loading-time differences. The hack NOPs the
   intro_state 1→0 progression, but if one peer's game state is already at
   intro_state=0 when the hack lands, that peer advances immediately while
   the other waits.

2. **`stage_animation_off` timing** — applied alongside `hijackIntroState`.
   If this flag affects when the game transitions loading→chara_intro,
   a 1-frame difference in when it's applied could cause the divergence.

3. **Loading state duration** — the loading→chara_intro transition is driven
   by the game's internal loading completion. If one peer's MBAA.exe loads
   1 frame faster (disk cache, CPU scheduling), it enters chara_intro 1
   frame earlier. The lockstep should catch this, but if the transition
   index (3) is set before the lockstep wait fires, the 1-frame gap is
   baked in.

4. **`world_timer` increment timing** — `world_timer` is incremented by the
   game's main loop, which zzcaster hooks. If the hook fires at a different
   point in the loop on the two peers (due to the 1-frame loading
   difference), the `world_timer` at the chara_intro transition differs.

### Next steps for investigation

1. **Add `world_timer` to the lockstep check** — currently the lockstep only
   checks `index`. Add a `world_timer` comparison so a 1-frame divergence
   at chara_intro entry is caught immediately (and the peer that's ahead
   waits for the one that's behind, rather than both advancing to index=3
   with divergent state).

2. **Log the exact frame at which `hijackIntroState` + `stage_animation_off`
   are applied** relative to the game's first `frameStep` call. If the two
   peers apply the hack at different frames, that's the divergence source.

3. **Check whether CCCaster has this same 1-frame entry divergence** —
   CCCaster's `getbase()` + lock-at-entry-point mechanism (see
   `tools/Launcher.cpp:57-183`, documented in `src/launcher/launcher.zig`
   comment block) might enforce stricter timing than zzcaster's
   CREATE_SUSPENDED approach. This is speculative — needs verification.

### Important: do NOT confuse with the rollback small drift (§B)

This is a **different bug** from the rollback small drift at frame 149
documented in §B below. The key differences:

| | §A chara_intro entry divergence | §B rollback small drift |
|---|---|---|
| **Mode** | delay mode (rollback=0) | rollback mode (rollback=4) |
| **When** | chara_intro → in_game transition (frame 207) | in_game frame 149 |
| **Root cause** | 1-frame world_timer divergence at chara_intro entry | unknown — RNG matches, camera/P1.x drift |
| **RNG** | matches (sync confirmed) | matches |
| **Symptom** | freeze/deadlock at in_game entry | small drift, desync detected later |
| **Branch** | `main` | `fix/small-drift-animation-states` (RC, not finished) |

**Solving §A may or may not solve §B.** They could share a root cause
(timing divergence at a state transition) or be independent. Investigate
§A first because it's the one users are hitting in delay mode.

---

## §B — rollback small drift at frame 149 (SECONDARY ISSUE)

> **Status:** open, release candidate on branch `fix/small-drift-animation-states`
> (not fully tested — consider it unfinished as of 2026-06-29)
> **Mode affected:** rollback mode only (rollback=4)
> **Symptom:** desync at frame 149 with small drift (camera Δ161, P1.x Δ250),
> RNG matching. Occurs especially in the second match after rematch.

### Sintoma
- Desync no frame 149 (index 4, frame 149 = `indexed_frame=0x400000095`)
- `camera_x` e `P1.x` divergem (Δ161 e Δ250 respectivamente)
- **RNG hash: MATCH** (determinism root está OK)
- Ocorre mais na segunda partida após rematch

### Comparação de Approaches

| Lockstep | Desync | RNG | Magnitude |
|---|---|---|---|
| Index-based | ✗ Massive | **Mismatch** | camera Δ19613, P1.x Δ45227 |
| Per-frame (atual) | ✗ Small drift | **Match** | camera Δ161, P1.x Δ250 |

O per-frame é claramente melhor. O small drift é o próximo a investigar.

### Hipóteses para o Small Drift

1. **Cooperative sleep** (`recommendPerFrameSleepMs` em
   `frame_step.zig:128-135`) — pode estar adicionando latência extra durante
   `chara_intro`/`skippable`, onde não é necessário (inputs suprimidos,
   animação determinística)

2. **RTT EMA** (`updateRttEma` em `netplay_manager.zig`) — alimentado durante
   `chara_intro`/`skippable`, pode ter valores stale

3. **Frame rate limiter** (`limitFrameRate` em `dllmain.zig`) — busy-wait pode
   se comportar diferente quando lockstep pausa o frameStep

### Próximo Passo Sugerido

Desabilitar o cooperative sleep e o RTT EMA durante `chara_intro`/`skippable`
(esses estados não precisam de time-sync). Em `frame_step.zig:128`:

```zig
// Atual:
if (n.state == .in_game and !n.isRerunning()) {
    const sleep_ms = n.recommendPerFrameSleepMs();
    ...
}

// Sugerido:
if (n.state == .in_game and !n.isRerunning()) {
    const sleep_ms = n.recommendPerFrameSleepMs();
    ...
}
// (não mudar — já é gated em .in_game)
```

Na verdade o sleep já é gated em `.in_game`. O problema pode ser que o
lockstep wait durante `chara_intro` introduz variabilidade no timing que o
`limitFrameRate` não compensa. Investigue a interação entre lockstep wait e
frame limiter.

---

## Estado Atual (commit `671a9da` no main, 2026-06-29)

### O que está funcionando
- **Delay mode (rollback=0)**: Funciona online APÓS a primeira partida —
  mas a **primeira partida** frequentemente freeze devido ao bug §A
  (chara_intro entry divergence). Os fixes que levaram ao delay mode
  funcionar (quando não freeze) foram:
  - `hijackIntroState` aplicado antes de `waitForConfig` (race condition fix)
  - `clearIntroStateDuringRollback` em todos os modos netplay (não só rollback)
  - Supressão de inputs durante `chara_intro` e `skippable`
  - Per-frame lockstep para `chara_intro`, `skippable`, `retry_menu`

### O que ainda tem problema
- **§A chara_intro entry divergence** (PRIMARY) — freeze na primeira partida
  em delay mode. Root cause identificado: 1-frame world_timer divergence no
  loading→chara_intro transition. Investigações em andamento.
- **§B rollback small drift** (SECONDARY) — desync intermitente com small
  drift no frame 149 em rollback mode. RC na branch
  `fix/small-drift-animation-states`, não terminado.

---

## Histórico de Commits (em ordem cronológica)

Commits 1-16 são do trabalho pré-QA (documentado na versão original deste
arquivo, então chamado `HANDOFF.md`).
Commits 17+ são da QA cleanup pass iniciada em 2026-06-29.

1. **`4509eea`** — Gate `hijackIntroState` em `is_netplay` em vez de
   `rollback > 0` (delay mode fix inicial)
2. **`5a5c13c`** — Aplicar `hijackIntroState` ANTES de `waitForConfig`
   (race condition: jogo chegava em chara_intro antes do hack ser aplicado)
3. **`3c51919`** — Documentação da investigação
   (`docs/rollback-desync-investigation.md`)
4. **`18221dc`** — Flag `enable_rollback_min_frame_delay_guard` (default
   false, match CCCaster)
5. **`220b8a0`** — `clearIntroStateDuringRollback` em todos os modos netplay
   + log state pool erosion
6. **`d07dd8f`** — `setRemote` break após primeira misprediction + suprimir
   rollbacks ao frame 0
7. **`434cbb1`** — Gate chara_intro catch-up mash (depois supersedido por
   supressão total de inputs)
8. **`2664a43`** — Suprimir TODOS os inputs durante `chara_intro` (não só
   auto mash)
9. **`0e4760c`** — Lockstep block para `chara_intro` (index-based)
10. **`0dc28ab`** — Mesmo para `skippable` (tela de vitória)
11. **`e4a8ba5`** — Mesmo para `retry_menu`
12. **`d6a93b6`** — Per-frame lockstep para
    `chara_intro`/`skippable`/`retry_menu` (tentativa de fix da segunda partida)
13. **`d1899e8`** — REVERT do per-frame para index-based (regressão: small
    drift com delay=2) — **este foi um erro**
14. **`6495b94`** — Logging diagnóstico (`DIAG:` lines)
15. **`ed1b458`** — Documentação `docs/cccaster-vs-zzcaster-diffs.md`
16. **`515df3b`** — REVERT de volta ao per-frame lockstep (logs confirmaram
    que index-based causa divergência massiva)
17. **`2aa714a`** — docs: handoff document for next agent session (último
    commit antes da QA cleanup pass)
18. **`a6f0eec`** — fix(launcher): CLI netplay sends 9-byte IPC header to
    match DLL expectation (QA A1)
19. **`b70b00d`** — fix(launcher): drop dead orig_bytes read, document
    CCCaster divergence (QA A2)
20. **`d682a20`** — fix(net): nat_probe.resolveHost endianness — port
    relay_client.zig fix (QA A3)
21. **`8aa8664`** — refactor(net): dedupe ws2_32 extern bindings into shared
    module (QA B1)
22. **`671a9da`** — fix(ui): initialize rollback/wincount text fields from
    config (QA — found while investigating §A)

---

## Arquivos-Chave

- `src/dll/netplay_manager.zig` — NetplayManager, FSM, lockstep, rollback,
  sync hash. **`onStateTransition` (loading→chara_intro) e `checkRoundStart`
  (chara_intro→in_game) são os pontos críticos para §A.**
- `src/dll/rollback.zig` — InputBuffer, StatePool, loadStateForFrame
- `src/dll/rollback_regions.zig` — 271 regiões de memória para save/restore
- `src/dll/frame_step.zig` — frameStepNetplay, lockstep wait loop,
  cooperative sleep. **O lockstep wait loop é onde §A se manifesta como
  deadlock.**
- `src/dll/dllmain.zig` — lazyInit, applyPostLoadHacks, frameStep,
  limitFrameRate. **`lazyInit` aplica `hijackIntroState` +
  `stage_animation_off` antes de `waitForConfig` — timing deste apply é
  suspeito #1 para §A.**
- `src/dll/asm_hacks.zig` — hijackIntroState, detectRoundStart,
  round_start_counter. **`applyDetectRoundStart` (code cave que incrementa
  `round_start_counter`) é o trigger que dispara chara_intro→in_game —
  dispara no host mas não no client quando §A ocorre.**
- `docs/rollback-desync-investigation.md` — Análise dos 3 suspeitos do
  desync de rollback (§B)
- `docs/cccaster-vs-zzcaster-diffs.md` — Features do CCCaster não portadas
  + análise do drift

---

## Descobertas Importantes (para não redescobrir)

### 1. CCCaster RELEASE não detecta desyncs em rollback mode
O handler de `SyncHash` é `#ifndef RELEASE` (`DllMain.cpp:1432-1436`). Em
RELEASE, `remoteSync` nunca recebe entries. zzcaster detecta no frame 149,
CCCaster não detectaria. **Não existe "CCCaster rollback funcionando" como
referência.**

### 2. `rollback_min_frame_delay = 8` era um bug
O guard silenciosamente dropava mispredictions de early-frame. `lcf_frame` é
fixo — se for 5, `5 < 8` é true para sempre, rollback nunca dispara. Agora é
default false (`enable_rollback_min_frame_delay_guard`).

### 3. Frame-0 rollbacks causam erosão do state pool
`loadState` apaga todos os states depois do carregado. Re-run não salva
intermediários. Rollback ao frame 0 → pool vira
`[frame_0, frame_at_rerun_end]` → rollbacks subsequentes caem no frame 0.
Por isso suprimimos rollbacks ao frame 0 em `checkRollback`.

### 4. `InputBuffer.get` faz fallback cross-index
Retorna `last_inputs` de índices anteriores se não há input exato. Igual ao
CCCaster. Pode causar mispredictions falsas no frame 0 (inputs stale do
chara_intro). Já mitigado pela supressão de frame-0 rollbacks.

### 5. `setRemote` agora faz break após primeira misprediction
Matches CCCaster (`InputsContainer.hpp:73-81`). Antes continuava verificando,
podendo sobrescrever `lcf` com frame mais tarde.

### 6. Per-frame lockstep é necessário
Index-based permite o peer rápido avançar frames enquanto o lento carrega.
Logs mostraram remote 30 frames à frente no frame 0 do chara_intro.
Per-frame corrige isso. **MAS per-frame lockstep só verifica `index`, não
`world_timer` — por isso §A não é pego pelo lockstep. Ver §A hipóteses.**

### 7. `hijackIntroState` + `stage_animation_off` devem ser aplicados antes de `waitForConfig`
Senão o jogo chega em chara_intro antes do hack ser aplicado → intro_state
progride naturalmente em frame não-determinístico → desync. Aplicamos
incondicionalmente e revertemos se for offline/spectator. **O timing exato
deste apply em relação ao primeiro frameStep é suspeito #1 para §A.**

### 8. §A e §B são bugs diferentes
Não confunda. Ver tabela comparativa no §A. **Solving §A may or may not
solve §B** — could share a root cause (timing divergence at a state
transition) or be independent. Investigate §A first because it's the one
users are hitting in delay mode.

---

## Features do CCCaster Não Portadas (documentadas em `docs/cccaster-vs-zzcaster-diffs.md`)

1. Reset de variáveis ASM ao sair do retry_menu (`currentMenuIndex`,
   `menuConfirmState`, `targetMenuState`, `targetMenuIndex`)
2. Gerenciamento de `_startIndex` (`eraseIndexOlderThan` preserva inputs
   recentes)
3. Sistema de retry menu sincronizado (`_localRetryMenuIndex` /
   `_remoteRetryMenuIndex` via mensagens `MenuIndex`)
4. Variáveis ASM não portadas (`currentMenuIndex`, `menuConfirmState`,
   `numLoadedColors`, `autoReplaySaveState`)
5. `exportResults` ao entrar no RetryMenu
6. `CC_MENU_STATE_COUNTER_ADDR` para timing de menu

**Nenhuma dessas explica diretamente §A ou §B**, mas podem ser relevantes
para bugs futuros.

---

## Como o Usuário Testa

1. Build: `bash scripts/build-and-deploy.sh` (faz build + deploy para a
   pasta do jogo)
2. Abre zzcaster.exe na pasta do jogo
3. Testa online com um amigo (diferentes estados/máquinas para expor
   timing issues) OU localhost com 2 instâncias
4. Config: `defaultRollback=0` para delay mode, `defaultRollback=4` para
   rollback mode. **Nota: o campo de texto na UI de "Game Config" agora
   reflete o valor do config.ini (fix em `671a9da`); antes sempre mostrava
   "4".**
5. Logs da DLL: `dll_<pid>.log` na pasta `zzcaster/` ao lado do MBAA.exe
   (envia os dois logs de ambos os peers)
6. Procura por `DESYNC detected`, `DIAG:`, `transition to`, `Round start`,
   `Waiting for remote input`

### Padrão de freeze da §A (reconhecer pelos logs)

```
HOST:   Round start (counter 0 -> 1) — chara_intro -> InGame (frame=N, world_timer=W)
HOST:   DIAG: transition to in_game at world_timer=W (index=4)
HOST:   RNG state sent (index=4)
HOST:   (log ends — host waiting for client's index-4 input)

CLIENT: DIAG: lockstep passed for chara_intro (frame=N, index=3, remote_end_frame=N+1)
CLIENT: Cached future remote RNG state (index=4, current=3)
CLIENT: [WARN] Waiting for remote input... (5s elapsed, enet_connected=true, remote_end_index=4, local_index=3)
```

**Key diagnostic:** compare the `world_timer` values at the
`transition to chara_intro` log line on both peers. If they differ by even
1 frame, that's §A.

---

## Padrões de Desync (reconhecer pelos logs)

| Padrão | Causa | Status |
|---|---|---|
| RNG mismatch + camera/P1.x divergência massiva | Lockstep insuficiente (index-based) | ✗ Resolvido (per-frame) |
| RNG match + camera/P1.x small drift no frame 149 | Per-frame lockstep + timing variability (§B) | **Em investigação (branch RC)** |
| RNG mismatch + P1/P2 seq_state divergente | Skip de intro assimétrico | ✗ Resolvido (supressão de inputs) |
| RNG match + camera/P1.x/P2.x offset uniforme | State pool erosion (frame-0 rollbacks) | ✗ Resolvido (supressão frame-0) |
| **Freeze no chara_intro→in_game transition, host vê round_start mas client não, world_timer diverge por 1 frame no loading→chara_intro entry** | **§A chara_intro entry divergence** | **PRIMARY ISSUE — em investigação** |

---

## Notas para o Próximo Agente

1. **Sempre peça logs de AMBOS os peers.** Comparar os dois é essencial.
   Para §A, compare especificamente os `world_timer` values na linha
   `transition to chara_intro`.
2. **Não faça mudanças sem confirmar com logs.** Já cometemos erros por
   adivinhar (ex: revert `d1899e8`).
3. **Documente cada fix com comentários no código.** O usuário valoriza isso.
4. **Commits atômicos com mensagens detalhadas.** Inclua os números de delta
   do desync nos commits.
5. **O usuário testa online com um amigo E em localhost com 2 instâncias.**
   Resultados podem variar entre localhost e online devido a latency.
6. **§A (chara_intro entry divergence) é o PRIMARY ISSUE.** §B (rollback
   small drift) é secondary, na branch `fix/small-drift-animation-states`,
   não terminado. Foque em §A primeiro.
7. **O usuário fala português.** Responda em português.
8. **SSH push funciona** com o shim paramiko. Não tente instalar
   openssh-client.
9. **Sempre verifique contra o CCCaster reference** antes de assumir que algo
   é um bug zzcaster — o CCCaster é a "pure truth". Clone de
   `https://github.com/Rhekar/CCCaster` está em `/home/z/my-project/CCCaster`
   se disponível.

---

## Próximos Passos (plano mental do usuário)

1. **Investigar §A** — chara_intro entry divergence (1-frame world_timer
   difference no loading→chara_intro transition). Adicionar `world_timer`
   ao lockstep check é o próximo passo sugerido.
2. **Terminar §B** — validar o RC na branch `fix/small-drift-animation-states`
   (não mexer até §A estar resolvido, podem compartilhar root cause).
3. Se §A resolvido, partir para melhorar rollback (state pool, determinism).
4. Considerar portar features do CCCaster (retry menu sync, etc.) conforme
   necessário.

---

## Documentos de Referência

- `docs/rollback-desync-investigation.md` — Análise dos 3 suspeitos do
  desync de rollback (§B específico)
- `docs/cccaster-vs-zzcaster-diffs.md` — Features do CCCaster não portadas
  + análise do drift atualizada
- `docs/roadmap.md` — Roadmap geral do projeto
- `docs/rollback-improvement-plan.md` — Plano de melhorias de rollback
- `docs/nat-traversal-protocol.md` — Protocolo de NAT traversal (autoritativo
  para wire format)
- `docs/threading-architecture-plan.md` — Arquitetura de threading
- **CCCaster reference:** `https://github.com/Rhekar/CCCaster` — a "pure
  truth" para comportamento esperado. Sempre verifique contra este antes de
  assumir que algo é um bug zzcaster.
