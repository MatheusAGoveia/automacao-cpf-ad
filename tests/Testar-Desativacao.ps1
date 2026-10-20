#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'CpfAd.psm1') -Force
$temp = Join-Path ([IO.Path]::GetTempPath()) ('cpf-ad-disable-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$script:passed = 0

function Assert-Disable($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -cne [string]$Expected) { throw "$Message — esperado '$Expected', recebido '$Actual'." }
}
function Disable-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Host "OK: $Name"
}
function New-DisableRow([string]$Domain = 'BETIM.PMB', [string]$Login = ' desativar ', [string]$Name = 'Pessoa Exemplo A', [string]$Cpf = '', [string]$Done = 'FALSE', [int]$Record = 2) {
    [pscustomobject]@{ Registro = $Record; Nome = $Name; Dominio = $Domain; Login = $Login; Cpf = $Cpf; Concluido = $Done }
}
function New-DisableFixture {
    $state = @{
        Users = @(
            [pscustomobject]@{ Domain = 'BETIM.PMB'; Name = 'Pessoa Exemplo A'; DisplayName = 'Pessoa Exemplo A'; SamAccountName = 'pessoa.betim'; ObjectGUID = [guid]::NewGuid(); CPF = ''; Enabled = $true },
            [pscustomobject]@{ Domain = 'SAUDE.BETIM'; Name = 'Pessoa Exemplo A'; DisplayName = 'Pessoa Exemplo A'; SamAccountName = 'pessoa.saude'; ObjectGUID = [guid]::NewGuid(); CPF = ''; Enabled = $true }
        )
        Finds = (New-Object 'System.Collections.Generic.List[string]'); ValidatedAttributes = (New-Object 'System.Collections.Generic.List[string]')
        Writes = 0; Disables = 0; Reads = 0; FailDisable = $false; FailConfirmation = $false; KeepEnabled = $false
        RenameOnRead = $false; ChangeLoginOnRead = $false; DisableOnRead = $false
    }
    $adapter = @{
        DiscoverServer = { param($Domain) 'dc.' + $Domain.ToLowerInvariant() }
        ValidateServer = {
            param($Server, $Attribute, $Domain)
            $state.ValidatedAttributes.Add([string]$Attribute)
            if ($Server -ine ('dc.' + $Domain.ToLowerInvariant())) { throw 'Servidor pertence a outro domínio.' }
            $Server
        }.GetNewClosure()
        Find = {
            param($Server, $Attribute, $Login, $Name)
            $state.Finds.Add($Server)
            $domain = $Server -replace '^dc\.', ''
            foreach ($user in $state.Users) {
                if ($user.Domain -ieq $domain -and (($Login -and $user.SamAccountName -ieq $Login) -or (-not $Login -and ($user.Name -ieq $Name -or $user.DisplayName -ieq $Name)))) { $user.PSObject.Copy() }
            }
        }.GetNewClosure()
        Read = {
            param($Server, $Attribute, $Identity)
            $state.Reads++
            if ($state.FailConfirmation -and $state.Disables -gt 0) { throw 'Falha de conexão na confirmação.' }
            $user = @($state.Users | Where-Object { $_.ObjectGUID -eq $Identity -and $_.Domain -ieq ($Server -replace '^dc\.', '') })[0]
            if ($state.RenameOnRead) { $user.Name = 'Outra Pessoa'; $user.DisplayName = 'Outra Pessoa' }
            if ($state.ChangeLoginOnRead) { $user.SamAccountName = 'login.alterado' }
            if ($state.DisableOnRead) { $user.Enabled = $false }
            $user.PSObject.Copy()
        }.GetNewClosure()
        Add = {
            param($Server, $Attribute, $Identity, $Value)
            $state.Writes++
            (@($state.Users | Where-Object { $_.ObjectGUID -eq $Identity })[0]).CPF = $Value
        }.GetNewClosure()
        Disable = {
            param($Server, $Identity)
            if ($state.FailDisable) { throw 'Acesso negado à desativação.' }
            $state.Disables++
            $user = @($state.Users | Where-Object { $_.ObjectGUID -eq $Identity -and $_.Domain -ieq ($Server -replace '^dc\.', '') })[0]
            if (-not $state.KeepEnabled) { $user.Enabled = $false }
        }.GetNewClosure()
    }
    [pscustomobject]@{ State = $state; Adapter = $adapter }
}
function New-DisableConfig([bool]$Enabled = $true) {
    [pscustomobject]@{ AtributoCpf = 'CPF'; FormatoCpf = 'Numeros'; DesativarUsuarios = $Enabled; Dominios = [pscustomobject]@{ 'BETIM.PMB' = ''; 'SAÚDE.BETIM' = '' } }
}
function Invoke-DisableTest($Fixture, [object[]]$Rows, [switch]$Apply, $Config = (New-DisableConfig), [hashtable]$ExpectedIdentities, [hashtable]$ExpectedLogins) {
    $report = Join-Path $temp ([guid]::NewGuid().ToString('N') + '.csv')
    $options = @{}
    if ($null -ne $ExpectedIdentities) { $options.ExpectedIdentities = $ExpectedIdentities }
    if ($null -ne $ExpectedLogins) { $options.ExpectedLogins = $ExpectedLogins }
    $results = @(Invoke-CpfSync -Rows $Rows -Config $Config -Adapter $Fixture.Adapter -ReportPath $report -Aplicar:$Apply @options)
    Assert-Disable @(Import-Csv -LiteralPath $report -Delimiter ';' -Encoding UTF8).Count $Rows.Count 'Relatório completo'
    return $results
}

