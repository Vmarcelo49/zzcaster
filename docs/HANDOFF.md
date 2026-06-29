# Handoff — zzcaster Netplay Desync Investigation

## Contexto

ZZCaster é um port em Zig 0.16 do CCCaster (netplay launcher para MBAACC). Estamos resolvendo desyncs de netplay. O trabalho foi feito na branch `main` do repo `git@github.com:Vmarcelo49/zzcaster.git`.

**Antes de continuar:** clone o repo, leia `docs/rollback-desync-investigation.md` e `docs/cccaster-vs-zzcaster-diffs.md` para contexto completo. O repo de referência do CCCaster (C++) está em `https://github.com/Rhekar/CCCaster` — clone se precisar comparar implementações.

## Setup

- **Repo zzcaster:** `git@github.com:Vmarcelo49/zzcaster.git`
- **Repo CCCaster ref:** `https://github.com/Rhekar/CCCaster.git`
- **SSH key:** o usuário fornece uma chave OpenSSH privada. Salve em `/home/z/my-project/.ssh/id_ed25519` com header/footer `-----BEGIN/END OPENSSH PRIVATE KEY-----`, chmod 600. Use o shim em `/home/z/my-project/scripts/ssh-shim.py` (requer `paramiko`) já que não há `openssh-client` instalado. Configure: `git config core.sshCommand "/home/z/my-project/scripts/ssh-shim.py -i /home/z/my-project/.ssh/id_ed25519 -o StrictHostKeyChecking=no"`
- **Build:** `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast` → `zig-out/bin/{zzcaster.exe,hook.dll}`
- **Toolchain:** Zig 0.16.0 de `https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz` (sha256: `70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00`)
- **Usuário:** `vmarcelo49 <vmarcelo49@gmail.com>` — todos os commits devem ser authored como este usuário.
- **TZ do usuário:** America/Sao_Paulo (fala português, responde em português)

## Estado Atual (commit `515df3b` no main)

### O que está funcionando
- **Delay mode (rollback=0)**: Funciona online após fixes de:
  - `hijackIntroState` aplicado antes de `waitForConfig` (race condition fix)
  - `clearIntroStateDuringRollback` em todos os modos netplay (não só rollback)
  - Supressão de inputs durante `chara_intro` e `skippable`
  - Per-frame lockstep para `chara_intro`, `skippable`, `retry_menu`

### O que ainda tem problema
- **Rollback mode**: Desync intermitente com **small drift** (camera Δ161, P1.x Δ250) no frame 149, com **RNG batendo**. Ocorre especialmente na segunda partida (após rematch).

## Histórico de Commits (em ordem cronológica)

1. **`4509eea`** — Gate `hijackIntroState` em `is_netplay` em vez de `rollback > 0` (delay mode fix inicial)
2. **`5a5c13c`** — Aplicar `hijackIntroState` ANTES de `waitForConfig` (race condition: jogo chegava em chara_intro antes do hack ser aplicado)
3. **`3c51919`** — Documentação da investigação (`docs/rollback-desync-investigation.md`)
4. **`18221dc`** — Flag `enable_rollback_min_frame_delay_guard` (default false, match CCCaster)
5. **`220b8a0`** — `clearIntroStateDuringRollback` em todos os modos netplay + log state pool erosion
6. **`d07dd8f`** — `setRemote` break após primeira misprediction + suprimir rollbacks ao frame 0
7. **`434cbb1`** — Gate chara_intro catch-up mash (depois supersedido por supressão total de inputs)
8. **`2664a43`** — Suprimir TODOS os inputs durante `chara_intro` (não só auto mash)
9. **`0e4760c`** — Lockstep block para `chara_intro` (index-based)
10. **`0dc28ab`** — Mesmo para `skippable` (tela de vitória)
11. **`e4a8ba5`** — Mesmo para `retry_menu`
12. **`d6a93b6`** — Per-frame lockstep para `chara_intro`/`skippable`/`retry_menu` (tentativa de fix da segunda partida)
13. **`d1899e8`** — REVERT do per-frame para index-based (regressão: small drift com delay=2) — **este foi um erro**
14. **`6495b94`** — Logging diagnóstico (`DIAG:` lines)
15. **`ed1b458`** — Documentação `docs/cccaster-vs-zzcaster-diffs.md`
16. **`515df3b`** — REVERT de volta ao per-frame lockstep (logs confirmaram que index-based causa divergência massiva)

