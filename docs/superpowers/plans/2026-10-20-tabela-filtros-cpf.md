# Tabela, filtros e CPF numérico — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tornar a tabela visível em janelas menores, permitir filtrar/ordenar os resultados e gravar CPFs exclusivamente como 11 dígitos.

**Architecture:** Limitar a área superior com rolagem própria e recolher configurações inicialmente, preservando espaço da tabela. Usar ICollectionView para filtros e ordenação sem alterar os resultados originais ou o plano da aplicação. O motor grava sempre Digits, inclusive para configurações antigas com FormatoCpf=Formatado.

**Tech Stack:** WPF e PowerShell 5.1/7 existentes.

**Spec:** Pedidos do usuário: investigar planilha invisível em Confira e aplique; adicionar ordenação/filtro; inserção no AD sem pontos/espaços. Reproduzido com CSV fictício: em 1060x650 a tabela tinha altura zero e três registros carregados.

## Global Constraints

- Preservar dados originais do CSV, CPFs já preenchidos e regras de domínio/identificação.
- Filtros são somente de visualização; botão deve indicar claramente aplicação de todos os prontos da simulação.
- Nova gravação de CPF sempre tem 11 dígitos, incluindo zeros iniciais.
- Testes sem AD real e sem credenciais.

## Review Focus

- Tabela com altura útil em 1060x650 e configurações expandidas.
- Nome com acento e CPF com pontuação encontrados pela busca.
- Filtros combinados, vazios e limpeza mantêm contagem correta.
- Ordenação crescente/decrescente e cabeçalhos não alteram o plano de aplicação.
- Configuração antiga Formatado não consegue gravar pontuação.

### Task 1: Layout, visualização e gravação

**Files:** Modify Interface-CpfAD.xaml/.ps1, CpfAd.psm1, testes e README.md.

**Interfaces:** Update-UiView atualiza ICollectionView; Update-UiLayout ajusta limite superior; Get-UiConfigJson fixa FormatoCpf=Numeros; Invoke-CpfSync grava Digits.

- [x] Ajustar layout e adicionar controles de busca, filtros e ordenação.
- [x] Integrar ICollectionView e manter o plano independente dos filtros.
- [x] Forçar CPF numérico e atualizar testes de gravação.
- [x] Testar layout compacto/expandido, filtros, ordenação e fluxo completo nos dois PowerShells.
- [x] Inspecionar imagens e atualizar instruções.
- [x] Abrir a versão atualizada.

## Validação

23 testes do motor e 37 verificações de interface passaram em Windows PowerShell 5.1 e PowerShell 7.6.3. Não houve consulta/gravação no AD real. O caso 1060x650 deixou de produzir tabela com altura zero; há teste de área útil mínima com configurações recolhidas e expandidas. Imagens em tamanho normal, mínimo e compacto foram inspecionadas. Revisão independente identificou ordenação errada de CPFs misturando valores pontuados e numéricos; corrigida com chaves só de dígitos e teste de regressão. Filtros não alteram registros/GUIDs do plano; botão Aplicar todos (N) mostra o total real. Interface e motor fixam novas gravações em 11 dígitos mesmo com configuração antiga Formatado.

## Retorno sobre Todos os domínios e mensagens

Usuário relatou tabela vazia ao voltar a Todos os domínios. A troca direta com dados fictícios já passava, então a causa exata no uso não foi confirmada. A seleção agora usa identificador explícito em vez de valor vazio e consome o item novo do evento, com teste que simula o controle ainda expondo a seleção anterior. A interface informa filtros ativos e explica que Todos remove somente o domínio, enquanto Limpar remove todos. Rótulos alterados para Pendente na planilha e Login contém uma ação; os detalhes e o relatório explicam CONCLUÍDO desmarcado e ações desativar/excluir/remover em NOVO LOGIN. Validação atual: 23 testes do motor e 43 verificações de interface passaram em ambos os PowerShells, sem AD real.