try {
    Disable-Case 'Opção desligada ou ausente impede consultas e escritas para desativar' {
        foreach ($settings in @((New-DisableConfig $false), ('{"AtributoCpf":"CPF","Dominios":{}}' | ConvertFrom-Json))) {
            $fixture = New-DisableFixture
            $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply -Config $settings
            Assert-Disable $result[0].Status 'DESATIVACAO_DESLIGADA' 'Ação desligada'
            Assert-Disable $fixture.State.Finds.Count 0 'Sem consultas de usuários'
            Assert-Disable $fixture.State.Disables 0 'Nenhuma desativação'
        }
    }
    Disable-Case 'Configuração não booleana nunca habilita desativação por coerção' {
        foreach ($value in @('false', 'true', 'FALSE', 1, 0, $null)) {
            $fixture = New-DisableFixture; $settings = New-DisableConfig; $settings.DesativarUsuarios = $value
            try { Invoke-DisableTest $fixture @(New-DisableRow) -Apply -Config $settings | Out-Null } catch { }
            Assert-Disable $fixture.State.Disables 0 'Somente booleano verdadeiro habilita'
            Assert-Disable $fixture.State.Finds.Count 0 'Não consulta usuários para opção inválida'
        }
    }
    Disable-Case 'Simulação aceita desativar com espaços/caixa, sem conclusão e sem CPF' {
        $fixture = New-DisableFixture
        $result = Invoke-DisableTest $fixture @(New-DisableRow -Login '  DeSaTiVaR  ')
        Assert-Disable $result[0].Status 'SIMULADO_DESATIVAR' 'Candidato'
        Assert-Disable $result[0].Acao 'DESATIVAR' 'Ação explícita'
        Assert-Disable $result[0].ConcluidoPlanilha 'FALSE' 'Conclusão original registrada'
        Assert-Disable $result[0].LoginEncontrado 'pessoa.betim' 'Login verdadeiro identificado'
        Assert-Disable $fixture.State.ValidatedAttributes[0] '' 'Desativar não exige atributo CPF no schema'
        Assert-Disable $fixture.State.Disables 0 'Simular não escreve'
    }
    Disable-Case 'Desativação também independe de CPF inválido ou já preenchido' {
        $fixture = New-DisableFixture
        $fixture.State.Users[0].CPF = 'CPF legado preservado'
        $result = Invoke-DisableTest $fixture @(New-DisableRow -Cpf 'invalido') -Apply
        Assert-Disable $result[0].Status 'DESATIVADO' 'Conta desativada'
        Assert-Disable $fixture.State.Users[0].CPF 'CPF legado preservado' 'CPF preservado'
        Assert-Disable $fixture.State.Writes 0 'Nenhuma escrita CPF'
    }
    Disable-Case 'Mesmo nome nos dois ADs desativa somente o domínio informado' {
        foreach ($domain in @('BETIM.PMB', 'SAÚDE.BETIM')) {
            $fixture = New-DisableFixture
            $result = Invoke-DisableTest $fixture @(New-DisableRow -Domain $domain) -Apply
            $key = ConvertTo-DomainKey $domain
            $targetUser = @($fixture.State.Users | Where-Object { $_.Domain -eq $key })[0]
            $otherUser = @($fixture.State.Users | Where-Object { $_.Domain -ne $key })[0]
            Assert-Disable $result[0].Status 'DESATIVADO' 'Conta do domínio escolhido'
            Assert-Disable $targetUser.Enabled $false 'Conta escolhida desativada'
            Assert-Disable $otherUser.Enabled $true 'Outro domínio preservado'
            Assert-Disable @($fixture.State.Finds | Select-Object -Unique).Count 1 'Um único domínio consultado'
            Assert-Disable $fixture.State.Disables 1 'Uma desativação'
        }
    }
    Disable-Case 'Conta já desativada é informada sem nova escrita' {
        $fixture = New-DisableFixture; $fixture.State.Users[0].Enabled = $false
        $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply
        Assert-Disable $result[0].Status 'JA_DESATIVADO' 'Estado já atendido'
        Assert-Disable $fixture.State.Disables 0 'Sem repetição'
    }
    Disable-Case 'Conta desativada entre busca e releitura não recebe nova escrita' {
        $fixture = New-DisableFixture; $fixture.State.DisableOnRead = $true
        $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply
        Assert-Disable $result[0].Status 'JA_DESATIVADO' 'Releitura prevalece'
        Assert-Disable $fixture.State.Disables 0 'Sem repetição'
    }
    Disable-Case 'Homônimos no domínio impedem escolha automática' {
        $fixture = New-DisableFixture
        $copy = $fixture.State.Users[0].PSObject.Copy(); $copy.ObjectGUID = [guid]::NewGuid(); $copy.SamAccountName = 'homonimo'
        $fixture.State.Users += $copy
        $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply
        Assert-Disable $result[0].Status 'USUARIO_AMBIGUO' 'Ambiguidade'
        Assert-Disable $fixture.State.Disables 0 'Homônimos preservados'
    }
    Disable-Case 'Nome divergente, usuário ausente e domínio vazio não desativam' {
        foreach ($row in @((New-DisableRow -Name 'Pessoa Exemplo'), (New-DisableRow -Domain ''))) {
            $fixture = New-DisableFixture
            $result = Invoke-DisableTest $fixture @($row) -Apply
            if ($row.Dominio) { Assert-Disable $result[0].Status 'USUARIO_NAO_ENCONTRADO' 'Sem aproximação de nome' }
            else { Assert-Disable $result[0].Status 'SEM_DOMINIO' 'Domínio obrigatório' }
            Assert-Disable $fixture.State.Disables 0 'Nenhuma desativação'
        }
    }
    Disable-Case 'Frases e ações diferentes não são tratadas como desativar' {
        foreach ($login in @('não desativar', 'desativar depois', 'desativar.usuario', 'excluir', 'remover')) {
            $fixture = New-DisableFixture
            $result = Invoke-DisableTest $fixture @(New-DisableRow -Login $login -Cpf '00000000191' -Done 'TRUE') -Apply
            Assert-Disable $fixture.State.Disables 0 "Não desativar para '$login'"
        }
    }
    Disable-Case 'Estado Enabled ausente impede desativação por suposição' {
        $fixture = New-DisableFixture; $fixture.State.Users[0].PSObject.Properties.Remove('Enabled')
        $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply
        Assert-Disable $fixture.State.Disables 0 'Não assume conta habilitada'
        Assert-Disable ($result[0].Status -like 'ERRO_*') $true 'Estado desconhecido exige revisão'
    }
    Disable-Case 'Enabled nulo ou texto não equivale a ativo ou já desativado' {
        foreach ($value in @($null, 'false', 'true', 0, 1)) {
            $fixture = New-DisableFixture; $fixture.State.Users[0].Enabled = $value
            $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply
            Assert-Disable $fixture.State.Disables 0 'Estado inválido impede escrita'
            Assert-Disable ($result[0].Status -like 'ERRO_*') $true 'Estado inválido exige revisão'
        }
    }
    Disable-Case 'Linhas desativar repetidas geram somente uma escrita' {
        $fixture = New-DisableFixture
        $result = Invoke-DisableTest $fixture @((New-DisableRow), (New-DisableRow -Record 3)) -Apply
        Assert-Disable $result[0].Status 'DESATIVADO' 'Linha principal'
        Assert-Disable $result[1].Status 'LINHA_REPETIDA' 'Linha duplicada'
        Assert-Disable $fixture.State.Disables 1 'Sem escrita duplicada'
    }
    Disable-Case 'Mesmo objeto com CPF e desativação conflitantes bloqueia ambas as ações' {
        $fixture = New-DisableFixture
        $result = Invoke-DisableTest $fixture @((New-DisableRow), (New-DisableRow -Login 'pessoa.betim' -Cpf '00000000191' -Done 'TRUE' -Record 3)) -Apply
        Assert-Disable @($result | Where-Object { $_.Status -eq 'CONFLITO_ACOES' }).Count 2 'Todas as linhas em conflito'
        Assert-Disable $fixture.State.Disables 0 'Sem desativação'
        Assert-Disable $fixture.State.Writes 0 'Sem CPF'
    }
    Disable-Case 'Nome ou login alterado na releitura bloqueia desativação' {
        foreach ($field in @('RenameOnRead', 'ChangeLoginOnRead')) {
            $fixture = New-DisableFixture; $fixture.State[$field] = $true
            $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply
            Assert-Disable $result[0].Status 'IDENTIDADE_ALTERADA' 'Identidade alterada'
            Assert-Disable $fixture.State.Disables 0 'Nenhuma desativação'
        }
    }
    Disable-Case 'GUID ou login esperado da simulação precisa coincidir' {
        foreach ($kind in @('Guid', 'Login')) {
            $fixture = New-DisableFixture
            $guid = [string]$fixture.State.Users[0].ObjectGUID; $login = 'pessoa.betim'
            if ($kind -eq 'Guid') { $guid = [string][guid]::NewGuid() } else { $login = 'login.diferente' }
            $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply -ExpectedIdentities @{ '2' = $guid } -ExpectedLogins @{ '2' = $login }
            Assert-Disable $result[0].Status 'IDENTIDADE_ALTERADA' 'Plano vincula identidade'
            Assert-Disable $fixture.State.Disables 0 'Nenhuma desativação'
        }
    }
    Disable-Case 'Erro de permissão é relatado sem marcar como desativado' {
        $fixture = New-DisableFixture; $fixture.State.FailDisable = $true
        $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply
        Assert-Disable $result[0].Status 'ERRO_PROCESSAMENTO' 'Falha explícita'
        Assert-Disable ($result[0].Detalhe -like '*Acesso negado*') $true 'Causa preservada'
        Assert-Disable $fixture.State.Users[0].Enabled $true 'Conta permanece ativa'
    }
    Disable-Case 'Escrita sem confirmação fica identificada para revisão' {
        foreach ($field in @('FailConfirmation', 'KeepEnabled')) {
            $fixture = New-DisableFixture; $fixture.State[$field] = $true
            $result = Invoke-DisableTest $fixture @(New-DisableRow) -Apply
            Assert-Disable $result[0].Status 'DESATIVADO_SEM_CONFIRMACAO' 'Não anuncia confirmação inexistente'
            Assert-Disable $fixture.State.Disables 1 'Uma tentativa de escrita'
        }
    }
    Disable-Case 'CPF continua exigindo conclusão mesmo com desativação habilitada' {
        $fixture = New-DisableFixture
        $result = Invoke-DisableTest $fixture @(New-DisableRow -Login 'pessoa.betim' -Cpf '00000000191') -Apply
        Assert-Disable $result[0].Status 'NAO_CONCLUIDO' 'Regra de CPF preservada'
        Assert-Disable $fixture.State.Writes 0 'Sem CPF indevido'
    }

    # Exercitar os cmdlets do adaptador e o worker reais com módulo AD inteiramente falso.
    New-Module -Name ActiveDirectory -ScriptBlock {
        function Get-ADDomainController { [CmdletBinding()] param([switch]$Discover,$DomainName,[switch]$Writable,$Service) $global:DisablePlan.Calls++; [pscustomobject]@{ HostName = @('dc.' + $DomainName); Domain = $DomainName } }
        function Get-ADRootDSE { [CmdletBinding()] param($Server) $global:DisablePlan.Calls++; [pscustomobject]@{ schemaNamingContext = 'CN=Schema'; defaultNamingContext = ('DC=' + (($Server -replace '^dc\.', '') -replace '\.', ',DC=')); dnsHostName = $Server } }
        function Get-ADObject {
            [CmdletBinding()] param($Server,$SearchBase,$LDAPFilter,$Properties)
            $global:DisablePlan.SchemaCalls++
            if (-not $global:DisablePlan.AllowSchema) { throw 'Uma desativação não pode exigir atributo CPF no schema.' }
            [pscustomobject]@{ isSingleValued = $true }
        }
        function Get-ADUser {
            [CmdletBinding()] param($Server,$LDAPFilter,$Properties,$Identity)
            $global:DisablePlan.Calls++
            if ($Identity) { @($global:DisablePlan.Users | Where-Object { $_.ObjectGUID -eq $Identity -and $_.Domain -ieq ($Server -replace '^dc\.', '') }) | ForEach-Object { $_.PSObject.Copy() } }
            else {
                foreach ($user in $global:DisablePlan.Users) {
                    if ($user.Domain -ine ($Server -replace '^dc\.', '')) { continue }
                    if ($LDAPFilter -eq ('(sAMAccountName=' + $user.SamAccountName + ')') -or $LDAPFilter -eq ('(|(name=' + $user.Name + ')(displayName=' + $user.Name + '))')) { $user.PSObject.Copy() }
                }
            }
        }
        function Disable-ADAccount {
            [CmdletBinding(SupportsShouldProcess)] param($Server,$Identity)
            $global:DisablePlan.Disables++
            (@($global:DisablePlan.Users | Where-Object { $_.ObjectGUID -eq $Identity -and $_.Domain -ieq ($Server -replace '^dc\.', '') })[0]).Enabled = $false
        }
        function Set-ADUser {
            [CmdletBinding(SupportsShouldProcess)] param($Server,$Identity,$Add)
            $global:DisablePlan.CpfWrites++
            if (-not $global:DisablePlan.AllowSchema) { throw 'Desativar não deve escrever CPF.' }
            (@($global:DisablePlan.Users | Where-Object { $_.ObjectGUID -eq $Identity -and $_.Domain -ieq ($Server -replace '^dc\.', '') })[0]).CPF = $Add['CPF']
        }
        Export-ModuleMember -Function Get-ADDomainController,Get-ADRootDSE,Get-ADObject,Get-ADUser,Disable-ADAccount,Set-ADUser
    } | Import-Module -Global -Force

    function New-DisablePlanFixture {
        $fixture = New-DisableFixture
        $global:DisablePlan = @{ Users = $fixture.State.Users; Calls = 0; Disables = 0; SchemaCalls = 0; AllowSchema = $false; CpfWrites = 0 }
        $csv = Join-Path $temp ([guid]::NewGuid().ToString('N') + '.csv')
        [IO.File]::WriteAllText($csv, "NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO`r`nPessoa Exemplo A,SAÚDE.BETIM,desativar,,FALSE", (New-Object Text.UTF8Encoding($true)))
        return $csv
    }
    function Invoke-DisablePlan([string]$Csv, [object[]]$Plan, [switch]$Apply, [bool]$EnableOption = $true) {
        $configJson = New-DisableConfig $EnableOption | ConvertTo-Json -Depth 5 -Compress
        $report = Join-Path $temp ([guid]::NewGuid().ToString('N') + '.csv')
        $json = ''; if ($Apply) { $json = ConvertTo-Json -InputObject $Plan -Depth 5 -Compress }
        & (Join-Path $root 'Executar-CpfAD.ps1') -Csv $Csv -ConfigJson $configJson -ReportPath $report -Aplicar ([bool]$Apply) -PlanoJson $json
    }
    Disable-Case 'Worker real simula e desativa conta do domínio indicado, sem schema CPF' {
        $csv = New-DisablePlanFixture
        $simulation = Invoke-DisablePlan $csv
        Assert-Disable $simulation.Results[0].Status 'SIMULADO_DESATIVAR' 'Simulação do worker'
        $applied = Invoke-DisablePlan $csv @($simulation.Results) -Apply
        Assert-Disable $applied.Results[0].Status 'DESATIVADO' 'Aplicação confirmada'
        Assert-Disable $global:DisablePlan.Users[0].Enabled $true 'Betim preservado'
        Assert-Disable $global:DisablePlan.Users[1].Enabled $false 'Saúde desativado'
        Assert-Disable $global:DisablePlan.Disables 1 'Uma chamada Disable-ADAccount'
        Assert-Disable $global:DisablePlan.SchemaCalls 0 'Desativação não consultou schemaCPF'
    }
    Disable-Case 'Cache de domínio não dispensa validação CPF após linha desativar' {
        $csv = New-DisablePlanFixture
        $global:DisablePlan.AllowSchema = $true
        $user = $global:DisablePlan.Users[1].PSObject.Copy(); $user.Name = 'Pessoa CPF'; $user.DisplayName = 'Pessoa CPF'; $user.SamAccountName = 'pessoa.cpf'; $user.ObjectGUID = [guid]::NewGuid()
        $global:DisablePlan.Users += $user
        [IO.File]::AppendAllText($csv, "`r`nPessoa CPF,SAÚDE.BETIM,pessoa.cpf,00000000191,TRUE", (New-Object Text.UTF8Encoding($true)))
        $simulation = Invoke-DisablePlan $csv
        Assert-Disable $simulation.Results[0].Status 'SIMULADO_DESATIVAR' 'Primeiro desativar'
        Assert-Disable $simulation.Results[1].Status 'SIMULADO_PREENCHER' 'Depois CPF'
        Assert-Disable $global:DisablePlan.SchemaCalls 1 'CPF verifica schema mesmo com domínio já validado'
        $applied = Invoke-DisablePlan $csv @($simulation.Results) -Apply
        Assert-Disable $applied.Results[0].Status 'DESATIVADO' 'Desativação aplicada'
        Assert-Disable $applied.Results[1].Status 'ATUALIZADO' 'CPF aplicado'
        Assert-Disable $global:DisablePlan.Disables 1 'Uma desativação'
        Assert-Disable $global:DisablePlan.CpfWrites 1 'Uma gravação CPF'
    }
    Disable-Case 'Worker rejeita alteração de conclusão, ação ou domínio após simulação' {
        foreach ($line in @('Pessoa Exemplo A,SAÚDE.BETIM,desativar,,TRUE','Pessoa Exemplo A,SAÚDE.BETIM,pessoa.saude,,FALSE','Pessoa Exemplo A,BETIM.PMB,desativar,,FALSE')) {
            $csv = New-DisablePlanFixture
            $simulation = Invoke-DisablePlan $csv
            $calls = $global:DisablePlan.Calls
            [IO.File]::WriteAllText($csv, "NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO`r`n$line", (New-Object Text.UTF8Encoding($true)))
            $rejected = $false
            try { Invoke-DisablePlan $csv @($simulation.Results) -Apply | Out-Null } catch { $rejected = $true }
            Assert-Disable $rejected $true 'Plano alterado rejeitado'
            Assert-Disable $global:DisablePlan.Calls $calls 'Rejeita antes de consultar AD'
            Assert-Disable $global:DisablePlan.Disables 0 'Sem escrita'
        }
    }
    Disable-Case 'Worker não aplica desativação se opção foi desligada após simular' {
        $csv = New-DisablePlanFixture
        $simulation = Invoke-DisablePlan $csv
        try { Invoke-DisablePlan $csv @($simulation.Results) -Apply -EnableOption $false | Out-Null } catch { }
        Assert-Disable $global:DisablePlan.Disables 0 'Opção desligada prevalece'
    }
    Disable-Case 'Worker vincula GUID e login real encontrado na simulação' {
        foreach ($property in @('ObjectGUID','SamAccountName')) {
            $csv = New-DisablePlanFixture
            $simulation = Invoke-DisablePlan $csv
            if ($property -eq 'ObjectGUID') { $global:DisablePlan.Users[1].ObjectGUID = [guid]::NewGuid() }
            else { $global:DisablePlan.Users[1].SamAccountName = 'login.trocado' }
            $applied = Invoke-DisablePlan $csv @($simulation.Results) -Apply
            Assert-Disable $applied.Results[0].Status 'IDENTIDADE_ALTERADA' 'Conta alterada bloqueada'
            Assert-Disable $global:DisablePlan.Disables 0 'Sem escrita'
        }
    }
    Write-Host "$script:passed cenários de desativação passaram. Nenhum AD real acessado."
} finally {
    Remove-Module ActiveDirectory -Force -ErrorAction SilentlyContinue
    Remove-Variable DisablePlan -Scope Global -ErrorAction SilentlyContinue
    $target = [IO.Path]::GetFullPath($temp)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cpf-ad-disable-test-'
    if ($target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $target -Recurse -Force }
}