## Arquivos-Chave

- `src/dll/netplay_manager.zig` — NetplayManager, FSM, lockstep, rollback, sync hash
- `src/dll/rollback.zig` — InputBuffer, StatePool, loadStateForFrame
- `src/dll/rollback_regions.zig` — 271 regiões de memória para save/restore
- `src/dll/frame_step.zig` — frameStepNetplay, lockstep wait loop, cooperative sleep
- `src/dll/dllmain.zig` — lazyInit, applyPostLoadHacks, frameStep, limitFrameRate
- `src/dll/asm_hacks.zig` — hijackIntroState, detectRoundStart, round_start_counter
- `docs/rollback-desync-investigation.md` — Análise dos 3 suspeitos (rollback_min_frame_delay, state pool regions, clearIntroStateDuringRollback)
- `docs/cccaster-vs-zzcaster-diffs.md` — Features do CCCaster não portadas + análise do drift

## O Problema Atual: Small Drift no Rollback Mode

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

1. **Cooperative sleep** (`recommendPerFrameSleepMs` em `frame_step.zig:128-135`) — pode estar adicionando latência extra durante `chara_intro`/`skippable`, onde não é necessário (inputs suprimidos, animação determinística)

2. **RTT EMA** (`updateRttEma` em `netplay_manager.zig`) — alimentado durante `chara_intro`/`skippable`, pode ter valores stale

3. **Frame rate limiter** (`limitFrameRate` em `dllmain.zig`) — busy-wait pode se comportar diferente quando lockstep pausa o frameStep

### Próximo Passo Sugerido

Desabilitar o cooperative sleep e o RTT EMA durante `chara_intro`/`skippable` (esses estados não precisam de time-sync). Em `frame_step.zig:128`:

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

Na verdade o sleep já é gated em `.in_game`. O problema pode ser que o lockstep wait durante `chara_intro` introduz variabilidade no timing que o `limitFrameRate` não compensa. Investigue a interação entre lockstep wait e frame limiter.

## Descobertas Importantes (para não redescobrir)

### 1. CCCaster RELEASE não detecta desyncs em rollback mode
O handler de `SyncHash` é `#ifndef RELEASE` (`DllMain.cpp:1432-1436`). Em RELEASE, `remoteSync` nunca recebe entries. zzcaster detecta no frame 149, CCCaster não detectaria. **Não existe "CCCaster rollback funcionando" como referência.**

### 2. `rollback_min_frame_delay = 8` era um bug
O guard silenciosamente dropava mispredictions de early-frame. `lcf_frame` é fixo — se for 5, `5 < 8` é true para sempre, rollback nunca dispara. Agora é default false (`enable_rollback_min_frame_delay_guard`).

### 3. Frame-0 rollbacks causam erosão do state pool
`loadState` apaga todos os states depois do carregado. Re-run não salva intermediários. Rollback ao frame 0 → pool vira `[frame_0, frame_at_rerun_end]` → rollbacks subsequentes caem no frame 0. Por isso suprimimos rollbacks ao frame 0 em `checkRollback`.

### 4. `InputBuffer.get` faz fallback cross-index
Retorna `last_inputs` de índices anteriores se não há input exato. Igual ao CCCaster. Pode causar mispredictions falsas no frame 0 (inputs stale do chara_intro). Já mitigado pela supressão de frame-0 rollbacks.

### 5. `setRemote` agora faz break após primeira misprediction
Matches CCCaster (`InputsContainer.hpp:73-81`). Antes continuava verificando, podendo sobrescrever `lcf` com frame mais tarde.

### 6. Per-frame lockstep é necessário
Index-based permite o peer rápido avançar frames enquanto o lento carrega. Logs mostraram remote 30 frames à frente no frame 0 do chara_intro. Per-frame corrige isso.

