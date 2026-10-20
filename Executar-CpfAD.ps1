#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Csv,
    [Parameter(Mandatory)][string]$ConfigJson,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$Codificacao = 'utf-8',
    [bool]$Aplicar = $false,
    [string]$PlanoJson = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CpfAd.psm1') -Force
$config = $ConfigJson | ConvertFrom-Json
$allowDisable = $false
if ($config.PSObject.Properties.Name -contains 'DesativarUsuarios') {
    if ($config.DesativarUsuarios -isnot [bool]) { throw 'DesativarUsuarios deve ser true ou false na configuração.' }
    $allowDisable = $config.DesativarUsuarios
}
$rows = @(Import-CpfCsv -Path $Csv -Encoding $Codificacao)
if ($rows.Count -eq 0) { throw 'O CSV não contém registros de usuários.' }
$options = @{}
$plan = @()
if ($Aplicar) {
    if (-not $PlanoJson) { throw 'A interface exige uma simulação antes de aplicar.' }
    # PowerShell 5.1 retorna arrays JSON como um único objeto no pipeline.
    $plan = @($PlanoJson | ConvertFrom-Json | ForEach-Object { $_ })
    if ($plan.Count -ne $rows.Count) { throw 'O CSV não corresponde à quantidade de registros da simulação. Simule novamente.' }
    $actualRows = @{}
    foreach ($row in $rows) { $actualRows[[string]$row.Registro] = $row }
    $seenRecords = @{}
    foreach ($item in $plan) {
        $key = [string]$item.Registro
        if (-not $actualRows.ContainsKey($key) -or $seenRecords.ContainsKey($key)) { throw 'O plano não corresponde aos registros do CSV. Simule novamente.' }
        $seenRecords[$key] = $true
        $row = $actualRows[$key]
        $expectedAction = 'PREENCHER_CPF'
        if ((ConvertTo-DomainKey $row.Login) -eq 'DESATIVAR') { $expectedAction = 'DESATIVAR' }
        if ($item.PSObject.Properties.Name -notcontains 'ConcluidoPlanilha' -or $item.PSObject.Properties.Name -notcontains 'Acao') { throw 'O plano usa uma versão antiga. Simule novamente.' }
        if ((ConvertTo-DomainKey $row.Nome) -ne (ConvertTo-DomainKey $item.Nome) -or
            (ConvertTo-DomainKey $row.Dominio) -ne (ConvertTo-DomainKey $item.Dominio) -or
            ([string]$row.Login).Trim() -ine ([string]$item.Login).Trim() -or
            ($row.Cpf -replace '[^0-9]', '') -ne ($item.CpfPlanilha -replace '[^0-9]', '') -or
            (ConvertTo-DomainKey $row.Concluido) -ne (ConvertTo-DomainKey ([string]$item.ConcluidoPlanilha)) -or
            $item.Acao -cne $expectedAction) {
            throw "Os dados do registro $key mudaram em relação à simulação. Simule novamente antes de aplicar."
        }
    }
    $expected = @{}
    $expectedLogins = @{}
    foreach ($item in $plan) {
        if ($item.Status -in @('SIMULADO_PREENCHER', 'SIMULADO_DESATIVAR')) {
            if (($item.Status -eq 'SIMULADO_DESATIVAR' -and ($item.Acao -ne 'DESATIVAR' -or -not $allowDisable)) -or
                ($item.Status -eq 'SIMULADO_PREENCHER' -and $item.Acao -ne 'PREENCHER_CPF')) { throw 'A ação da simulação não corresponde às opções atuais. Simule novamente.' }
            if ($item.PSObject.Properties.Name -notcontains 'LoginEncontrado' -or [string]::IsNullOrWhiteSpace([string]$item.LoginEncontrado)) { throw 'A simulação não confirmou o login da conta. Simule novamente.' }
            $expected[[string]$item.Registro] = ([guid]$item.ObjectGuid).ToString()
            $expectedLogins[[string]$item.Registro] = [string]$item.LoginEncontrado
        }
    }
    if ($expected.Count -eq 0) { throw 'A simulação não contém usuários prontos para aplicar.' }
    $rows = @($rows | Where-Object { $expected.ContainsKey([string]$_.Registro) })
    if ($rows.Count -ne $expected.Count) { throw 'O CSV não corresponde aos registros da simulação.' }
    $options.ExpectedIdentities = $expected
    $options.ExpectedLogins = $expectedLogins
}
$adapter = Get-AdAdapter
$results = @(Invoke-CpfSync -Rows $rows -Config $config -Adapter $adapter -ReportPath $ReportPath -Aplicar:$Aplicar @options)
if ($Aplicar) {
    $updated = @{}
    foreach ($row in $results) { $updated[[string]$row.Registro] = $row }
    $results = @(foreach ($item in $plan) { if ($updated.ContainsKey([string]$item.Registro)) { $updated[[string]$item.Registro] } else { $item } })
    $results | Export-Csv -LiteralPath $ReportPath -Delimiter ';' -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
}
[pscustomobject]@{ Results = $results; Report = $ReportPath }
