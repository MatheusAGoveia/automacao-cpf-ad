# Desativação de usuários Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Desativar, mediante opção explícita e simulação, contas indicadas por NOVO LOGIN = desativar no domínio informado no CSV.

**Architecture:** Estender o adaptador e o processamento atual, preservando o fluxo de CPF. A interface envia `DesativarUsuarios` no JSON, incluído na impressão digital da simulação. A aplicação fixa domínio, controlador, GUID e login encontrado e confirma o estado após a escrita.

**Tech Stack:** Windows PowerShell 5.1/PowerShell 7, WPF, ActiveDirectory; sem novas dependências externas.

**Spec:** Requisitos confirmados nesta conversa: processar todas as linhas com desativar, independentemente de CONCLUÍDO; se a pessoa existir nos dois domínios, usar exclusivamente DOMÍNIO da linha.

## Global Constraints

- Opção desligada por padrão; aceitar DESATIVAR sem distinção de maiúsculas e espaços nas extremidades, somente como conteúdo integral da célula.
- Desativação não depende de CPF nem de CONCLUÍDO. CPF segue as regras existentes.
- Identificar por nome completo exato e único no domínio indicado; homônimos ficam para revisão.
- Conta já desativada não recebe nova escrita. Não alterar CPF nas linhas de desativação.
- Simular antes de aplicar na interface; nenhuma conta real será desativada nos testes.
- Relatórios registram ação, conclusão original, login encontrado e estados da conta.
- Arquivos PowerShell com UTF-8 BOM, compatíveis com Windows PowerShell 5.1.

## Review Focus

- Mesmo nome nos dois domínios: somente o domínio do CSV pode ser consultado/escrito.
- Nome ambíguo dentro do domínio: nenhuma conta deve ser escolhida.
- Opção desligada, CPF ausente/inválido e CONCLUÍDO desmarcado: ações devem seguir regras separadas.
- Conta renomeada/substituída ou estado alterado entre simulação/aplicação: revalidar GUID/login/nome/Enabled.
- Mesmo GUID com CPF e desativação ou linhas repetidas: bloquear ações conflitantes e evitar escritas duplicadas.

### Task 1: Motor, adaptador e plano

**Files:** `CpfAd.psm1`, `Executar-CpfAD.ps1`, `Atualizar-CpfAD.ps1`, `tests/Testar-Desativacao.ps1`.

**Interfaces:** Config opcional `DesativarUsuarios` bool default false. Resultados acrescentam `Acao` (`PREENCHER_CPF`/`DESATIVAR`), `ConcluidoPlanilha`, `LoginEncontrado`, `ContaAtivaAnterior`, `ContaAtivaAtual`. Adaptador `Disable(Server, Identity)` usa Disable-ADAccount; atributo vazio em ValidateServer/Find/Read indica operação sem CPF. `ExpectedIdentities` permanece GUID por registro; `ExpectedLogins` vincula login descoberto na simulação.

- [x] Cobrir opção desligada, sem conclusão/CPF, ambos os domínios, ambiguidade, já desativado, conflito, troca de identidade, falha de escrita e confirmação em testes com AD falso.
- [x] Implementar seleção independente de ações, releituras e confirmação; preservar fluxo de CPF.
- [x] Validar conteúdo original do plano e opção da ação no worker; acrescentar opção explícita à CLI.
- [x] Executar testes do motor/plano em PowerShell 5.1 e 7.

### Task 2: Interface e documentação

**Files:** `Interface-CpfAD.ps1`, `Interface-CpfAD.xaml`, `tests/Testar-Interface.ps1`, `README.md`.

**Interfaces:** Mesmos campos e configuração da Task 1. Candidatos: `SIMULADO_PREENCHER` e `SIMULADO_DESATIVAR`; sucesso inclui `DESATIVADO` e `JA_DESATIVADO`. Ignorado inclui `DESATIVACAO_DESLIGADA`; estados de escrita: `DESATIVACAO_INICIADA`, `DESATIVADO_SEM_CONFIRMACAO`; conflito `CONFLITO_ACOES`.

- [x] Acrescentar opção desligada por padrão, descrição de domínio/conclusão, ação/login encontrado e status legíveis.
- [x] Integrar filtros, contadores, impressão digital, invalidação e aplicação aos dois tipos de ação.
- [x] Cobrir o fluxo misto e alteração da opção em testes WPF com AD falso; atualizar instruções de uso.
- [x] Verificar layout compacto e realizar revisão independente das mudanças antes de concluir.

Validação final: 29 cenários de motor, 6 de plano, 24 de desativação e 70 verificações WPF passaram em Windows PowerShell 5.1 e PowerShell 7. Revisão independente concluída sem falhas bloqueantes. Imagens normal e compacta inspecionadas; nenhum AD real acessado.
