# Verificação de novos logins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Mostrar no sistema quais contas já usam NOVO LOGIN e quais ainda usam outro login.

**Architecture:** Consulta independente das ações de CPF/desativação, usando o adaptador AD existente e o worker assíncrono. Um botão Verificar logins exibe os resultados na tabela com filtros e contadores próprios; nunca habilita aplicação nem altera contas.

**Tech Stack:** PowerShell 5.1/7, WPF, módulo ActiveDirectory.

**Spec:** Pedido confirmado em 21/10/2026: incorporar ao sistema a conferência realizada no AD na conversa anterior.

## Global Constraints

- Consultar todas as linhas com novo login, independentemente de CPF e CONCLUÍDO.
- Usar somente o domínio da linha, com validação do controlador antes de consultar usuários.
- Buscar login exato e conferir nome completo; na ausência do login, buscar nome exato e único para mostrar o login atual.
- Erros, homônimos e nome divergente exigem revisão; não significam que a alteração está pendente.
- NOVO LOGIN vazio ou com desativar/excluir/remover recebe situação específica; não executa a ação.
- Esta consulta não altera CPF, login, estado de conta ou planilha e não autoriza o botão Aplicar.
- Preservar o fluxo existente de CPF/desativação e compatibilidade PowerShell 5.1 com UTF-8 BOM.

## Review Focus

- Mesmo nome em domínios diferentes: consultar somente o domínio informado.
- CPF inválido/ausente e conclusão desmarcada: verificar login normalmente.
- Login esperado pertence a outra pessoa ou nome é ambíguo: exigir revisão.
- Consulta após simulação válida: invalidar o plano de escrita anterior e bloquear aplicação.
- Interface compacta e filtros: mostrar login esperado/atual e situação sem esconder a tabela.

### Task 1: Consulta independente

**Files:** `CpfAd.psm1`, `Executar-CpfAD.ps1`, `tests/Testar-Logins.ps1`.

**Interfaces:** Exportar `Invoke-AdLoginCheck(Rows, Config, Adapter, ReportPath)`, sem parâmetro de escrita. Worker recebe `VerificarLogins` bool opcional default false; rejeita combinação com Aplicar. Resultados usam o formato atual, `Acao=VERIFICAR_LOGIN`, `Login` esperado e `LoginEncontrado` atual. Status novos: JA_COM_NOVO_LOGIN, NOVO_LOGIN_PENDENTE, SEM_NOVO_LOGIN, ACAO_NA_PLANILHA.

- [x] Testar os estados acima, identidades ambíguas/divergentes, domínio, falhas de consulta e ausência total de escritas.
- [x] Implementar consulta e rota somente leitura no worker, sem depender do atributo CPF.
- [x] Executar suíte nova e suítes existentes do motor/plano em PowerShell 5.1 e 7.

### Task 2: Interface e documentação

**Files:** `Interface-CpfAD.ps1`, `Interface-CpfAD.xaml`, `tests/Testar-Interface.ps1`, `README.md`.

**Interfaces:** Botão VerifyLoginsButton chama Start-UiOperation -CheckLogins; State.Mode/Job.CheckLogins distinguem a consulta. Filtros LoginOk/LoginPendente e contadores com legendas de login. Aplicar bloqueado tanto visualmente quanto na função de início.

- [x] Integrar consulta assíncrona, invalidar plano anterior, mostrar login atual/esperado e resultados legíveis; ocultar colunas CPF nesta consulta.
- [x] Testar botão, fluxo UI → worker → AD falso, filtros, modo de consulta e bloqueio de aplicação; preservar testes anteriores.
- [x] Documentar uso e executar testes WPF nos dois PowerShells, inspecionando imagens normal/compacta.

Validação final: 14 cenários de logins, 89 verificações WPF, 29 cenários do motor de CPF, 6 do plano e 24 de desativação passaram em Windows PowerShell 5.1 e PowerShell 7. Imagens normal e compacta inspecionadas. Consulta real pelo worker confirmou os 26 registros da última simulação, sem alterações no AD.
