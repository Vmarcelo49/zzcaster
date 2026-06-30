# Handoff — §C End-of-Round Delay Desync

> **Data:** 2026-06-30
> **Current HEAD:** `bdad26e`
> **Issue:** Delay mode desyncs at end of round (frame 149, uniform position offset, no RNG mismatch)

---

## Contexto Rápido

ZZCaster é um port em Zig 0.16 do CCCaster (netplay launcher para MBAACC). O
usuário é `vmarcelo49`, fala português, TZ America/Sao_Paulo.

**Leia antes de continuar:** `docs/netplay-desync-investigation.md` — tem o
histórico completo, todos os commits, e os findings que não devem ser
redescobertos.

## Setup

- **Repo:** `git@github.com:Vmarcelo49/zzcaster.git`
- **CCCaster ref:** `https://github.com/Rhekar/CCCaster.git` (clone em `/home/z/my-project/CCCaster`)
- **SSH shim:** `/home/z/my-project/.ssh/ssh-shim.py` (paramiko)
- **Build:** `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast`
- **Zig:** `/home/z/my-project/zig-x86_64-linux-0.16.0/zig`
- **Deploy:** `bash scripts/build-and-deploy.sh`

## O que está resolvido (NÃO MEXER)

| Issue | Fix | Commit |
|---|---|---|
| §A chara_intro freeze | always-mash durante chara_intro + lockstep | `d9ae272` |
| §B round-2 drift | always-mash durante skippable | `b098c32` |
| Replay popup | menuConfirmState hack + menu_state_counter | `9749937` + `c6ae0db` |
| Retry menu confirms | always mcs=2 durante retry_menu | `01376d6` |
| Delay mismatch | host dicta delay, client adota | `bdad26e` |
| Title screen freeze | mcs=2 em pre-game mashes | `0936798` |
| Log spam | dedup + remove DIAG per-frame | `b587751` + `e23b1a3` |

## O Problema: §C — Desync no fim do round (delay mode)

### Sintoma

Delay mode (rollback=0). A partida completa um round inteiro, mas desynca
exatamente no frame 149 (o frame onde o sync-hash check roda).

```
[ERROR] DESYNC detected at indexed_frame=0x0000000400000095
  (index=4, frame=149 = 0x95)
[ERROR]   camera_x: -12500 vs -9750    (Δ2750)
[ERROR]   P1 x: -37880 vs -35130       (Δ2750)
[ERROR]   (no RNG mismatch)
```

### Características principais

1. **Offset uniforme** — camera_x, P1_x, P2_x todos com o MESMO delta (~2750)
2. **Sem RNG mismatch** — a raiz de determinismo está OK
3. **Sempre no frame 149** — é o sync-hash check que pega
4. **Δ2750 / 149 frames ≈ 18.5 units/frame** — drift pequeno por frame
5. **Acontece com delay=1 e delay=2** — não é específico do delay value
6. **Acontece online mas NÃO no localhost** — sugere timing relacionado a latency

### O que já sabemos que NÃO é

- **NÃO é §A** (chara_intro entry divergence) — isso foi resolvido com always-mash
- **NÃO é §B** (skippable entry divergence) — isso foi resolvido com always-mash
- **NÃO é delay mismatch** — o host agora dicta o delay (`bdad26e`)
- **NÃO é RNG divergence** — RNG hash matches

### Hipóteses (NÃO VERIFICADAS — investigar com logs)

1. **Timing injection durante in_game** — o cooperative sleep (`recommendPerFrameSleepMs`),
   RTT EMA, e frame limiter podem causar pequeno drift por frame que acumula em
   Δ2750 over 149 frames. O branch `fix/small-drift-animation-states` (merged
   em `981c1fb`) tentou endereçar isso para animation states mas talvez seja
   necessário também durante in_game ativo.

2. **Frame limiter drift** — o busy-wait frame limiter (`limitFrameRate` em
   `dllmain.zig`) pode driftar de forma diferente no hardware dos dois peers
   (CPU speed diferente, timer resolution diferente). O `frame_limiter_needs_reset`
   (do branch) ajuda após lockstep wait, mas talvez não seja suficiente.

