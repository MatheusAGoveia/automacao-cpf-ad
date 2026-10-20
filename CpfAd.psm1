Set-StrictMode -Version Latest

function ConvertTo-Key([string]$Value) {
    $text = $Value.Normalize([Text.NormalizationForm]::FormD)
    $text = [regex]::Replace($text, '\p{Mn}', '')
    return ([regex]::Replace($text, '\s+', ' ').Trim().ToUpperInvariant())
}

function ConvertTo-DomainKey([string]$Value) { return ConvertTo-Key $Value }

function ConvertTo-LdapValue([string]$Value) {
    return $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
}

function Test-Cpf([string]$Value) {
    if ($Value -notmatch '^\s*(?:[0-9]{11}|[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2})\s*$') { return $false }
    $digits = $Value -replace '[^0-9]', ''
    if ($digits -match '^([0-9])\1{10}$') { return $false }
    foreach ($length in @(9, 10)) {
        $sum = 0
        for ($i = 0; $i -lt $length; $i++) { $sum += ([int]::Parse([string]$digits[$i])) * ($length + 1 - $i) }
        $digit = (11 - ($sum % 11)) % 10
        if (($sum % 11) -lt 2) { $digit = 0 }
        if ($digit -ne [int]::Parse([string]$digits[$length])) { return $false }
    }
    return $true
}

function Import-CpfCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Encoding = 'utf-8')
    $raw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [Text.Encoding]::GetEncoding($Encoding))
    $lines = @($raw -split '\r?\n')
    $required = @('NOME COMPLETO', 'DOMINIO', 'NOVO LOGIN', 'CPF', 'CONCLUIDO')
    $headerIndex = -1
    $delimiter = ','
    # O Google Sheets pode exportar uma linha de título antes do cabeçalho.
    for ($i = 0; $i -lt [Math]::Min(20, $lines.Count); $i++) {
        foreach ($candidate in @(',', ';', "`t")) {
            $cells = @($lines[$i].Split([char]$candidate) | ForEach-Object { ConvertTo-Key ($_.Trim().Trim('"').Trim([char]0xfeff)) })
            $missing = @($required | Where-Object { $_ -notin $cells })
            if ($missing.Count -eq 0) { $headerIndex = $i; $delimiter = $candidate; break }
        }
        if ($headerIndex -ge 0) { break }
    }
    if ($headerIndex -lt 0) { throw 'Cabeçalho não encontrado: NOME COMPLETO, DOMINIO, NOVO LOGIN, CPF e CONCLUÍDO. Confira o CSV e a codificação.' }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $reader = New-Object IO.StringReader(($lines[$headerIndex..($lines.Count - 1)] -join "`n"))
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($reader)
    $parsed = New-Object 'System.Collections.Generic.List[object]'
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters($delimiter)
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        $headers = @($parser.ReadFields() | ForEach-Object { ConvertTo-Key ($_.Trim().Trim([char]0xfeff)) })
        $duplicates = @($headers | Where-Object { $_ } | Group-Object | Where-Object { $_.Count -gt 1 })
        if ($duplicates.Count) { throw ('Cabeçalhos repetidos após normalização: ' + (($duplicates.Name) -join ', ') + '. Corrija o CSV antes de continuar.') }
        $recordNumber = $headerIndex + 1
        while (-not $parser.EndOfData) {
            $recordNumber++
            $fields = @($parser.ReadFields())
            if ($fields.Count -ne $headers.Count) { throw "Registro $recordNumber tem $($fields.Count) campos; o cabeçalho tem $($headers.Count). Corrija o CSV antes de continuar." }
            $values = @{}
            for ($column = 0; $column -lt $headers.Count; $column++) {
                if ($headers[$column]) { $values[$headers[$column]] = ([string]$fields[$column]).Trim() }
            }
            if (-not ($values['NOME COMPLETO'] -or $values['DOMINIO'] -or $values['NOVO LOGIN'] -or $values['CPF'])) { continue }
            $parsed.Add([pscustomobject]@{
                Registro = $recordNumber
                Nome = $values['NOME COMPLETO']
                Dominio = $values['DOMINIO']
                Login = $values['NOVO LOGIN']
                Cpf = $values['CPF']
                Concluido = $values['CONCLUIDO']
            })
        }
    } catch [Microsoft.VisualBasic.FileIO.MalformedLineException] {
        throw "CSV inválido próximo da linha $($headerIndex + $parser.ErrorLineNumber): verifique aspas e separadores. Nenhum registro foi processado."
    } finally { $parser.Dispose(); $reader.Dispose() }
    return $parsed.ToArray()
}

