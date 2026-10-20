#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$workerPath = Join-Path $root 'Executar-CpfAD.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('cpf-ad-plan-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$script:passed = 0
$configJson = '{"AtributoCpf":"CPF","FormatoCpf":"Numeros","Dominios":{"BETIM.PMB":""}}'
$header = 'NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO'
$first = 'Pessoa Exemplo A,BETIM.PMB,pessoa.a,00000000191,TRUE'
$second = 'Pessoa Exemplo B,BETIM.PMB,pessoa.b,00000000272,TRUE'

function Assert-Plan($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -cne [string]$Expected) { throw "$Message — esperado '$Expected', recebido '$Actual'." }
}
function Plan-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Host "OK: $Name"
}
function New-PlanFixture([switch]$TwoRows) {
    $csv = Join-Path $temp ([guid]::NewGuid().ToString('N') + '.csv')
    $lines = @($header, $first)
    if ($TwoRows) { $lines += $second }
    [IO.File]::WriteAllText($csv, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
    $global:CpfPlanDirectory = @{
        'pessoa.a' = [pscustomobject]@{ Name = 'Pessoa Exemplo A'; DisplayName = 'Pessoa Exemplo A'; SamAccountName = 'pessoa.a'; ObjectGUID = [guid]::NewGuid(); CPF = '' }
        'pessoa.b' = [pscustomobject]@{ Name = 'Pessoa Exemplo B'; DisplayName = 'Pessoa Exemplo B'; SamAccountName = 'pessoa.b'; ObjectGUID = [guid]::NewGuid(); CPF = '' }
    }
    $global:CpfPlanCalls = @{ Queries = 0; Writes = 0 }
    return $csv
}
function Invoke-PlanWorker([string]$Csv, [object[]]$Plan, [switch]$Apply) {
    $report = Join-Path $temp ([guid]::NewGuid().ToString('N') + '.csv')
    $json = ''; if ($Apply) { $json = ConvertTo-Json -InputObject $Plan -Depth 5 -Compress }
    & $workerPath -Csv $Csv -ConfigJson $configJson -ReportPath $report -Aplicar ([bool]$Apply) -PlanoJson $json
}

# Todos os comandos AD são falsos, mas o worker e o motor são os arquivos reais.
New-Module -Name ActiveDirectory -ScriptBlock {
    function Get-ADDomainController {
        [CmdletBinding()] param([switch]$Discover, $DomainName, [switch]$Writable, $Service)
        $global:CpfPlanCalls.Queries++
        [pscustomobject]@{ HostName = @('dc.' + $DomainName); Domain = $DomainName }
    }
    function Get-ADRootDSE {
        [CmdletBinding()] param($Server)
        $global:CpfPlanCalls.Queries++
        [pscustomobject]@{ schemaNamingContext = 'CN=Schema'; defaultNamingContext = 'DC=betim,DC=pmb'; dnsHostName = $Server }
    }
    function Get-ADObject {
        [CmdletBinding()] param($Server, $SearchBase, $LDAPFilter, $Properties)
        $global:CpfPlanCalls.Queries++
        [pscustomobject]@{ isSingleValued = $true }
    }
    function Get-ADUser {
        [CmdletBinding()] param($Server, $LDAPFilter, $Properties, $Identity)
        $global:CpfPlanCalls.Queries++
        if ($Identity) { ($global:CpfPlanDirectory.Values | Where-Object { $_.ObjectGUID -eq $Identity }).PSObject.Copy() }
        else {
            $login = $LDAPFilter -replace '^\(sAMAccountName=', '' -replace '\)$', ''
            $global:CpfPlanDirectory[$login].PSObject.Copy()
        }
    }
    function Set-ADUser {
        [CmdletBinding(SupportsShouldProcess)] param($Server, $Identity, $Add)
        $global:CpfPlanCalls.Writes++
        ($global:CpfPlanDirectory.Values | Where-Object { $_.ObjectGUID -eq $Identity }).CPF = $Add['CPF']
    }
    Export-ModuleMember -Function Get-ADDomainController,Get-ADRootDSE,Get-ADObject,Get-ADUser,Set-ADUser
} | Import-Module -Global -Force

try {
    Plan-Case 'Plano aprovado grava somente o CPF numérico do mesmo usuário' {
        $csv = New-PlanFixture
        $simulation = Invoke-PlanWorker $csv
        $applied = Invoke-PlanWorker $csv @($simulation.Results) -Apply
        Assert-Plan $applied.Results[0].Status 'ATUALIZADO' 'Resultado'
        Assert-Plan $global:CpfPlanDirectory['pessoa.a'].CPF '00000000191' 'CPF gravado'
        Assert-Plan $global:CpfPlanCalls.Writes 1 'Quantidade de escritas'
    }
    Plan-Case 'Mudança de CPF, nome, login, domínio ou conclusão bloqueia antes de consultar AD' {
        foreach ($replacement in @(
            'Pessoa Exemplo A,BETIM.PMB,pessoa.a,00000000272,TRUE',
            'Outro Nome,BETIM.PMB,pessoa.a,00000000191,TRUE',
            'Pessoa Exemplo A,BETIM.PMB,outro.login,00000000191,TRUE',
            'Pessoa Exemplo A,SAÚDE.BETIM,pessoa.a,00000000191,TRUE',
            'Pessoa Exemplo A,BETIM.PMB,pessoa.a,00000000191,FALSE'
        )) {
            $csv = New-PlanFixture
            $simulation = Invoke-PlanWorker $csv
            $queries = $global:CpfPlanCalls.Queries
            [IO.File]::WriteAllText($csv, (@($header, $replacement) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
            $rejected = $false
            try { Invoke-PlanWorker $csv @($simulation.Results) -Apply | Out-Null } catch { $rejected = $_.Exception.Message -like '*mudaram*' }
            Assert-Plan $rejected $true 'Dados alterados rejeitados'
            Assert-Plan $global:CpfPlanCalls.Queries $queries 'Sem nova consulta após a divergência'
            Assert-Plan $global:CpfPlanCalls.Writes 0 'Nenhuma escrita'
        }
    }
    Plan-Case 'Inclusão de registro após simular invalida o plano completo' {
        $csv = New-PlanFixture
        $simulation = Invoke-PlanWorker $csv
        [IO.File]::WriteAllText($csv, (@($header, $first, $second) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
        $rejected = $false
        try { Invoke-PlanWorker $csv @($simulation.Results) -Apply | Out-Null } catch { $rejected = $_.Exception.Message -like '*quantidade*' }
        Assert-Plan $rejected $true 'Quantidade alterada'
        Assert-Plan $global:CpfPlanCalls.Writes 0 'Nenhuma escrita'
    }
    Plan-Case 'Registros repetidos no plano não substituem outra aprovação' {
        $csv = New-PlanFixture -TwoRows
        $simulation = Invoke-PlanWorker $csv
        $plan = @($simulation.Results)
        $plan[1].Registro = $plan[0].Registro
        $rejected = $false
        try { Invoke-PlanWorker $csv $plan -Apply | Out-Null } catch { $rejected = $_.Exception.Message -like '*plano não corresponde*' }
        Assert-Plan $rejected $true 'Plano ambíguo rejeitado'
        Assert-Plan $global:CpfPlanCalls.Writes 0 'Nenhuma escrita'
    }
    Plan-Case 'GUID modificado depois da simulação é bloqueado pelo motor' {
        $csv = New-PlanFixture
        $simulation = Invoke-PlanWorker $csv
        $global:CpfPlanDirectory['pessoa.a'].ObjectGUID = [guid]::NewGuid()
        $applied = Invoke-PlanWorker $csv @($simulation.Results) -Apply
        Assert-Plan $applied.Results[0].Status 'IDENTIDADE_ALTERADA' 'Usuário recriado'
        Assert-Plan $global:CpfPlanCalls.Writes 0 'Nenhuma escrita'
    }
    Plan-Case 'Linha duplicada resulta em uma escrita e permanece no relatório completo' {
        $csv = New-PlanFixture
        [IO.File]::WriteAllText($csv, (@($header, $first, $first) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
        $simulation = Invoke-PlanWorker $csv
        Assert-Plan $simulation.Results[1].Status 'LINHA_REPETIDA' 'Repetição reconhecida'
        $applied = Invoke-PlanWorker $csv @($simulation.Results) -Apply
        Assert-Plan $global:CpfPlanCalls.Writes 1 'Somente a principal gravada'
        Assert-Plan $applied.Results[1].Status 'LINHA_REPETIDA' 'Repetida preservada'
        $report = @(Import-Csv -LiteralPath $applied.Report -Delimiter ';' -Encoding UTF8)
        Assert-Plan $report.Count 2 'Relatório inclui ambas as linhas'
    }
    Write-Host "$script:passed cenários do plano passaram. Nenhum AD real acessado."
} finally {
    Remove-Module ActiveDirectory -Force -ErrorAction SilentlyContinue
    Remove-Variable CpfPlanDirectory,CpfPlanCalls -Scope Global -ErrorAction SilentlyContinue
    $target = [IO.Path]::GetFullPath($temp)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cpf-ad-plan-test-'
    if ($target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $target -Recurse -Force }
}
