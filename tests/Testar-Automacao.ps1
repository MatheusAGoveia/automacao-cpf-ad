#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'CpfAd.psm1') -Force
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('cpf-ad-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDir
$script:passed = 0

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -cne [string]$Expected) { throw "$Message — esperado '$Expected', recebido '$Actual'." }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Host "OK: $Name"
}
function New-Row([string]$Cpf = '000.000.001-91', [string]$Login = 'pessoa.a', [string]$Name = 'Pessoa Exemplo A', [string]$Done = 'TRUE') {
    [pscustomobject]@{ Registro = 3; Nome = $Name; Dominio = 'BETIM.PMB'; Login = $Login; Cpf = $Cpf; Concluido = $Done }
}
function New-Fixture {
    $state = @{
        User = [pscustomobject]@{ Name = 'Pessoa Exemplo A'; DisplayName = 'Pessoa Exemplo A'; SamAccountName = 'pessoa.a'; ObjectGUID = [guid]::NewGuid(); CPF = '' }
        Writes = 0; Reads = 0; Finds = 0; Count = 1; FailAdd = $false; FailReadAfterAdd = $false; ConcurrentCpf = ''; Rename = $false
        AllowDiscovery = $false; Discoveries = (New-Object 'System.Collections.Generic.List[string]'); FoundServers = (New-Object 'System.Collections.Generic.List[string]')
    }
    $adapter = @{
        DiscoverServer = {
            param($Domain)
            $state.Discoveries.Add($Domain)
            if (-not $state.AllowDiscovery) { throw 'Domínio indisponível no teste.' }
            switch ($Domain) { 'BETIM.PMB' { 'dc.betim.test' }; 'SAUDE.BETIM' { 'dc.saude.test' }; default { throw 'Domínio desconhecido.' } }
        }.GetNewClosure()
        ValidateServer = { param($Server, $Attribute) 'dc.exemplo.test' }
        Find = {
            param($Server, $Attribute, $Login, $Name)
            $state.Finds++
            $state.FoundServers.Add($Server)
            for ($n = 0; $n -lt $state.Count; $n++) { $state.User.PSObject.Copy() }
        }.GetNewClosure()
        Read = {
            param($Server, $Attribute, $Identity)
            $state.Reads++
            if ($state.FailReadAfterAdd -and $state.Writes -gt 0) { throw 'Sem conexão na confirmação.' }
            if ($state.ConcurrentCpf) { $state.User.CPF = $state.ConcurrentCpf }
            if ($state.Rename) { $state.User.Name = 'Outra Pessoa'; $state.User.DisplayName = 'Outra Pessoa' }
            $state.User.PSObject.Copy()
        }.GetNewClosure()
        Add = {
            param($Server, $Attribute, $Identity, $Value)
            if ($state.FailAdd) { throw 'Acesso negado.' }
            if ($state.User.CPF) { throw 'Campo já preenchido.' }
            $state.Writes++
            $state.User.CPF = $Value
        }.GetNewClosure()
    }
    [pscustomobject]@{ State = $state; Adapter = $adapter }
}
$config = '{"AtributoCpf":"CPF","FormatoCpf":"Formatado","Dominios":{"BETIM.PMB":"dominio.exemplo.test"}}' | ConvertFrom-Json
function Run-Sync($Fixture, [object[]]$Rows, [switch]$Apply, $Settings = $config) {
    $reportPath = Join-Path $testDir ([guid]::NewGuid().ToString('N') + '.csv')
    $output = @(Invoke-CpfSync -Rows $Rows -Config $Settings -Adapter $Fixture.Adapter -ReportPath $reportPath -Aplicar:$Apply)
    $fromDisk = @(Import-Csv -LiteralPath $reportPath -Delimiter ';' -Encoding UTF8)
    Assert-Equal $fromDisk.Count $Rows.Count 'Relatório deve registrar todas as linhas'
    return $output
}

