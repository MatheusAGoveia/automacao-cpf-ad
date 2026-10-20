# Descoberta automática de domínios — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Usar DOMÍNIO do CSV para direcionar cada usuário e descobrir automaticamente o controlador correspondente.

**Architecture:** Servidor vazio ou rótulo sem configuração aciona o DC Locator do Windows por Get-ADDomainController -Discover -Writable -Service ADWS. Normalizar caixa/acentos dos rótulos para nomes DNS; conferir o domínio retornado antes de consultar usuários. Cachear sucesso e falha por domínio durante a execução. Servidor preenchido manualmente continua como opção.

**Tech Stack:** PowerShell 5.1+, módulo ActiveDirectory existente, WPF.

**Spec:** Usuário escolheu explicitamente "Usar DOMÍNIO do CSV e descobrir servidores automaticamente". Não buscar usuários nos dois ADs para decidir domínio. BETIM.PMB corresponde a betim.pmb; SAÚDE.BETIM corresponde a saude.betim.

## Global Constraints

- Não usar o domínio atual como fallback de uma descoberta malsucedida.
- Domínio vazio deve ser ignorado com explicação.
- Manter simulação, conferência de identidade e preservação do CPF existente.
- Carregar CSV não consulta AD; descoberta acontece ao simular/aplicar.

## Review Focus

- Acentos/caixa e domínios distintos precisam resolver para os controladores corretos.
- Domínio retornado divergente deve bloquear a consulta e escrita.
- Falha de um domínio não pode redirecionar usuário para outro.
- Servidor manual continua funcional sem descoberta.
- Controles e instruções não podem continuar exigindo servidor manual.

### Task 1: Descoberta no motor e na interface

**Files:** Modify CpfAd.psm1, Atualizar-CpfAD.ps1, Interface-CpfAD.ps1, Interface-CpfAD.xaml, README.md e testes existentes.

**Interfaces:** Adaptador recebe DiscoverServer(Domain) e retorna hostname validado; resultado acrescenta OrigemServidor; a interface mostra Controlador localizado sem alterar a configuração/fingerprint.

- [x] Adicionar DC Locator, validação e cache da descoberta por domínio.
- [x] Remover obrigatoriedade de configuração manual na UI/CLI e mostrar servidores localizados.
- [x] Testar dois domínios, falha sem fallback, domínio vazio, cache e override manual.
- [x] Atualizar instruções e validar PowerShell 5.1/7 e renderização da interface.

## Validação

23 testes do motor e 22 verificações de interface passaram em Windows PowerShell 5.1 e PowerShell 7.6.3. Testes usam AD falso; descoberta real foi validada separadamente, apenas para os metadados dos controladores dos dois domínios. Nenhum usuário real foi consultado ou alterado. Renderizações normal e mínima foram inspecionadas. Revisão independente não encontrou bugs concretos. Preferência de formato do CPF salva pelo usuário foi preservada.
