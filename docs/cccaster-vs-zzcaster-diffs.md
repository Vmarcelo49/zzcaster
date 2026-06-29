# CCCaster vs zzcaster — Diferenças Não-Portadas

Análise comparativa do fluxo de fim de partida e início da próxima.
Foco em funcionalidades do CCCaster que o zzcaster não implementou.

---

## 1. Reset ao sair do retry_menu (`DllNetplayManager.cpp:754-765`)

### CCCaster

```cpp
// Exiting RetryMenu
if ( _state == NetplayState::RetryMenu )
{
    AsmHacks::autoReplaySaveStatePtr = 0;
    resetInGameIndexes();
}

// Reset state variables (sempre, em toda transição para CharaSelect+)
AsmHacks::currentMenuIndex = 0;
AsmHacks::menuConfirmState = 0;
_targetMenuState = -1;
_targetMenuIndex = -1;
```

### zzcaster

**Não portado.** O zzcaster não tem `currentMenuIndex`, `menuConfirmState`, `targetMenuState`, `targetMenuIndex`, nem `resetInGameIndexes`. Essas variáveis simplesmente não existem no código Zig.

### Impacto

- `currentMenuIndex` e `menuConfirmState` são usados pelo ASM hack de menu para navegação. Sem resetar, podem conter valores stale da partida anterior.
- `targetMenuState` / `targetMenuIndex` controlam a auto-navegação do menu de rematch.
- `resetInGameIndexes` limpa o array que rastreia quais índices foram in_game (usado para replays).

### Relevância para o desync da segunda partida

**Baixa.** Essas variáveis afetam o comportamento do menu da retry_menu, não a animação de chara_intro. O desync da segunda partida é na chara_intro do round 1, com inputs suprimidos.

---

## 2. Gerenciamento de `_startIndex` ao entrar em Loading (`DllNetplayManager.cpp:702-731`)

### CCCaster

```cpp
if ( state == NetplayState::Loading )
{
    _spectateStartIndex = getIndex();

    const uint32_t newStartIndex = min ( getBufferedPreserveStartIndex(), getIndex() );

    if ( newStartIndex > _startIndex )
    {
        const size_t offset = newStartIndex - _startIndex;

        // Remove inputs antigos, preserva recentes
        _inputs[0].eraseIndexOlderThan ( offset );
        _inputs[1].eraseIndexOlderThan ( offset );

        // Limpa RNG states antigos
        if ( offset >= _rngStates.size() )
            _rngStates.clear();
        else
            _rngStates.erase ( _rngStates.begin(), _rngStates.begin() + offset );

        // Limpa retry menu indices antigos
        if ( offset >= _retryMenuIndicies.size() )
            _retryMenuIndicies.clear();
        else
            _retryMenuIndicies.erase ( _retryMenuIndicies.begin(), _retryMenuIndicies.begin() + offset );

        _startIndex = newStartIndex;
    }

    _localRetryMenuIndex = -1;
    _remoteRetryMenuIndex = -1;
}
```

### zzcaster

O zzcaster faz `self.local_inputs.reset()` e `self.remote_inputs.reset()` no `onEnterInGame` (`netplay_manager.zig:2438-2439`), que limpa **tudo**. Não há conceito de `_startIndex` — o `InputBuffer` é um HashMap que cresce indefinidamente.

### Impacto

- O CCCaster preserva inputs recentes (para spectators atrasados) e só remove os antigos.
- O zzcaster limpa tudo, o que pode causar problemas se um spectator estiver atrasado.
- O `_startIndex` é usado para mapear índices absolutos para relativos nos containers de input.

### Relevância para o desync da segunda partida

**Média.** Se inputs stale da partida anterior não forem limpos corretamente, podem causar mispredictions. Mas o `onEnterInGame` faz `reset()`, então inputs são limpos. O problema pode ser que o `reset()` não limpa tudo que deveria (ex: `end_index`, `end_frames`).

---

## 3. Sistema de retry menu sincronizado (`DllNetplayManager.cpp:442-487, 489-502`)

### CCCaster

```cpp
// getRetryMenuInput — netplay mode
if ( _remoteRetryMenuIndex != -1 && _localRetryMenuIndex != -1 )
{
    // Ambos selecionaram — navega para o max(local, remote)
    _targetMenuState = 0;
    _targetMenuIndex = max ( _localRetryMenuIndex, _remoteRetryMenuIndex );
    _targetMenuIndex = min ( _targetMenuIndex, ( int8_t ) 1 );
    setRetryMenuIndex ( getIndex(), _targetMenuIndex );
    input = 0;
}
else if ( _localRetryMenuIndex != -1 )
{
    // Local selecionou, esperando remote
    input = 0;
}
else if ( AsmHacks::menuConfirmState == 1 )
{
    // Captura seleção local
    _localRetryMenuIndex = AsmHacks::currentMenuIndex;
    input = 0;
}
```