try {
    Test-Case 'CPF preserva zeros e rejeita formato/checksum inválido' {
        Assert-Equal (Test-Cpf '000.000.001-91') $true 'CPF de teste'
        Assert-Equal (Test-Cpf '00000000272') $true 'CPF sem pontuação'
        foreach ($bad in @('00000000000', '000.000.001-90', '1.91', '0E10', '=00000000191')) {
            Assert-Equal (Test-Cpf $bad) $false "Rejeitar $bad"
        }
    }
    Test-Case 'CSV Google com título, BOM, vírgula e cabeçalho acentuado' {
        $path = Join-Path $testDir 'google.csv'
        $csvText = '"CONFERIR NOME E CPF",,,,,,,' + "`r`n" + 'NOME COMPLETO,DOMINIO,NOVO LOGIN,DATA MUDANÇA,Sistemas SAÚDE,Sistemas ADM,CPF,CONCLUÍDO' + "`r`n" + '"Pessoa, Exemplo",BETIM.PMB,pessoa.a,,,,000.000.001-91,VERDADEIRO'
        [IO.File]::WriteAllText($path, $csvText, (New-Object Text.UTF8Encoding($true)))
        $rows = @(Import-CpfCsv $path)
        Assert-Equal $rows.Count 1 'Número de linhas'
        Assert-Equal $rows[0].Nome 'Pessoa, Exemplo' 'Vírgula em campo entre aspas'
        Assert-Equal $rows[0].Cpf '000.000.001-91' 'Zero inicial'
        Assert-Equal $rows[0].Registro 3 'Registro após título'
    }
    Test-Case 'CSV ponto e vírgula e Windows-1252' {
        $path = Join-Path $testDir 'excel.csv'
        $csvText = "NOME COMPLETO;DOMÍNIO;NOVO LOGIN;CPF;CONCLUÍDO`r`nPessoa Saúde;BETIM.PMB;pessoa.a;00000000191;TRUE"
        [IO.File]::WriteAllText($path, $csvText, [Text.Encoding]::GetEncoding(1252))
        $rows = @(Import-CpfCsv $path -Encoding 'windows-1252')
        Assert-Equal $rows[0].Nome 'Pessoa Saúde' 'Acentos'
        Assert-Equal $rows[0].Cpf '00000000191' 'CPF numérico continua sendo texto'
    }
    Test-Case 'CSV sem cabeçalhos obrigatórios é rejeitado' {
        $path = Join-Path $testDir 'invalido.csv'
        [IO.File]::WriteAllText($path, 'nome,cpf')
        $rejected = $false
        try { Import-CpfCsv $path | Out-Null } catch { $rejected = $true }
        Assert-Equal $rejected $true 'Rejeição do cabeçalho'
    }
    Test-Case 'CSV rejeita cabeçalhos duplicados após normalização sem emitir linhas' {
        $path = Join-Path $testDir 'duplicados.csv'
        foreach ($pair in @(
            @('NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO,CONCLUIDO', 'Pessoa Exemplo A,BETIM.PMB,pessoa.a,00000000191,FALSE,TRUE'),
            @('NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO, CPF ', 'Pessoa Exemplo A,BETIM.PMB,pessoa.a,00000000191,TRUE,00000000272')
        )) {
            [IO.File]::WriteAllText($path, ($pair -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
            $rejected = $false; $seen = New-Object 'System.Collections.Generic.List[object]'
            try { Import-CpfCsv $path | ForEach-Object { $seen.Add($_) } } catch { $rejected = $_.Exception.Message -like '*repetidos*' }
            Assert-Equal $rejected $true 'Cabeçalho ambíguo rejeitado'
            Assert-Equal $seen.Count 0 'Nenhuma linha emitida'
        }
    }
    Test-Case 'CSV com campos excedentes, faltantes ou aspas abertas é rejeitado integralmente' {
        $path = Join-Path $testDir 'estrutura.csv'
        $header = 'NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO'
        $valid = 'Pessoa Exemplo A,BETIM.PMB,pessoa.a,00000000191,TRUE'
        foreach ($broken in @(
            'Pessoa Exemplo B,BETIM.PMB,pessoa.b,00000000272,TRUE,00000000191',
            'Pessoa Exemplo B,BETIM.PMB,pessoa.b,00000000272',
            '"Pessoa Exemplo B,BETIM.PMB,pessoa.b,00000000272,TRUE'
        )) {
            [IO.File]::WriteAllText($path, (@($header, $valid, $broken) -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
            $rejected = $false; $seen = New-Object 'System.Collections.Generic.List[object]'
            try { Import-CpfCsv $path | ForEach-Object { $seen.Add($_) } } catch { $rejected = $true }
            Assert-Equal $rejected $true 'Estrutura inválida rejeitada'
            Assert-Equal $seen.Count 0 'Até a linha válida aguarda a validação integral'
        }
    }
    Test-Case 'CSV aceita campo entre aspas com quebra de linha e ignora checkbox sem usuário' {
        $path = Join-Path $testDir 'multilinha.csv'
        $text = 'NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO' + "`r`n" + ',,,,FALSE' + "`r`n" + '"Pessoa' + "`n" + 'Exemplo A",BETIM.PMB,pessoa.a,00000000191,TRUE' + "`r`n" + ',,,,TRUE'
        [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
        $rows = @(Import-CpfCsv $path)
        Assert-Equal $rows.Count 1 'Checkbox isolado não conta como usuário'
        Assert-Equal $rows[0].Registro 3 'Número do registro original preservado'
        Assert-Equal ($rows[0].Nome -replace '\s+', ' ') 'Pessoa Exemplo A' 'Quebra válida preservada no campo'
    }
    Test-Case 'Simulação consulta sem escrever e aplica idempotentemente' {
        $f = New-Fixture
        $r = @(Run-Sync $f @((New-Row)))
        Assert-Equal $r[0].Status 'SIMULADO_PREENCHER' 'Simulação'
        Assert-Equal $f.State.Writes 0 'Sem escrita'
        $r = @(Run-Sync $f @((New-Row)) -Apply)
        Assert-Equal $r[0].Status 'ATUALIZADO' 'Aplicação'
        Assert-Equal $f.State.User.CPF '00000000191' 'Grava somente 11 dígitos mesmo com configuração antiga Formatado'
        $r = @(Run-Sync $f @((New-Row)) -Apply)
        Assert-Equal $r[0].Status 'CPF_JA_CONFERE' 'Reexecução'
        Assert-Equal $f.State.Writes 1 'Somente uma escrita'
    }
    Test-Case 'Pendentes e concluídos sem CPF não consultam o AD' {
        $f = New-Fixture
        $r = @(Run-Sync $f @((New-Row -Done 'FALSE'), (New-Row -Cpf '')) -Apply)
        Assert-Equal $r[0].Status 'NAO_CONCLUIDO' 'Pendente'
        Assert-Equal ($r[0].Detalhe -like '*CONCLUÍDO*') $true 'Explica por que a linha pendente é pulada'
        Assert-Equal $r[1].Status 'SEM_CPF_PLANILHA' 'Sem CPF'
        Assert-Equal $f.State.Finds 0 'Nenhuma consulta'
        Assert-Equal $f.State.Writes 0 'Nenhuma gravação'
    }
    Test-Case 'CPF divergente no AD é preservado' {
        $f = New-Fixture; $f.State.User.CPF = '000.000.002-72'
        $r = @(Run-Sync $f @((New-Row)) -Apply)
        Assert-Equal $r[0].Status 'CPF_AD_DIVERGENTE' 'Divergência'
        Assert-Equal $f.State.User.CPF '000.000.002-72' 'Valor original'
        Assert-Equal $f.State.Writes 0 'Sem sobrescrita'
    }
    Test-Case 'Nome divergente bloqueia usuário encontrado pelo login' {
        $f = New-Fixture
        $r = @(Run-Sync $f @((New-Row -Name 'Outra Pessoa')) -Apply)
        Assert-Equal $r[0].Status 'NOME_DIVERGENTE' 'Nome diferente'
        Assert-Equal $f.State.Writes 0 'Sem gravação'
    }
    Test-Case 'Sem login exige nome único e aceita acentos equivalentes' {
        $f = New-Fixture; $f.State.Count = 2
        $r = @(Run-Sync $f @((New-Row -Login '')) -Apply)
        Assert-Equal $r[0].Status 'USUARIO_AMBIGUO' 'Homônimo'
        $f.State.Count = 1; $f.State.User.DisplayName = 'Pessóa Exemplo A'
        $r = @(Run-Sync $f @((New-Row -Login '' -Name ' PESSOA  EXEMPLO A ')) -Apply)
        Assert-Equal $r[0].Status 'ATUALIZADO' 'Nome único'
    }
    Test-Case 'Domínio indisponível, ação desativar e CPF inválido são pulados' {
        $f = New-Fixture
        $other = New-Row; $other.Dominio = 'SAÚDE.BETIM'
        $r = @(Run-Sync $f @($other, (New-Row -Login 'desativar'), (New-Row -Cpf '001')) -Apply)
        Assert-Equal $r[0].Status 'DOMINIO_NAO_LOCALIZADO' 'Domínio'
        Assert-Equal $r[1].Status 'DESATIVACAO_DESLIGADA' 'Desativar requer opção explícita'
        Assert-Equal ($r[1].Detalhe -like '*Permitir desativação*desligada*') $true 'Explica opção necessária para a ação'
        Assert-Equal $r[2].Status 'CPF_INVALIDO' 'CPF inválido'
        Assert-Equal $f.State.Finds 0 'Sem consulta para linhas inelegíveis'
    }
    Test-Case 'DOMÍNIO do CSV descobre Betim e Saúde sem servidores manuais e cacheia por domínio' {
        $f = New-Fixture; $f.State.AllowDiscovery = $true
        $f.Adapter.ValidateServer = { param($Server, $Attribute) $Server }
        $settings = '{"AtributoCpf":"CPF","FormatoCpf":"Formatado","Dominios":{"BETIM.PMB":"","SAÚDE.BETIM":""}}' | ConvertFrom-Json
        $saude = New-Row; $saude.Dominio = 'saúde.betim'
        $r = @(Run-Sync $f @((New-Row), $saude, (New-Row)) -Settings $settings)
        Assert-Equal $r[0].Servidor 'dc.betim.test' 'Betim usa controlador de Betim'
        Assert-Equal $r[1].Servidor 'dc.saude.test' 'Saúde usa controlador de Saúde'
        Assert-Equal $r[2].OrigemServidor 'Automatico' 'Origem automática'
        Assert-Equal $f.State.Discoveries.Count 2 'Uma descoberta por domínio'
        Assert-Equal $f.State.FoundServers[1] 'dc.saude.test' 'Consulta não foi desviada para Betim'
        Assert-Equal $f.State.Writes 0 'Simulação sem gravação'
    }
    Test-Case 'Falha de descoberta é cacheada e não usa domínio atual como fallback' {
        $f = New-Fixture
        $saude = New-Row; $saude.Dominio = 'SAÚDE.BETIM'
        $r = @(Run-Sync $f @($saude, $saude, (New-Row)))
        Assert-Equal $r[0].Status 'DOMINIO_NAO_LOCALIZADO' 'Falha Saúde'
        Assert-Equal $r[1].Status 'DOMINIO_NAO_LOCALIZADO' 'Falha repetida'
        Assert-Equal $r[2].Status 'SIMULADO_PREENCHER' 'Betim continua independente'
        Assert-Equal $f.State.Discoveries.Count 1 'Falha não gera descoberta para cada usuário'
        Assert-Equal $f.State.Finds 1 'Somente Betim foi consultado'
    }
    Test-Case 'Domínio vazio bloqueia descoberta e servidor manual dispensa descoberta' {
        $f = New-Fixture
        $blank = New-Row; $blank.Dominio = ''
        $r = @(Run-Sync $f @($blank, (New-Row)))
        Assert-Equal $r[0].Status 'SEM_DOMINIO' 'Sem domínio'
        Assert-Equal $r[1].OrigemServidor 'Manual' 'Servidor explícito preservado'
        Assert-Equal $f.State.Discoveries.Count 0 'Não adivinha domínio vazio nem descobre override'
    }
    Test-Case 'Cache de servidor manual não permite trocar o domínio do usuário' {
        $f = New-Fixture
        $checkedDomains = New-Object 'System.Collections.Generic.List[string]'
        $f.Adapter.ValidateServer = {
            param($Server, $Attribute, $Domain)
            $checkedDomains.Add($Domain)
            if ($Domain -ne 'BETIM.PMB') { throw 'Servidor pertence a Betim, não à Saúde.' }
            $Server
        }.GetNewClosure()
        $settings = '{"AtributoCpf":"CPF","Dominios":{"BETIM.PMB":"dc.compartilhado.test","SAÚDE.BETIM":"dc.compartilhado.test"}}' | ConvertFrom-Json
        $saude = New-Row; $saude.Dominio = 'SAÚDE.BETIM'
        $r = @(Run-Sync $f @($saude, (New-Row)) -Settings $settings)
        Assert-Equal $r[0].Status 'ERRO_CONSULTA' 'Domínio errado bloqueado'
        Assert-Equal $r[1].Status 'SIMULADO_PREENCHER' 'Falha de Saúde não afeta validação de Betim'
        Assert-Equal $checkedDomains.Count 2 'Servidor validado separadamente por domínio'
        Assert-Equal $f.State.Finds 1 'Nenhuma busca no domínio errado'
    }
    Test-Case 'Mesmo GUID e CPF repetidos planejam somente uma gravação' {
        $f = New-Fixture
        $other = New-Row; $other.Registro = 4
        $r = @(Run-Sync $f @((New-Row), $other))
        Assert-Equal $r[0].Status 'SIMULADO_PREENCHER' 'Linha principal pronta'
        Assert-Equal $r[1].Status 'LINHA_REPETIDA' 'Repetida identificada'
        Assert-Equal ($r[1].Detalhe -like '*registro 3*') $true 'Aponta para a linha principal'
        $r = @(Run-Sync $f @((New-Row), $other) -Apply)
        Assert-Equal $f.State.Writes 1 'Uma única escrita'
    }
    Test-Case 'GUIDs diferentes com o mesmo CPF permanecem independentes' {
        $f = New-Fixture
        $otherUser = $f.State.User.PSObject.Copy()
        $otherUser.ObjectGUID = [guid]::NewGuid(); $otherUser.SamAccountName = 'pessoa.b'
        $directory = @{ 'pessoa.a' = $f.State.User; 'pessoa.b' = $otherUser }
        $f.Adapter.Find = { param($Server, $Attribute, $Login, $Name) $directory[$Login].PSObject.Copy() }.GetNewClosure()
        $f.Adapter.Read = { param($Server, $Attribute, $Identity) ($directory.Values | Where-Object { $_.ObjectGUID -eq $Identity }).PSObject.Copy() }.GetNewClosure()
        $other = New-Row -Login 'pessoa.b'; $other.Registro = 4
        $r = @(Run-Sync $f @((New-Row), $other))
        Assert-Equal $r[0].Status 'SIMULADO_PREENCHER' 'Primeira conta'
        Assert-Equal $r[1].Status 'SIMULADO_PREENCHER' 'Outra conta com CPF igual não foi deduplicada'
    }
    Test-Case 'Dois CPFs para o mesmo GUID bloqueiam todas as linhas' {
        $f = New-Fixture
        $r = @(Run-Sync $f @((New-Row), (New-Row -Cpf '000.000.002-72' -Login '')) -Apply)
        Assert-Equal $r[0].Status 'CONFLITO_CSV' 'Primeira linha'
        Assert-Equal $r[1].Status 'CONFLITO_CSV' 'Segunda linha'
        Assert-Equal $f.State.Writes 0 'Nenhuma ganhou por ordem'
    }
    Test-Case 'CPF preenchido entre consulta e aplicação é preservado' {
        $f = New-Fixture; $f.State.ConcurrentCpf = '000.000.002-72'
        $r = @(Run-Sync $f @((New-Row)) -Apply)
        Assert-Equal $r[0].Status 'CPF_AD_DIVERGENTE' 'Concorrência'
        Assert-Equal $f.State.Writes 0 'Sem sobrescrita'
    }
    Test-Case 'Conflitos do mesmo GUID por controladores distintos são bloqueados' {
        $f = New-Fixture
        $f.Adapter.ValidateServer = { param($Server, $Attribute) $Server }
        $settings = '{"AtributoCpf":"CPF","FormatoCpf":"Formatado","Dominios":{"BETIM.PMB":"dc1.exemplo.test","SAÚDE.BETIM":"dc2.exemplo.test"}}' | ConvertFrom-Json
        $other = New-Row -Cpf '000.000.002-72'
        $other.Dominio = 'SAÚDE.BETIM'
        $r = @(Run-Sync $f @((New-Row), $other) -Apply -Settings $settings)
        Assert-Equal $r[0].Status 'CONFLITO_CSV' 'Primeiro controlador'
        Assert-Equal $r[1].Status 'CONFLITO_CSV' 'Segundo controlador'
        Assert-Equal $f.State.Writes 0 'Nenhuma gravação'
    }
    Test-Case 'Identidade alterada entre consulta e gravação bloqueia operação' {
        $f = New-Fixture; $f.State.Rename = $true
        $r = @(Run-Sync $f @((New-Row)) -Apply)
        Assert-Equal $r[0].Status 'IDENTIDADE_ALTERADA' 'Identidade'
        Assert-Equal $f.State.Writes 0 'Sem gravação'
    }
    Test-Case 'GUID diferente da simulação bloqueia a aplicação da interface' {
        $f = New-Fixture
        $report = Join-Path $testDir 'plano.csv'
        $r = @(Invoke-CpfSync -Rows @((New-Row)) -Config $config -Adapter $f.Adapter -ReportPath $report -Aplicar -ExpectedIdentities @{ '3' = [guid]::NewGuid().ToString() })
        Assert-Equal $r[0].Status 'IDENTIDADE_ALTERADA' 'GUID divergente'
        Assert-Equal $f.State.Writes 0 'Nenhuma gravação fora do plano'
    }
    Test-Case 'Erro de escrita e falha de confirmação não aparecem como sucesso' {
        $f = New-Fixture; $f.State.FailAdd = $true
        $r = @(Run-Sync $f @((New-Row)) -Apply)
        Assert-Equal $r[0].Status 'ERRO_PROCESSAMENTO' 'Erro'
        Assert-Equal $r[0].Detalhe 'Acesso negado.' 'Mensagem preservada'
        $f = New-Fixture; $f.State.FailReadAfterAdd = $true
        $r = @(Run-Sync $f @((New-Row)) -Apply)
        Assert-Equal $r[0].Status 'GRAVADO_SEM_CONFIRMACAO' 'Não confirmar sucesso'
    }
    Test-Case 'Formato somente números preserva zeros' {
        $f = New-Fixture
        $settings = '{"AtributoCpf":"CPF","FormatoCpf":"Numeros","Dominios":{"BETIM.PMB":"dominio.exemplo.test"}}' | ConvertFrom-Json
        $r = @(Run-Sync $f @((New-Row -Cpf ' 000.000.001-91 ')) -Apply -Settings $settings)
        Assert-Equal $r[0].Status 'ATUALIZADO' 'Aplicação'
        Assert-Equal $f.State.User.CPF '00000000191' 'Onze dígitos'
    }
    Test-Case 'Caracteres especiais são literais no filtro LDAP' {
        Assert-Equal (ConvertTo-LdapValue 'a*(b)\c') 'a\2a\28b\29\5cc' 'Escape LDAP'
    }
    Test-Case 'Validação de servidor falha sem consultar ou escrever usuário' {
        $f = New-Fixture
        $f.Adapter.ValidateServer = { throw 'CPF não é single-valued.' }
        $r = @(Run-Sync $f @((New-Row)) -Apply)
        Assert-Equal $r[0].Status 'ERRO_CONSULTA' 'Schema inválido'
        Assert-Equal $f.State.Finds 0 'Sem consulta de usuário'
        Assert-Equal $f.State.Writes 0 'Sem escrita'
    }
    Test-Case 'Adaptador nativo usa filtro literal, GUID, controlador fixo e Add sem Replace' {
        # Módulo de comandos falso: exercita o adaptador real sem importar ou acessar AD real.
        $fakeDir = Join-Path $testDir 'ActiveDirectory'
        $null = New-Item -ItemType Directory -Path $fakeDir
        $fakePath = Join-Path $fakeDir 'ActiveDirectory.psm1'
        $fakeModule = @'
function Get-ADRootDSE {
    [CmdletBinding()] param($Server)
    [pscustomobject]@{ schemaNamingContext = 'CN=Schema,DC=example,DC=test'; dnsHostName = 'dc.exemplo.test'; defaultNamingContext = $global:CpfAdTestNative.NamingContext }
}
function Get-ADDomainController {
    [CmdletBinding()] param([switch]$Discover, $DomainName, [switch]$Writable, $Service)
    $global:CpfAdTestNative.DiscoveryDomain = $DomainName
    $global:CpfAdTestNative.Writable = $Writable.IsPresent
    $global:CpfAdTestNative.Service = $Service
    $domain = $DomainName
    if ($global:CpfAdTestNative.WrongDomain) { $domain = 'outro.test' }
    [pscustomobject]@{ HostName = @('dc.' + $DomainName); Domain = $domain }
}
function Get-ADObject {
    [CmdletBinding()] param($Server, $SearchBase, $LDAPFilter, $Properties)
    [pscustomobject]@{ isSingleValued = $global:CpfAdTestNative.SingleValued }
}
function Get-ADUser {
    [CmdletBinding()] param($Server, $LDAPFilter, $Identity, $Properties)
    $global:CpfAdTestNative.Servers.Add($Server)
    if ($LDAPFilter) { $global:CpfAdTestNative.Filter = $LDAPFilter }
    if ($Identity) { $global:CpfAdTestNative.Identity = $Identity }
    $global:CpfAdTestNative.User.PSObject.Copy()
}
function Set-ADUser {
    [CmdletBinding(SupportsShouldProcess)] param($Server, $Identity, $Add)
    $global:CpfAdTestNative.Servers.Add($Server)
    $global:CpfAdTestNative.Writes++
    $global:CpfAdTestNative.Identity = $Identity
    $global:CpfAdTestNative.User.CPF = $Add['CPF']
}
Export-ModuleMember -Function Get-ADRootDSE,Get-ADObject,Get-ADUser,Set-ADUser,Get-ADDomainController
'@
        [IO.File]::WriteAllText($fakePath, $fakeModule)
        $f = New-Fixture
        $f.State.User.SamAccountName = 'pessoa*(a)'
        $global:CpfAdTestNative = @{
            User = $f.State.User; SingleValued = $true; Writes = 0; Filter = ''; Identity = $null
            Servers = (New-Object 'System.Collections.Generic.List[string]')
            DiscoveryDomain = ''; Writable = $false; Service = ''; WrongDomain = $false; NamingContext = 'DC=betim,DC=pmb'
        }
        Import-Module $fakePath -Global -Force
        try {
            $nativeAdapter = Get-AdAdapter
            $located = & $nativeAdapter.DiscoverServer 'SAÚDE.BETIM'
            Assert-Equal $located 'dc.saude.betim' 'Descoberta nativa normaliza acento e caixa'
            Assert-Equal $global:CpfAdTestNative.DiscoveryDomain 'saude.betim' 'DNS do domínio solicitado'
            Assert-Equal $global:CpfAdTestNative.Writable $true 'Exige controlador gravável'
            Assert-Equal $global:CpfAdTestNative.Service 'ADWS' 'Exige serviço dos cmdlets AD'
            $global:CpfAdTestNative.WrongDomain = $true
            $rejected = $false
            try { & $nativeAdapter.DiscoverServer 'SAÚDE.BETIM' | Out-Null } catch { $rejected = $true }
            Assert-Equal $rejected $true 'Controlador de domínio diferente é rejeitado'
            $global:CpfAdTestNative.WrongDomain = $false
            $global:CpfAdTestNative.NamingContext = 'DC=saude,DC=betim'
            $rejected = $false
            try { & $nativeAdapter.ValidateServer 'dc.errado.test' 'CPF' 'BETIM.PMB' | Out-Null } catch { $rejected = $_.Exception.Message -like '*pertence*' }
            Assert-Equal $rejected $true 'Override manual de outro domínio é rejeitado'
            $global:CpfAdTestNative.NamingContext = 'DC=betim,DC=pmb'
            $f.Adapter = $nativeAdapter
            $r = @(Run-Sync $f @((New-Row -Login 'pessoa*(a)')) -Apply)
            Assert-Equal $r[0].Status 'ATUALIZADO' 'Caminho nativo'
            Assert-Equal $global:CpfAdTestNative.Filter '(sAMAccountName=pessoa\2a\28a\29)' 'Filtro exato escapado'
            Assert-Equal $global:CpfAdTestNative.Identity $f.State.User.ObjectGUID 'Escrita por GUID'
            Assert-Equal $global:CpfAdTestNative.Writes 1 'Uma escrita'
            foreach ($server in $global:CpfAdTestNative.Servers) { Assert-Equal $server 'dc.exemplo.test' 'Controlador fixado' }
            $global:CpfAdTestNative.SingleValued = $false
            $r = @(Run-Sync $f @((New-Row -Login 'pessoa*(a)')) -Apply)
            Assert-Equal $r[0].Status 'ERRO_CONSULTA' 'Atributo multivalorado bloqueia'
            Assert-Equal $global:CpfAdTestNative.Writes 1 'Nenhuma escrita adicional'
        } finally {
            Remove-Module ActiveDirectory -Force
            Remove-Variable CpfAdTestNative -Scope Global
        }
    }
    Write-Host ("{0} testes passaram. Nenhum acesso ao AD real." -f $script:passed)
} finally {
    $resolvedTestDir = [IO.Path]::GetFullPath($testDir)
    $allowedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cpf-ad-test-'
    if ($resolvedTestDir.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestDir -Recurse -Force
    }
}
