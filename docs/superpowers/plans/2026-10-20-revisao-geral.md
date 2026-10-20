# Revisão geral das regras e interface — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Corrigir riscos comprovados na importação/roteamento e tornar o estado da interface confiável, preservando as regras já acordadas.

**Architecture:** Parser CSV estrito TextFieldParser com validação de cabeçalhos e estrutura; o adaptador valida o domínio pelo defaultNamingContext do controlador. O worker confere os dados aprovados no plano além do GUID. O motor sinaliza repetições do mesmo objeto e a interface invalida prévias após mudanças.

**Tech Stack:** PowerShell 5.1/7, WPF, ActiveDirectory e Microsoft.VisualBasic do Windows/.NET existente.

**Spec:** Usuário autorizou revisão e melhorias inclusive da interface. Manter apenas concluídos com CPF válido, domínio pelo CSV, identidade conferida, CPF vazio e 11 dígitos, nenhuma renomeação/desativação/unificação de contas.

## Global Constraints

- Nenhuma escrita/consulta de usuários reais nesta revisão; testes com AD falso.
- Campo CPF já preenchido permanece preservado.
- Dois objetos distintos não são deduplicados só por terem o mesmo CPF.
- Nenhum domínio alternativo é escolhido diante de falha ou configuração errada.
- Dados visuais anteriores não podem continuar sinalizados como prontos após mudança de entrada.

## Review Focus

- Cabeçalhos CPF/CONCLUÍDO duplicados após normalização não podem substituir dados silenciosamente.
- CSV com aspas abertas ou número incorreto de campos deve ser rejeitado integralmente.
- Servidor manual e cache precisam respeitar o domínio de cada linha.
- Plano não pode aceitar CPF/nome/login/domínio diferente mantendo o mesmo número do registro.
- Falha de importação ou alteração externa do CSV deve deixar Aplicar indisponível.

### Task 1: Motor e worker

**Files:** CpfAd.psm1, Executar-CpfAD.ps1, tests/Testar-Automacao.ps1 e novos testes do worker.

**Interfaces:** ValidateServer(Server,Attribute,Domain); status LINHA_REPETIDA preserva todos os registros no relatório e só planeja uma escrita por GUID/CPF; worker exige correspondência dos dados do plano.

- [x] Implementar parser estrito, rejeição de duplicatas e ignorar linhas sem identificação que só tenham checkbox.
- [x] Validar domínio do controlador e cachear por domínio/servidor.
- [x] Deduplicar repetições do mesmo GUID/CPF sem afetar contas distintas.
- [x] Validar dados de entrada contra o plano antes de aplicar.
- [x] Testar os riscos e executar suites nos dois PowerShells.

### Task 2: Interface

**Files:** Interface-CpfAD.ps1/.xaml e tests/Testar-Interface.ps1.

- [x] Limpar seleção anterior se a importação falhar.
- [x] Invalidar contadores/prontos após mudança de configuração ou do CSV externo.
- [x] Melhorar detalhes/indicação de estado e status de linha repetida.
- [x] Testar e renderizar layout compacto/normal.
- [x] Atualizar README com regras finais e registrar validação.

## Validação final

29 cenários do motor, 6 do executor/plano e 51 verificações da interface passaram em Windows PowerShell 5.1 e PowerShell 7.6.3. A revisão independente das correções não identificou regressões concretas. Todos os testes usaram dados fictícios e AD falso; nenhum usuário real consultado ou alterado. Relatório das regras finais em docs/revisao-regras-2026-10-20.md.