function Get-AdAdapter {
    Import-Module ActiveDirectory -ErrorAction Stop
    return @{
        DiscoverServer = {
            param($Domain)
            $dnsDomain = (ConvertTo-Key $Domain).ToLowerInvariant()
            if ($dnsDomain -notmatch '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
                throw "O domínio '$Domain' não é um nome DNS completo. Confira a coluna DOMÍNIO ou informe um servidor manual."
            }
            $controller = Get-ADDomainController -Discover -DomainName $dnsDomain -Writable -Service ADWS -ErrorAction Stop
            $hosts = @($controller.HostName | ForEach-Object { [string]$_ })
            $domains = @($controller.Domain | ForEach-Object { [string]$_ })
            if ($hosts.Count -ne 1 -or [string]::IsNullOrWhiteSpace($hosts[0]) -or $domains.Count -ne 1 -or (ConvertTo-Key $domains[0]) -ne (ConvertTo-Key $dnsDomain)) {
                throw "A descoberta não confirmou um controlador do domínio '$dnsDomain'. Nenhum outro domínio será utilizado."
            }
            return $hosts[0]
        }
        ValidateServer = {
            param($Server, $Attribute, $Domain)
            $root = Get-ADRootDSE -Server $Server -ErrorAction Stop
            $labels = @()
            foreach ($part in ([string]$root.defaultNamingContext -split ',')) {
                if ($part.Trim() -notmatch '^DC=([a-zA-Z0-9-]+)$') { throw "O servidor '$Server' não confirmou um domínio AD válido." }
                $labels += $Matches[1]
            }
            $actualDomain = $labels -join '.'
            if (-not $Domain -or (ConvertTo-Key $actualDomain) -ne (ConvertTo-Key $Domain)) {
                throw "O servidor '$Server' pertence a '$actualDomain', mas a linha informa '$Domain'. Nenhum usuário foi consultado neste servidor."
            }
            if ($Attribute) {
                $escaped = ConvertTo-LdapValue $Attribute
                $schema = @(Get-ADObject -Server $Server -SearchBase $root.schemaNamingContext -LDAPFilter "(lDAPDisplayName=$escaped)" -Properties isSingleValued -ErrorAction Stop)
                if ($schema.Count -ne 1 -or $schema[0].isSingleValued -ne $true) {
                    throw "O atributo '$Attribute' não existe ou não é de valor único neste servidor."
                }
            }
            # Fixar o mesmo controlador para busca, releitura, escrita e confirmação.
            return [string]$root.dnsHostName
        }
        Find = {
            param($Server, $Attribute, $Login, $Name)
            if ($Login) { $filter = '(sAMAccountName=' + (ConvertTo-LdapValue $Login) + ')' }
            else {
                $escaped = ConvertTo-LdapValue $Name
                $filter = "(|(name=$escaped)(displayName=$escaped))"
            }
            $properties = @('DisplayName', 'Enabled')
            if ($Attribute) { $properties += $Attribute }
            Get-ADUser -Server $Server -LDAPFilter $filter -Properties $properties -ErrorAction Stop
        }
        Read = {
            param($Server, $Attribute, $Identity)
            $properties = @('DisplayName', 'Enabled')
            if ($Attribute) { $properties += $Attribute }
            Get-ADUser -Server $Server -Identity $Identity -Properties $properties -ErrorAction Stop
        }
        Add = {
            param($Server, $Attribute, $Identity, $Value)
            # Add + atributo single-valued falha se outro processo preencher o campo.
            Set-ADUser -Server $Server -Identity $Identity -Add @{$Attribute = $Value} -Confirm:$false -ErrorAction Stop
        }
        Disable = {
            param($Server, $Identity)
            Disable-ADAccount -Server $Server -Identity $Identity -Confirm:$false -ErrorAction Stop
        }
    }
}