3. **Input delay asymmetry** — mesmo com o mesmo delay value, a forma como
   inputs são bufferizados e aplicados pode diferir entre host e client.

4. **Air dash macro** — o macro modifica inputs; se triggerar em frames
   diferentes nos dois peers (devido a input timing), pode causar position drift.

### Próximos passos sugeridos

1. **Coletar logs de AMBOS os peers** de uma partida que desyncou. Comparar
   frame-by-frame do in_game entry (frame 0) ao desync (frame 149). Procurar
   qualquer divergência em inputs, rollback triggers, ou timing.

2. **Verificar se o desync é sempre no MESMO frame** (149) ou se varia. Se
   sempre 149, é o sync-hash check pegando um drift que acumulou. Se varia,
   é um evento específico.

3. **Testar com delay=0** (se possível) para isolar se o mecanismo de delay
   contribui para o drift.

4. **Comparar com CCCaster** — CCCaster RELEASE não detecta desyncs
   (`SyncHash` handler é `#ifndef RELEASE`). Pode ter o mesmo drift mas não
   crashar. Testar CCCaster delay mode com debug build se possível.

5. **Investigar o cooperative sleep durante in_game** — o branch
   `fix/small-drift-animation-states` skipa o sleep durante animation states
   mas NÃO durante in_game. Talvez o sleep durante in_game esteja causando
   drift. Verificar `frame_step.zig:148`:
   ```zig
   if (n.state == .in_game and !n.isRerunning() and !n.isInAnimationState()) {
       const sleep_ms = n.recommendPerFrameSleepMs();
       ...
   }
   ```
   O `!n.isInAnimationState()` significa que o sleep roda durante in_game. Talvez
   precisamos desabilitar o sleep também durante in_game, ou pelo menos
   investigar se o sleep está adicionando drift.

## Padrões de Desync (reconhecer pelos logs)

| Padrão | Causa | Status |
|---|---|---|
| Freeze no chara_intro→in_game (host vê round_start, client não) | §A entry divergence | ✅ Resolvido |
| Δ1415 uniform offset no round 2 frame 149 | §B skippable entry divergence | ✅ Resolvido |
| Δ2750 uniform offset no round 1 frame 149, no RNG mismatch | **§C end-of-round drift** | **❌ Aberto** |
| RNG mismatch + massive divergence | Lockstep removido (Option 1 3/3) | ✅ Resolvido (revertido) |
| Δ150 uniform offset no round 1 frame 149 | §B variante (antes do fix) | ✅ Resolvido |

## Arquivos-Chave para §C

- `src/dll/frame_step.zig:148` — cooperative sleep durante in_game (SUSPEITO #1)
- `src/dll/frame_step.zig:129` — RTT EMA update (skipado em animation states, roda em in_game)
- `src/dll/dllmain.zig:795` — frame_limiter_needs_reset (do branch, pode não ser suficiente)
- `src/dll/netplay_manager.zig` — `recommendPerFrameSleepMs`, `updateRttEma`
- `src/dll/dllmain.zig` — `limitFrameRate` (busy-wait frame limiter)

## Notas para o Próximo Agente

1. **§C é o foco.** Leia §C acima e `docs/netplay-desync-investigation.md`.
2. **Sempre verifique contra CCCaster** — clone em `/home/z/my-project/CCCaster`.
3. **Sempre peça logs de AMBOS os peers.** Compare frame-by-frame.
4. **Não chute — confirme com logs.** O histórico de §A mostra que chutar causa regressões.
5. **O usuário fala português.** Responda em português.
6. **SSH push funciona** com o shim paramiko.
7. **Always-mash + lockstep** é o padrão comprovado para animation states. Não remova lockstep.
8. **Loading não pode ser lockstepped** — é I/O-bound.
9. **auto-replay-save está desabilitado, não portado.** Não portar o full feature a menos que necessário.
10. **O branch `fix/small-drift-animation-states` já está merged** (`981c1fb`). Seus 3 fixes (skip sleep, skip RTT EMA, reset frame limiter) estão ativos para animation states mas NÃO para in_game ativo.
