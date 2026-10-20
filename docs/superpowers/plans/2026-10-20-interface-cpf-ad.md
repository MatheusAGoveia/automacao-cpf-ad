# Interface CPF AD — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Oferecer uma janela Windows para operar a automação CSV/AD existente.

**Architecture:** WPF/XAML com PowerShell 5.1; worker em runspace separado mantém a janela responsiva e reutiliza CpfAd.psm1. Simulação guarda a impressão digital do conteúdo/configuração; aplicação exige a mesma entrada e usa cópia temporária imutável do CSV.

**Tech Stack:** WPF, Windows PowerShell 5.1, .NET e módulo ActiveDirectory existente; sem novas dependências.

**Spec:** Pedido do usuário: "faca uma interface" para a automação existente. Decisões de implementação: janela nativa, importação e prévia sem AD, configuração dos servidores na tela, contadores, resultados e detalhes, simulação antes de aplicação, abertura do relatório, inicializador por duplo clique. Preservar todas as regras anteriores.

## Global Constraints

- Não consultar AD durante carregamento da tela/CSV nem durante testes.
- Aplicar somente depois de simulação válida para os mesmos dados/configuração.
- Nenhuma nova dependência instalada e nenhuma credencial salva.
- Reutilizar as regras existentes; não implementar renomeação ou unificação de contas.

## Review Focus

- Alteração externa do CSV ou edição da configuração invalida a simulação.
- CSV é copiado antes da execução; alterações durante o trabalho não mudam seus dados.
- AD lento não bloqueia a janela nem permite duplo início ou fechar durante gravação.
- Erros do worker liberam os controles e não habilitam aplicação.
- Layout em tamanho mínimo e mensagens longas não escondem ações ou resultados.

### Task 1: Interface e integração

**Files:** Create `Interface-CpfAD.ps1`, `Interface-CpfAD.xaml`, `Executar-CpfAD.ps1`, `Abrir-Interface.cmd`, `tests/Testar-Interface.ps1`; modify `README.md`.

**Interfaces:** worker recebe Csv/ConfigJson/ReportPath/Codificacao/Aplicar/PlanoJson e retorna Results/Report; UI usa runspace assíncrono e DispatcherTimer; `-NaoExibir` permite teste sem abrir janela nem acessar AD. O motor aceita ExpectedIdentities para validar os GUIDs da simulação.

- [x] Criar layout, configuração, importação e prévia dos dados.
- [x] Integrar execução assíncrona, cópia imutável e validação de simulação.
- [x] Testar fluxo de simulação/aplicação com comandos AD falsos, worker e motor reais, falhas e invalidação.
- [x] Renderizar WPF em PNG, inspecionar a imagem e ajustar layout.
- [x] Rodar os testes existentes e documentar abertura por duplo clique.
- [x] Revisar os arquivos e abrir a interface para o usuário.

## Validação

20 testes do motor e 20 verificações da interface passaram tanto em Windows PowerShell 5.1 como em PowerShell 7.6.3. O fluxo de aplicação foi exercitado com o worker real e comandos AD falsos dentro do runspace. Corrigida diferença de enumeração de arrays JSON no PowerShell 5.1. A aplicação limita-se aos registros/GUIDs prontos na simulação; os demais resultados permanecem no relatório final. Renderizações em 1260x850 e 1060x740 foram inspecionadas. Revisão independente identificou a necessidade de limitar a janela à área útil do monitor; dimensões iniciais e mínimas corrigidas. Nenhum AD real foi acessado.
