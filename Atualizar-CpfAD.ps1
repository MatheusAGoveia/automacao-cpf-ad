#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Csv,
    [string]$Configuracao = (Join-Path $PSScriptRoot 'dominios.json'),
    [string]$PastaRelatorios = (Join-Path $PSScriptRoot 'relatorios'),
    [string]$Codificacao = 'utf-8',
    [switch]$Aplicar,
    [switch]$DesativarUsuarios
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CpfAd.psm1') -Force
$config = Get-Content -LiteralPath $Configuracao -Raw -Encoding UTF8 | ConvertFrom-Json
$config | Add-Member -NotePropertyName DesativarUsuarios -NotePropertyValue ([bool]$DesativarUsuarios) -Force
$rows = @(Import-CpfCsv -Path $Csv -Encoding $Codificacao)
if ($rows.Count -eq 0) { throw 'O CSV não contém registros de usuários.' }
$adapter = Get-AdAdapter
$null = New-Item -ItemType Directory -Path $PastaRelatorios -Force
$mode = 'simulacao'
if ($Aplicar) { $mode = 'aplicacao' }
$report = Join-Path $PastaRelatorios ('cpf-ad-{0}-{1}-{2}.csv' -f $mode, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8)))
Write-Host ("Modo: {0}. Registros: {1}." -f $mode, $rows.Count)
$results = @(Invoke-CpfSync -Rows $rows -Config $config -Adapter $adapter -ReportPath $report -Aplicar:$Aplicar)
$results | Group-Object Status | Sort-Object Name | Select-Object @{Name = 'Situacao'; Expression = { $_.Name }}, Count | Format-Table -AutoSize
Write-Host "Relatório: $report"
if (-not $Aplicar) { Write-Host 'Simulação concluída. Para gravar, execute o mesmo comando com -Aplicar.' }
$issues = @($results | Where-Object { $_.Status -in @('ERRO_CONSULTA', 'ERRO_PROCESSAMENTO', 'GRAVADO_SEM_CONFIRMACAO', 'DESATIVADO_SEM_CONFIRMACAO', 'DOMINIO_NAO_LOCALIZADO', 'SEM_DOMINIO') })
if ($issues.Count -gt 0) { Write-Warning 'Há registros com erro ou configuração pendente. Consulte Status e Detalhe no relatório.' }