### 7. `hijackIntroState` + `stage_animation_off` devem ser aplicados antes de `waitForConfig`
Senão o jogo chega em chara_intro antes do hack ser aplicado → intro_state progride naturalmente em frame não-determinístico → desync. Aplicamos incondicionalmente e revertemos se for offline/spectator.

## Features do CCCaster Não Portadas (documentadas em `docs/cccaster-vs-zzcaster-diffs.md`)

1. Reset de variáveis ASM ao sair do retry_menu (`currentMenuIndex`, `menuConfirmState`, `targetMenuState`, `targetMenuIndex`)
2. Gerenciamento de `_startIndex` (`eraseIndexOlderThan` preserva inputs recentes)
3. Sistema de retry menu sincronizado (`_localRetryMenuIndex` / `_remoteRetryMenuIndex` via mensagens `MenuIndex`)
4. Variáveis ASM não portadas (`currentMenuIndex`, `menuConfirmState`, `numLoadedColors`, `autoReplaySaveState`)
5. `exportResults` ao entrar no RetryMenu
6. `CC_MENU_STATE_COUNTER_ADDR` para timing de menu

**Nenhuma dessas explica diretamente o small drift atual**, mas podem ser relevantes para bugs futuros.

## Como o Usuário Testa

1. Build: `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast`
2. Pega `hook.dll` e `zzcaster.exe` de `zig-out/bin/`
3. Joga online com um amigo (diferentes estados/máquinas para expor timing issues)
4. Config: `defaultRollback=0` para delay mode, `defaultRollback=4` para rollback mode
5. Logs da DLL: `dll_<pid>.log` (envia os dois logs de ambos os peers)
6. Procura por `DESYNC detected` e `DIAG:` lines

## Padrões de Desync (reconhecer pelos logs)

| Padrão | Causa | Status |
|---|---|---|
| RNG mismatch + camera/P1.x divergência massiva | Lockstep insuficiente (index-based) | ✗ Resolvido (per-frame) |
| RNG match + camera/P1.x small drift | Per-frame lockstep + timing variability | **Atual** |
| RNG mismatch + P1/P2 seq_state divergente | Skip de intro assimétrico | ✗ Resolvido (supressão de inputs) |
| RNG match + camera/P1.x/P2.x offset uniforme | State pool erosion (frame-0 rollbacks) | ✗ Resolvido (supressão frame-0) |

## Notas para o Próximo Agente

1. **Sempre peça logs de AMBOS os peers.** Comparar os dois é essencial.
2. **Não faça mudanças sem confirmar com logs.** Já cometemos erros por adivinhar (ex: revert `d1899e8`).
3. **Documente cada fix com comentários no código.** O usuário valoriza isso.
4. **Commits atômicos com mensagens detalhadas.** Inclua os números de delta do desync nos commits.
5. **O usuário testa online com um amigo.** Resultados podem variar entre localhost e online devido a latency.
6. **Delay mode funciona.** Rollback mode tem o small drift. Foque no rollback.
7. **O usuário fala português.** Responda em português.
8. **Não mexa no delay mode** a menos que seja para alinhar com CCCaster — está funcionando.
9. **SSH push funciona** com o shim paramiko. Não tente instalar openssh-client.

## Próximos Passos (plano mental do usuário)

1. Investigar o small drift do per-frame lockstep
2. Possivelmente desabilitar cooperative sleep / RTT EMA durante estados de animação
3. Se resolver, partir para melhorar rollback (state pool, determinism)
4. Considerar portar features do CCCaster (retry menu sync, etc.) conforme necessário

## Documentos de Referência

- `docs/rollback-desync-investigation.md` — Análise dos 3 suspeitos do desync de rollback
- `docs/cccaster-vs-zzcaster-diffs.md` — Features do CCCaster não portadas + análise do drift atualizada
- `docs/roadmap.md` — Roadmap geral do projeto
- `docs/rollback-improvement-plan.md` — Plano de melhorias de rollback
- `docs/nat-traversal-protocol.md` — Protocolo de NAT traversal (autoritativo para wire format)
- `docs/threading-architecture-plan.md` — Arquitetura de threading
