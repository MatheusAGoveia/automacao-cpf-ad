#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'CpfAd.psm1') -Force
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ad-login-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$script:passed = 0
function Assert-Login($Actual, $Expected, [string]$Message) {
    if ([string]$Actual -cne [string]$Expected) { throw "$Message — esperado '$Expected', recebido '$Actual'." }
}
function Login-Case([string]$Name, [scriptblock]$Body) { & $Body; $script:passed++; Write-Host "OK: $Name" }
function New-LoginRow([string]$Login = 'pessoa.nova', [string]$Name = 'Pessoa Exemplo', [string]$Domain = 'BETIM.PMB') {
    [pscustomobject]@{ Registro = 3; Nome = $Name; Dominio = $Domain; Login = $Login; Cpf = 'invalido'; Concluido = 'FALSE' }
}
function New-LoginFixture {
    $state = @{
        Users = @(
            [pscustomobject]@{ Domain = 'BETIM.PMB'; Name = 'Pessoa Exemplo'; DisplayName = 'Pessoa Exemplo'; SamAccountName = 'pessoa.nova'; ObjectGUID = [guid]::NewGuid() },
            [pscustomobject]@{ Domain = 'SAUDE.BETIM'; Name = 'Pessoa Exemplo'; DisplayName = 'Pessoa Exemplo'; SamAccountName = 'pessoa.antiga'; ObjectGUID = [guid]::NewGuid() }
        )
        Finds = New-Object 'System.Collections.Generic.List[string]'
        Validations = 0; Discoveries = 0; Writes = 0; FailDiscover = $false; FailFind = $false; WrongServer = $false
    }
    $adapter = @{
        DiscoverServer = { param($Domain) $state.Discoveries++; if ($state.FailDiscover) { throw 'Domínio indisponível.' }; 'dc.' + $Domain.ToLowerInvariant() }.GetNewClosure()
        ValidateServer = {
            param($Server,$Attribute,$Domain)
            $state.Validations++
            if ($Attribute) { throw 'Consulta de login não deve exigir atributo CPF.' }
            if ($state.WrongServer -or ($Server -replace '^dc\.', '') -ine $Domain) { throw 'Servidor pertence a outro domínio.' }
            $Server
        }.GetNewClosure()
        Find = {
            param($Server,$Attribute,$Login,$Name)
            if ($Attribute) { throw 'Consulta de login não deve ler CPF.' }
            $state.Finds.Add($Server)
            if ($state.FailFind) { throw 'Falha na consulta.' }
            foreach ($user in $state.Users) {
                if ($user.Domain -ine ($Server -replace '^dc\.', '')) { continue }
                if (($Login -and $user.SamAccountName -ieq $Login) -or (-not $Login -and ((ConvertTo-DomainKey $user.Name) -eq (ConvertTo-DomainKey $Name)))) { $user.PSObject.Copy() }
            }
        }.GetNewClosure()
        Add = { $state.Writes++; throw 'Escrita proibida.' }.GetNewClosure()
        Disable = { $state.Writes++; throw 'Desativação proibida.' }.GetNewClosure()
    }
    [pscustomobject]@{ State = $state; Adapter = $adapter }
}
function Run-LoginCheck($Fixture, [object[]]$Rows, $Config = ('{"AtributoCpf":"atributo invalido","DesativarUsuarios":true,"Dominios":{"BETIM.PMB":"","SAÚDE.BETIM":""}}' | ConvertFrom-Json)) {
    $report = Join-Path $temp ([guid]::NewGuid().ToString('N') + '.csv')
    $result = @(Invoke-AdLoginCheck -Rows $Rows -Config $Config -Adapter $Fixture.Adapter -ReportPath $report)
    Assert-Login $Fixture.State.Writes 0 'Nenhuma escrita'
    Assert-Login @(Import-Csv -LiteralPath $report -Delimiter ';' -Encoding UTF8).Count $Rows.Count 'Relatório completo'
    $result
}
try {
    Login-Case 'Login já alterado é confirmado mesmo com CPF inválido e CONCLUÍDO desmarcado' {
        $f = New-LoginFixture
        $r = Run-LoginCheck $f @((New-LoginRow))
        Assert-Login $r[0].Status 'JA_COM_NOVO_LOGIN' 'Situação'
        Assert-Login $r[0].LoginEncontrado 'pessoa.nova' 'Login atual'
        Assert-Login $r[0].Acao 'VERIFICAR_LOGIN' 'Consulta explícita'
        Assert-Login $r[0].CpfPlanilha '' 'Relatório de logins não copia CPF'
    }
    Login-Case 'Nome único com login antigo fica pendente somente no domínio da linha' {
        $f = New-LoginFixture
        $r = Run-LoginCheck $f @((New-LoginRow -Domain 'SAÚDE.BETIM'))
        Assert-Login $r[0].Status 'NOVO_LOGIN_PENDENTE' 'Situação'
        Assert-Login $r[0].LoginEncontrado 'pessoa.antiga' 'Login antigo'
        Assert-Login @($f.State.Finds | Select-Object -Unique)[0] 'dc.saude.betim' 'Domínio consultado'
        Assert-Login @($f.State.Finds | Select-Object -Unique).Count 1 'Não procura no outro AD'
    }
    Login-Case 'Busca e comparação aceitam caixa e acentos equivalentes' {
        $f = New-LoginFixture
        $r = Run-LoginCheck $f @((New-LoginRow -Login 'PESSOA.NOVA' -Name ' Pessóa  Exemplo '))
        Assert-Login $r[0].Status 'JA_COM_NOVO_LOGIN' 'Normalização'
    }
    Login-Case 'CPF ausente também não impede verificar login' {
        $f = New-LoginFixture; $row = New-LoginRow; $row.Cpf = ''
        $r = Run-LoginCheck $f @($row)
        Assert-Login $r[0].Status 'JA_COM_NOVO_LOGIN' 'Sem CPF'
    }
    Login-Case 'Nome ambíguo não é classificado como alteração pendente' {
        $f = New-LoginFixture
        $extra = $f.State.Users[1].PSObject.Copy(); $extra.ObjectGUID = [guid]::NewGuid(); $extra.SamAccountName = 'outra.conta'
        $f.State.Users += $extra
        $r = Run-LoginCheck $f @((New-LoginRow -Domain 'SAÚDE.BETIM'))
        Assert-Login $r[0].Status 'USUARIO_AMBIGUO' 'Homônimos'
    }
    Login-Case 'Login esperado em outra pessoa exige revisão de identidade' {
        $f = New-LoginFixture; $f.State.Users[0].Name = 'Outra Pessoa'; $f.State.Users[0].DisplayName = 'Outra Pessoa'
        $r = Run-LoginCheck $f @((New-LoginRow))
        Assert-Login $r[0].Status 'NOME_DIVERGENTE' 'Colisão de login'
    }
    Login-Case 'Usuário não localizado não é presumido pendente' {
        $f = New-LoginFixture
        $r = Run-LoginCheck $f @((New-LoginRow -Login 'inexistente' -Name 'Pessoa Inexistente'))
        Assert-Login $r[0].Status 'USUARIO_NAO_ENCONTRADO' 'Não localizado'
    }
    Login-Case 'Login vazio e ações são informados sem consultar nem executar AD' {
        $f = New-LoginFixture
        $r = Run-LoginCheck $f @((New-LoginRow -Login ''),(New-LoginRow -Login ' desativar '),(New-LoginRow -Login 'EXCLUIR'),(New-LoginRow -Login 'remover'))
        Assert-Login $r[0].Status 'SEM_NOVO_LOGIN' 'Sem destino'
        Assert-Login @($r | Where-Object { $_.Status -eq 'ACAO_NA_PLANILHA' }).Count 3 'Ações separadas'
        Assert-Login $f.State.Discoveries 0 'Nenhuma descoberta'
        Assert-Login $f.State.Finds.Count 0 'Nenhuma busca'
    }
    Login-Case 'Nome e domínio ausentes impedem confirmação' {
        $f = New-LoginFixture
        $r = Run-LoginCheck $f @((New-LoginRow -Name ''),(New-LoginRow -Domain ''))
        Assert-Login $r[0].Status 'SEM_NOME' 'Nome obrigatório'
        Assert-Login $r[1].Status 'SEM_DOMINIO' 'Domínio obrigatório'
        Assert-Login $f.State.Finds.Count 0 'Nenhuma busca'
    }
    Login-Case 'Falha de domínio é cacheada e não usa outro domínio como alternativa' {
        $f = New-LoginFixture; $f.State.FailDiscover = $true
        $r = Run-LoginCheck $f @((New-LoginRow),(New-LoginRow))
        Assert-Login @($r | Where-Object { $_.Status -eq 'ERRO_CONSULTA' }).Count 2 'Erros explícitos'
        Assert-Login $f.State.Discoveries 1 'Falha cacheada'
        Assert-Login $f.State.Finds.Count 0 'Sem fallback'
    }
    Login-Case 'Controlador manual de outro domínio é rejeitado antes de consultar contas' {
        $f = New-LoginFixture
        $config = '{"Dominios":{"BETIM.PMB":"dc.saude.betim"}}' | ConvertFrom-Json
        $r = Run-LoginCheck $f @((New-LoginRow)) -Config $config
        Assert-Login $r[0].Status 'ERRO_CONSULTA' 'Domínio incompatível'
        Assert-Login $f.State.Finds.Count 0 'Sem consulta em destino errado'
    }
    Login-Case 'Falha de leitura é erro e não login pendente' {
        $f = New-LoginFixture; $f.State.FailFind = $true
        $r = Run-LoginCheck $f @((New-LoginRow))
        Assert-Login $r[0].Status 'ERRO_CONSULTA' 'Erro de consulta'
        Assert-Login ($r[0].Detalhe -like '*Falha na consulta*') $true 'Causa preservada'
    }
    Login-Case 'Consultas repetidas reutilizam controlador validado sem perder linhas' {
        $f = New-LoginFixture
        $r = Run-LoginCheck $f @((New-LoginRow),(New-LoginRow))
        Assert-Login $r.Count 2 'Duas linhas'
        Assert-Login $f.State.Discoveries 1 'Uma descoberta'
        Assert-Login $f.State.Validations 1 'Uma validação'
    }
    Login-Case 'Worker rejeita combinação VerificarLogins e Aplicar antes de acessar AD' {
        $csv = Join-Path $temp 'usuarios.csv'
        [IO.File]::WriteAllText($csv,"NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO`r`nPessoa Exemplo,BETIM.PMB,pessoa.nova,,FALSE",(New-Object Text.UTF8Encoding($true)))
        $rejected = $false
        try { & (Join-Path $root 'Executar-CpfAD.ps1') -Csv $csv -ConfigJson '{"Dominios":{}}' -ReportPath (Join-Path $temp 'bloqueado.csv') -VerificarLogins $true -Aplicar $true | Out-Null }
        catch { $rejected = $_.Exception.Message -like '*somente consulta*' }
        Assert-Login $rejected $true 'Escrita rejeitada'
    }
    Write-Host "$script:passed cenários de logins passaram. Nenhum AD real acessado."
} finally {
    $target = [IO.Path]::GetFullPath($temp)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ad-login-test-'
    if ($target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $target -Recurse -Force }
}