function Test-UserName($User, [string]$Name) {
    $expected = ConvertTo-Key $Name
    return ($expected -eq (ConvertTo-Key ([string]$User.Name)) -or $expected -eq (ConvertTo-Key ([string]$User.DisplayName)))
}

function Save-CpfReport($Results, [string]$Path) {
    $Results | Select-Object Registro, Nome, Dominio, Login, Acao, ConcluidoPlanilha, LoginEncontrado, ContaAtivaAnterior, ContaAtivaAtual, Servidor, OrigemServidor, ObjectGuid, CpfPlanilha, CpfAnterior, Status, Detalhe |
        Export-Csv -LiteralPath $Path -Delimiter ';' -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
}

function Invoke-CpfSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][hashtable]$Adapter,
        [Parameter(Mandatory)][string]$ReportPath,
        [switch]$Aplicar,
        [hashtable]$ExpectedIdentities,
        [hashtable]$ExpectedLogins
    )
    $attribute = [string]$Config.AtributoCpf
    if ($attribute -notmatch '^[a-zA-Z][a-zA-Z0-9-]*$') { throw 'AtributoCpf inválido na configuração.' }
    $allowDisable = $false
    if ($Config.PSObject.Properties.Name -contains 'DesativarUsuarios') {
        if ($Config.DesativarUsuarios -isnot [bool]) { throw 'DesativarUsuarios deve ser true ou false na configuração.' }
        $allowDisable = $Config.DesativarUsuarios
    }
    $domainMap = @{}
    foreach ($property in $Config.Dominios.PSObject.Properties) { $domainMap[(ConvertTo-Key $property.Name)] = ([string]$property.Value).Trim() }
    $servers = @{}
    $serverErrors = @{}
    $discovered = @{}
    $discoveryErrors = @{}
    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $Rows) {
        $result = [pscustomobject]@{
            Registro = $row.Registro; Nome = $row.Nome; Dominio = $row.Dominio; Login = $row.Login
            Acao = 'PREENCHER_CPF'; ConcluidoPlanilha = $row.Concluido; LoginEncontrado = ''; ContaAtivaAnterior = ''; ContaAtivaAtual = ''
            Servidor = ''; OrigemServidor = ''; ObjectGuid = ''; CpfPlanilha = $row.Cpf; CpfAnterior = ''
            Status = ''; Detalhe = ''; Digits = ''; Target = ''
        }
        $results.Add($result)
        $isDisable = (ConvertTo-Key $row.Login) -eq 'DESATIVAR'
        $queryAttribute = $attribute
        $queryLogin = $row.Login
        if ($isDisable) {
            $result.Acao = 'DESATIVAR'
            if (-not $allowDisable) {
                $result.Status = 'DESATIVACAO_DESLIGADA'
                $result.Detalhe = 'NOVO LOGIN contém desativar, mas a opção Permitir desativação está desligada. Ative a opção e simule novamente para incluir esta linha.'
                continue
            }
            # A palavra é uma ação, não um login. Busca somente por nome no domínio indicado.
            $queryAttribute = ''
            $queryLogin = ''
        } elseif ((ConvertTo-Key $row.Concluido) -notin @('TRUE', 'VERDADEIRO', '1', 'SIM', 'X')) {
            $result.Status = 'NAO_CONCLUIDO'
            $result.Detalhe = 'A coluna CONCLUÍDO está desmarcada ou não contém um valor de conclusão reconhecido no CSV. Esta linha é pulada.'
            continue
        }
        if (-not $isDisable) {
            if ([string]::IsNullOrWhiteSpace($row.Cpf)) { $result.Status = 'SEM_CPF_PLANILHA'; continue }
            if (-not (Test-Cpf $row.Cpf)) { $result.Status = 'CPF_INVALIDO'; continue }
            $result.Digits = $row.Cpf -replace '[^0-9]', ''
        }
        if ([string]::IsNullOrWhiteSpace($row.Nome)) { $result.Status = 'SEM_NOME'; continue }
        if ((ConvertTo-Key $row.Login) -in @('EXCLUIR', 'REMOVER')) {
            $result.Status = 'ACAO_NAO_SUPORTADA'
            $result.Detalhe = "NOVO LOGIN contém '$($row.Login)' em vez de um login. Exclusão e remoção de contas não são suportadas. A linha é pulada."
            continue
        }
        $domain = ConvertTo-Key $row.Dominio
        if (-not $domain) { $result.Status = 'SEM_DOMINIO'; $result.Detalhe = 'A coluna DOMÍNIO está vazia. Informe o domínio do usuário no CSV.'; continue }
        $configuredServer = ''
        if ($domainMap.ContainsKey($domain)) { $configuredServer = $domainMap[$domain] }
        if ($configuredServer) { $result.OrigemServidor = 'Manual' }
        else {
            $result.OrigemServidor = 'Automatico'
            try {
                if ($discoveryErrors.ContainsKey($domain)) { throw $discoveryErrors[$domain] }
                if (-not $discovered.ContainsKey($domain)) {
                    if (-not $Adapter.ContainsKey('DiscoverServer')) { throw 'O adaptador não oferece descoberta automática de domínios.' }
                    $located = & $Adapter.DiscoverServer $domain
                    if ([string]::IsNullOrWhiteSpace($located)) { throw 'Nenhum controlador foi localizado para este domínio.' }
                    $discovered[$domain] = [string]$located
                }
                $configuredServer = $discovered[$domain]
            } catch {
                $discoveryErrors[$domain] = $_.Exception.Message
                $result.Status = 'DOMINIO_NAO_LOCALIZADO'; $result.Detalhe = $_.Exception.Message
                continue
            }
        }
        try {
            $result.Servidor = $configuredServer
            $serverKey = $domain + '|' + $configuredServer + '|' + $queryAttribute
            if ($serverErrors.ContainsKey($serverKey)) { throw $serverErrors[$serverKey] }
            if (-not $servers.ContainsKey($serverKey)) {
                try {
                    $fixedServer = & $Adapter.ValidateServer $configuredServer $queryAttribute $domain
                    if ([string]::IsNullOrWhiteSpace($fixedServer)) { throw 'Servidor não retornou o nome do controlador de domínio.' }
                    $servers[$serverKey] = [string]$fixedServer
                } catch {
                    $serverErrors[$serverKey] = $_.Exception.Message
                    throw
                }
            }
            $result.Servidor = $servers[$serverKey]
            $users = @(& $Adapter.Find $result.Servidor $queryAttribute $queryLogin $row.Nome)
            if ($users.Count -eq 0) { $result.Status = 'USUARIO_NAO_ENCONTRADO'; continue }
            if ($users.Count -ne 1) { $result.Status = 'USUARIO_AMBIGUO'; $result.Detalhe = 'Mais de um usuário corresponde à busca neste domínio. Nenhuma conta foi selecionada.'; continue }
            $user = $users[0]
            if (-not (Test-UserName $user $row.Nome)) { $result.Status = 'NOME_DIVERGENTE'; continue }
            if ($queryLogin -and $queryLogin -ine [string]$user.SamAccountName) { $result.Status = 'LOGIN_DIVERGENTE'; continue }
            $result.LoginEncontrado = [string]$user.SamAccountName
            if ([string]::IsNullOrWhiteSpace($result.LoginEncontrado)) { throw 'O AD não retornou o login da conta encontrada.' }
            $result.ObjectGuid = ([guid]$user.ObjectGUID).ToString()
            if ($null -ne $ExpectedIdentities) {
                $recordKey = [string]$row.Registro
                if (-not $ExpectedIdentities.ContainsKey($recordKey) -or $result.ObjectGuid -ine [string]$ExpectedIdentities[$recordKey]) {
                    $result.Status = 'IDENTIDADE_ALTERADA'
                    $result.Detalhe = 'O objeto do AD não corresponde ao usuário aprovado na simulação.'
                    continue
                }
            }
            if ($null -ne $ExpectedLogins) {
                $recordKey = [string]$row.Registro
                if (-not $ExpectedLogins.ContainsKey($recordKey) -or $result.LoginEncontrado -ine [string]$ExpectedLogins[$recordKey]) {
                    $result.Status = 'IDENTIDADE_ALTERADA'
                    $result.Detalhe = 'O login da conta mudou em relação à simulação. Simule novamente.'
                    continue
                }
            }
            $result.Target = $result.ObjectGuid
            if (-not $isDisable) { $result.CpfAnterior = [string]$user.$attribute }
            $result.Status = 'PLANEJADO'
        } catch {
            $result.Status = 'ERRO_CONSULTA'; $result.Detalhe = $_.Exception.Message
        }
    }

    # Resolver todos os objetos primeiro: ações e CPFs conflitantes não dependem da ordem do CSV.
    foreach ($group in @($results | Where-Object { $_.Target } | Group-Object Target)) {
        $actions = @($group.Group.Acao | Select-Object -Unique)
        $cpfs = @($group.Group.Digits | Select-Object -Unique)
        if ($actions.Count -gt 1) {
            foreach ($item in $group.Group) { $item.Status = 'CONFLITO_ACOES'; $item.Detalhe = 'O CSV solicita preencher CPF e desativar a mesma conta. Separe as ações e simule novamente. Nenhuma delas será aplicada.' }
        } elseif ($cpfs.Count -gt 1) {
            foreach ($item in $group.Group) { $item.Status = 'CONFLITO_CSV'; $item.Detalhe = 'CPFs diferentes para o mesmo usuário. Nenhuma linha deste grupo será aplicada.' }
        } elseif ($group.Count -gt 1) {
            $primary = $group.Group[0]
            foreach ($item in @($group.Group | Select-Object -Skip 1)) {
                $item.Status = 'LINHA_REPETIDA'
                $item.Detalhe = "Mesmo usuário e ação do registro $($primary.Registro). O processamento ocorre somente pela linha principal."
            }
        }
    }
    Save-CpfReport $results $ReportPath
    foreach ($result in $results) {
        if ($result.Status -ne 'PLANEJADO') { continue }
        try {
            $isDisable = $result.Acao -eq 'DESATIVAR'
            $queryAttribute = $attribute
            if ($isDisable) { $queryAttribute = '' }
            # Revalidar identidade e estado da conta/CPF no controlador fixado antes da escrita.
            $current = & $Adapter.Read $result.Servidor $queryAttribute ([guid]$result.ObjectGuid)
            if (([guid]$current.ObjectGUID).ToString() -ine $result.ObjectGuid -or -not (Test-UserName $current $result.Nome) -or $result.LoginEncontrado -ine [string]$current.SamAccountName) {
                $result.Status = 'IDENTIDADE_ALTERADA'; continue
            }
            if ($isDisable) {
                if ($current.PSObject.Properties.Name -notcontains 'Enabled' -or $current.Enabled -isnot [bool]) { throw 'O AD não confirmou se a conta está ativa. Nenhuma desativação foi enviada.' }
                $result.ContaAtivaAnterior = $current.Enabled
                $result.ContaAtivaAtual = $current.Enabled
                if (-not $current.Enabled) { $result.Status = 'JA_DESATIVADO'; $result.Detalhe = 'A conta já está desativada no domínio indicado. Nenhuma alteração necessária.'; continue }
                if (-not $Aplicar) { $result.Status = 'SIMULADO_DESATIVAR'; $result.Detalhe = 'Conta ativa. Será desativada somente no domínio indicado, independentemente de CONCLUÍDO e CPF.'; continue }
                if (-not $Adapter.ContainsKey('Disable')) { throw 'O adaptador não oferece desativação de contas.' }
                $result.Status = 'DESATIVACAO_INICIADA'
                Save-CpfReport $results $ReportPath
                & $Adapter.Disable $result.Servidor ([guid]$result.ObjectGuid) | Out-Null
                $result.Status = 'DESATIVADO_SEM_CONFIRMACAO'
                $result.ContaAtivaAtual = ''
                $after = & $Adapter.Read $result.Servidor '' ([guid]$result.ObjectGuid)
                if (([guid]$after.ObjectGUID).ToString() -ine $result.ObjectGuid -or $after.PSObject.Properties.Name -notcontains 'Enabled' -or $after.Enabled -isnot [bool] -or $after.Enabled) { throw 'Desativação enviada, mas a leitura posterior não confirmou a conta desativada. Revise o usuário.' }
                $result.ContaAtivaAtual = $false
                $result.Status = 'DESATIVADO'
                $result.Detalhe = 'Conta desativada e estado confirmado no domínio indicado.'
                continue
            }
            $result.CpfAnterior = [string]$current.$attribute
            if (-not [string]::IsNullOrEmpty($result.CpfAnterior)) {
                if ($result.CpfAnterior -match '^\s*(?:[0-9]{11}|[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2})\s*$' -and ($result.CpfAnterior -replace '[^0-9]', '') -eq $result.Digits) {
                    $result.Status = 'CPF_JA_CONFERE'
                } else { $result.Status = 'CPF_AD_DIVERGENTE' }
                continue
            }
            if (-not $Aplicar) { $result.Status = 'SIMULADO_PREENCHER'; continue }
            $newValue = $result.Digits
            $result.Status = 'GRAVACAO_INICIADA'
            Save-CpfReport $results $ReportPath
            & $Adapter.Add $result.Servidor $attribute ([guid]$result.ObjectGuid) $newValue | Out-Null
            $result.Status = 'GRAVADO_SEM_CONFIRMACAO'
            $after = & $Adapter.Read $result.Servidor $attribute ([guid]$result.ObjectGuid)
            if ([string]$after.$attribute -ne $newValue) { throw 'Gravação enviada, mas a leitura posterior não confirmou o valor esperado. Revise o usuário.' }
            $result.Status = 'ATUALIZADO'
        } catch {
            if ($result.Status -notin @('GRAVADO_SEM_CONFIRMACAO', 'DESATIVADO_SEM_CONFIRMACAO')) { $result.Status = 'ERRO_PROCESSAMENTO' }
            $result.Detalhe = $_.Exception.Message
        } finally {
            # Falha ao salvar o relatório interrompe novas gravações.
            Save-CpfReport $results $ReportPath
        }
    }
    return $results.ToArray() | Select-Object Registro, Nome, Dominio, Login, Acao, ConcluidoPlanilha, LoginEncontrado, ContaAtivaAnterior, ContaAtivaAtual, Servidor, OrigemServidor, ObjectGuid, CpfPlanilha, CpfAnterior, Status, Detalhe
}

Export-ModuleMember -Function Import-CpfCsv, Invoke-CpfSync, Get-AdAdapter, Test-Cpf, ConvertTo-LdapValue, ConvertTo-DomainKey