O host envia `getLocalRetryMenuIndex()` para o client (`DllMain.cpp:499-503`), e o client recebe via `setRemoteRetryMenuIndex` (`DllMain.cpp:1461`). Ambos só confirmam a seleção quando **ambos** escolheram.

### zzcaster

**Não portado.** O zzcaster não tem `_localRetryMenuIndex`, `_remoteRetryMenuIndex`, nem troca de mensagens `MenuIndex`. O retry_menu usa um gate de input (`retry_menu_waiting_for_peer`) que só verifica se o remote atingiu o mesmo transition index.

### Impacto

- No CCCaster, ambos os peers selecionam a mesma opção (max de local e remote).
- No zzcaster, cada peer pode selecionar independentemente — se um escolhe "Rematch" e o outro "Character Select", há divergência.
- O gate atual previne seleção prematura, mas não sincroniza a escolha.

### Relevância para o desync da segunda partida

**Baixa.** O desync é na chara_intro, não no retry_menu. Mas se a transição retry_menu → chara_select vs retry_menu → loading divergir, poderia causar problemas.

---

## 4. Variáveis ASM não portadas

### CCCaster (`DllAsmHacks.hpp`)

```cpp
extern uint32_t roundStartCounter;
extern uint32_t currentMenuIndex;
extern uint32_t menuConfirmState;
extern uint32_t autoReplaySaveState;
extern uint32_t *autoReplaySaveStatePtr;
extern uint32_t numLoadedColors;
```

### zzcaster (`asm_hacks.zig`)

```zig
pub var round_start_counter: u32 = 0;
// currentMenuIndex: NÃO PORTADO
// menuConfirmState: NÃO PORTADO
// autoReplaySaveState: NÃO PORTADO
// autoReplaySaveStatePtr: NÃO PORTADO
// numLoadedColors: NÃO PORTADO
```

### Impacto

- `currentMenuIndex` e `menuConfirmState` são críticos para a navegação de menu sincronizada.
- Sem eles, o zzcaster não pode implementar o sistema de retry menu sincronizado do CCCaster.
- `numLoadedColors` é usado para detectar quando o loading terminou (cores dos personagens carregadas).

### Relevância para o desync da segunda partida

**Baixa direta.** Mas `numLoadedColors` poderia ser usado para sincronizar melhor a transição loading → chara_intro.

---

## 5. `exportResults` ao entrar no RetryMenu (`DllNetplayManager.cpp:746-752`)

### CCCaster

```cpp
if ( state == NetplayState::RetryMenu )
{
    _retryMenuStateCounter = *CC_MENU_STATE_COUNTER_ADDR + 1;
    if ( !config.mode.isSpectate() )
        exportResults();
}
```

### zzcaster

**Não portado.** `exportResults` exporta dados da partida (para replays/estatísticas). O zzcaster tem `auto_replay_save` na config mas não chama `exportResults`.

### Impacto

- Não afeta determinismo. Apenas funcionalidade de replay/estatísticas.

---

## 6. `CC_MENU_STATE_COUNTER_ADDR` e `_retryMenuStateCounter`

### CCCaster

```cpp
_retryMenuStateCounter = *CC_MENU_STATE_COUNTER_ADDR + 1;
```

Usado para rastrear quando o menu de retry realmente abre (após a animação de vitória terminar).

### zzcaster

**Não portado.** O zzcaster não lê `CC_MENU_STATE_COUNTER_ADDR`.

### Impacto

- Pode afetar o timing de quando o retry_menu é considerado "ativo" para input.

---

## Resumo: o que é mais provável que cause o desync da segunda partida

| Item | Relevância | Notas |
|---|---|---|
| Reset de variáveis ASM (menuConfirmState, etc.) | Baixa | Afeta menu, não intro |
| Gerenciamento de `_startIndex` | Média | Inputs stale podem causar mispredictions |
| Sistema de retry menu sincronizado | Baixa | Desync é na intro, não no menu |
| `numLoadedColors` | Baixa | Pode melhorar sync de loading |
| `exportResults` | Nenhuma | Apenas replay/stats |
| `CC_MENU_STATE_COUNTER_ADDR` | Baixa | Timing de menu |

## Hipótese atual

O desync da segunda partida provavelmente **não** é causado por nenhuma dessas diferenças diretamente. O padrão (camera ≈ 2× P1.x, RNG bate) indica divergência de timing da animação de intro, não de inputs ou estado de menu.

A causa mais provável é que o lockstep index-based (atual) permite o peer rápido avançar frames durante `chara_intro` enquanto o peer lento ainda está em loading. O per-frame lockstep (que corrigiria isso) causou drift de timing.

Próximos passos:
1. Analisar os logs diagnósticos (commit `6495b94`) para confirmar se `world_timer` difere na transição para `chara_intro`
2. Se confirmado, investigar uma abordagem híbrida: lockstep index-based para prevenir avance prematuro, mas com sincronização de frame 0 garantida
3. Considerar portar `numLoadedColors` para melhor sincronização de loading
