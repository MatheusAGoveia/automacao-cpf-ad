#requires -Version 5.1
[CmdletBinding()]
param([switch]$NaoExibir)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot 'CpfAd.psm1') -Force

$script:Ui = @{}
$script:State = @{
    Busy = $false; Csv = ''; Rows = @(); Results = @(); Fingerprint = ''; Report = ''; Job = $null; LastError = ''
    ReportFolder = (Join-Path $PSScriptRoot 'relatorios')
    WorkerPath = (Join-Path $PSScriptRoot 'Executar-CpfAD.ps1')
    ConfigPath = (Join-Path $PSScriptRoot 'dominios.json')
    ResultView = $null; FilterUpdating = $false; FilterSearch = ''; FilterDomain = ''; FilterStatus = 'Todos'; SortDirection = 'Ascending'
    ResultsStale = $false; SourceStamp = ''; LastInputCheckUtc = [DateTime]::MinValue; Preview = $true; Mode = 'Sincronizacao'
}
$script:StatusLabels = @{
    AGUARDANDO = 'Aguardando simulação'; SIMULADO_PREENCHER = 'Pronto para preencher'; ATUALIZADO = 'CPF atualizado'
    CPF_JA_CONFERE = 'CPF já confere'; CPF_AD_DIVERGENTE = 'CPF diferente no AD'; NAO_CONCLUIDO = 'Pendente na planilha'
    SEM_CPF_PLANILHA = 'Sem CPF na planilha'; CPF_INVALIDO = 'CPF inválido'; SEM_NOME = 'Sem nome completo'
    DOMINIO_NAO_LOCALIZADO = 'Domínio não localizado'; SEM_DOMINIO = 'Sem domínio no CSV'; USUARIO_NAO_ENCONTRADO = 'Usuário não encontrado'
    USUARIO_AMBIGUO = 'Mais de um usuário'; NOME_DIVERGENTE = 'Nome não confere'; LOGIN_DIVERGENTE = 'Login não confere'
    IDENTIDADE_ALTERADA = 'Cadastro alterado'; CONFLITO_CSV = 'CPFs em conflito'; ACAO_NAO_SUPORTADA = 'Login contém uma ação'
    LINHA_REPETIDA = 'Linha repetida no CSV'
    ERRO_CONSULTA = 'Erro ao consultar AD'; ERRO_PROCESSAMENTO = 'Erro ao processar'; GRAVADO_SEM_CONFIRMACAO = 'Verificar gravação'
    GRAVACAO_INICIADA = 'Gravação iniciada'; PLANEJADO = 'Aguardando processamento'
    SIMULADO_DESATIVAR = 'Pronto para desativar'; DESATIVADO = 'Conta desativada'; JA_DESATIVADO = 'Conta já desativada'
    DESATIVACAO_DESLIGADA = 'Desativação não habilitada'; DESATIVACAO_INICIADA = 'Desativação iniciada'
    DESATIVADO_SEM_CONFIRMACAO = 'Verificar desativação'; CONFLITO_ACOES = 'Ações em conflito'
    JA_COM_NOVO_LOGIN = 'Já com novo login'; NOVO_LOGIN_PENDENTE = 'Novo login pendente'
    SEM_NOVO_LOGIN = 'Sem novo login informado'; ACAO_NA_PLANILHA = 'Ação indicada na planilha'
    CONSULTA_DESATUALIZADA = 'Verifique novamente'
}
$script:Ignored = @('NAO_CONCLUIDO', 'SEM_CPF_PLANILHA', 'ACAO_NAO_SUPORTADA', 'LINHA_REPETIDA', 'AGUARDANDO', 'DESATIVACAO_DESLIGADA', 'SEM_NOVO_LOGIN', 'ACAO_NA_PLANILHA')
$script:Ready = @('SIMULADO_PREENCHER', 'SIMULADO_DESATIVAR')
$script:Confirmed = @('ATUALIZADO', 'CPF_JA_CONFERE', 'DESATIVADO', 'JA_DESATIVADO', 'JA_COM_NOVO_LOGIN')

function Update-UiButtons {
    $idle = -not $script:State.Busy
    foreach ($name in @('BrowseButton', 'SaveConfigButton', 'EncodingBox', 'AttributeBox', 'DomainsGrid', 'DisableUsersBox')) { $script:Ui[$name].IsEnabled = $idle }
    $script:Ui.SimulateButton.IsEnabled = $idle -and [bool]$script:State.Csv
    $script:Ui.VerifyLoginsButton.IsEnabled = $idle -and [bool]$script:State.Csv
    $pending = @($script:State.Results | Where-Object { $_.Status -in $script:Ready }).Count
    $cpfCount = @($script:State.Results | Where-Object { $_.Status -eq 'SIMULADO_PREENCHER' }).Count
    $disableCount = @($script:State.Results | Where-Object { $_.Status -eq 'SIMULADO_DESATIVAR' }).Count
    if ($script:State.ResultsStale) { $pending = 0 }
    $script:Ui.ApplyButton.Content = "Aplicar todos ($pending)"
    $script:Ui.ApplyButton.ToolTip = "Aplicar todas as ações da simulação: $cpfCount CPF(s) e $disableCount desativação(ões). Os filtros alteram somente a visualização."
    $script:Ui.PendingCount.ToolTip = "$cpfCount CPF(s) para preencher e $disableCount conta(s) para desativar."
    if ($script:State.ResultsStale) {
        $script:Ui.ApplyButton.ToolTip = 'Faça uma nova simulação antes de aplicar.'
        $script:Ui.PendingCount.ToolTip = 'Resultados desatualizados. Faça uma nova simulação.'
    }
    if ($script:State.Mode -eq 'Logins') {
        $script:Ui.ApplyButton.ToolTip = 'Verificação de logins é somente consulta. Use Simular no AD para preparar ações de CPF/desativação.'
        $script:Ui.PendingCount.ToolTip = 'Contas identificadas pelo nome que ainda usam outro login.'
    }
    $script:Ui.ApplyButton.IsEnabled = $idle -and $script:State.Mode -ne 'Logins' -and [bool]$script:State.Fingerprint -and $pending -gt 0
    $script:Ui.OpenReportButton.IsEnabled = $idle -and [bool]$script:State.Report -and (Test-Path -LiteralPath $script:State.Report)
    if ($idle) { $script:Ui.BusyBar.Visibility = 'Collapsed' } else { $script:Ui.BusyBar.Visibility = 'Visible' }
}

function Set-UiResultsStale([string]$Message) {
    if ($script:State.Results.Count -eq 0) { return }
    $script:State.ResultsStale = $true
    $script:Ui.StaleResultsText.Text = $Message
    $script:Ui.StaleResultsBanner.Visibility = 'Visible'
    $script:Ui.PendingCount.Text = '—'; $script:Ui.OkCount.Text = '—'; $script:Ui.ReviewCount.Text = '—'
    if ($null -ne $script:State.ResultView) {
        foreach ($item in $script:State.ResultView.SourceCollection) {
            if ($item.Status -in $script:Ready) {
                $item.Status = 'SIMULACAO_DESATUALIZADA'; $item.Situacao = 'Simule novamente'; $item.Revisar = $true
            } elseif ($script:State.Mode -eq 'Logins' -and $item.Status -in @('JA_COM_NOVO_LOGIN','NOVO_LOGIN_PENDENTE')) {
                $item.Status = 'CONSULTA_DESATUALIZADA'; $item.Situacao = 'Verifique novamente'; $item.Revisar = $true
            }
        }
        Update-UiView
    }
}

function Reset-UiSimulation([string]$Message = 'Entrada alterada. Execute uma nova simulação antes de aplicar.') {
    $script:State.Fingerprint = ''
    Set-UiResultsStale $Message
    if ($script:State.Csv -and -not $script:State.Busy) { $script:Ui.StatusText.Text = $Message }
    Update-UiButtons
}

function Test-UiSourceChanged([switch]$Force) {
    if ($script:State.Busy -or -not $script:State.Fingerprint -or -not $script:State.Csv) { return }
    if (-not $Force -and ([DateTime]::UtcNow - $script:State.LastInputCheckUtc).TotalSeconds -lt 1) { return }
    $script:State.LastInputCheckUtc = [DateTime]::UtcNow
    try {
        $file = Get-Item -LiteralPath $script:State.Csv -ErrorAction Stop
        $stamp = '{0}:{1}' -f $file.LastWriteTimeUtc.Ticks, $file.Length
        if (-not $Force -and $stamp -eq $script:State.SourceStamp) { return }
        $current = Get-UiFingerprint ([IO.File]::ReadAllBytes($script:State.Csv)) (Get-UiConfigJson -ForLogins:($script:State.Mode -eq 'Logins')) ([string]$script:Ui.EncodingBox.SelectedItem.Tag)
        $script:State.SourceStamp = $stamp
        if ($current -cne $script:State.Fingerprint) { Reset-UiSimulation 'O CSV foi alterado fora do sistema. Os resultados anteriores ficaram desatualizados; simule novamente.' }
    } catch {
        Reset-UiSimulation 'O CSV não está acessível. Selecione o arquivo novamente e faça uma nova simulação.'
    }
}

function Show-UiError([string]$Message) {
    $script:State.LastError = $Message
    $script:Ui.StatusText.Text = $Message
    $script:Ui.DetailsText.Text = $Message
    $script:Ui.DetailsText.ToolTip = $Message
}

function Get-UiErrorMessage($ErrorRecord) {
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
    return [string]$exception.Message
}

function Get-UiConfigJson([switch]$ForLogins) {
    $null = $script:Ui.DomainsGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell, $true)
    $null = $script:Ui.DomainsGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row, $true)
    $attribute = $script:Ui.AttributeBox.Text.Trim()
    if (-not $ForLogins -and $attribute -notmatch '^[a-zA-Z][a-zA-Z0-9-]*$') { throw 'Informe um nome válido para o atributo CPF.' }
    $domains = [ordered]@{}
    foreach ($item in $script:Domains) { $domains[$item.Dominio] = $item.Servidor.Trim() }
    return ([ordered]@{ AtributoCpf = $attribute; FormatoCpf = 'Numeros'; Dominios = $domains; DesativarUsuarios = [bool]$script:Ui.DisableUsersBox.IsChecked } | ConvertTo-Json -Depth 5 -Compress)
}

function Update-UiLayout([double]$Height = 0) {
    if ($Height -le 0) { $Height = $script:Window.ActualHeight }
    if ($Height -le 0) { $Height = $script:Window.Height }
    # Painéis superiores têm rolagem própria; a tabela conserva sua área útil.
    $script:Ui.SetupScroll.MaxHeight = [Math]::Max(70, [Math]::Min(340, $Height - 480))
    $script:Ui.SummaryCards.Visibility = 'Visible'
    if ($Height -lt 730) { $script:Ui.SummaryCards.Visibility = 'Collapsed' }
}

function Test-UiRowVisible($Item) {
    if ($script:State.FilterDomain -and $Item.DomainKey -ne $script:State.FilterDomain) { return $false }
    if ($script:State.FilterSearch -and -not $Item.SearchText.Contains($script:State.FilterSearch)) { return $false }
    switch ($script:State.FilterStatus) {
        'Prontos' { return $Item.Status -in $script:Ready }
        'Conferidos' { return $Item.Status -in $script:Confirmed }
        'LoginOk' { return $Item.Status -eq 'JA_COM_NOVO_LOGIN' }
        'LoginPendente' { return $Item.Status -eq 'NOVO_LOGIN_PENDENTE' }
        'Revisar' { return [bool]$Item.Revisar }
        'Ignorados' { return $Item.Status -in @('NAO_CONCLUIDO', 'SEM_CPF_PLANILHA', 'ACAO_NAO_SUPORTADA', 'LINHA_REPETIDA', 'DESATIVACAO_DESLIGADA', 'SEM_NOVO_LOGIN', 'ACAO_NA_PLANILHA') }
    }
    return $true
}

function Update-UiView {
    param([string]$DomainValue)
    if ($script:State.FilterUpdating -or $null -eq $script:State.ResultView) { return }
    $script:State.FilterSearch = ConvertTo-DomainKey $script:Ui.SearchBox.Text
    $domain = '__TODOS_DOMINIOS__'
    if ($script:Ui.DomainFilter.SelectedItem) { $domain = [string]$script:Ui.DomainFilter.SelectedItem.Value }
    if ($PSBoundParameters.ContainsKey('DomainValue')) { $domain = $DomainValue }
    $script:State.FilterDomain = ''
    if ($domain -and $domain -ne '__TODOS_DOMINIOS__') { $script:State.FilterDomain = $domain }
    $script:State.FilterStatus = [string]$script:Ui.StatusFilter.SelectedItem.Tag
    $sortField = [string]$script:Ui.SortBox.SelectedItem.Tag
    $sortProperty = $sortField
    if ($sortField -in @('CpfPlanilha', 'CpfAnterior')) { $sortProperty += 'Digits' }
    $direction = [ComponentModel.ListSortDirection]$script:State.SortDirection
    $view = $script:State.ResultView
    $defer = $view.DeferRefresh()
    try {
        $view.SortDescriptions.Clear()
        $view.SortDescriptions.Add((New-Object ComponentModel.SortDescription($sortProperty, $direction)))
        if ($sortProperty -ne 'Nome') { $view.SortDescriptions.Add((New-Object ComponentModel.SortDescription('Nome', [ComponentModel.ListSortDirection]::Ascending))) }
    } finally { $defer.Dispose() }
    $view.Refresh()
    foreach ($column in $script:Ui.ResultsGrid.Columns) {
        $column.SortDirection = $null
        if ($column.SortMemberPath -eq $sortField) { $column.SortDirection = $direction }
    }
    $script:Ui.SortDirectionButton.Content = 'A–Z'
    if ($direction -eq [ComponentModel.ListSortDirection]::Descending) { $script:Ui.SortDirectionButton.Content = 'Z–A' }
    $script:Ui.VisibleCountText.Text = "Exibindo $($view.Count) de $($script:State.Results.Count)"
    $active = @()
    if ($script:State.FilterSearch) { $active += ('Busca: ' + $script:Ui.SearchBox.Text) }
    if ($script:State.FilterDomain) { $active += ('Domínio: ' + $script:State.FilterDomain) }
    if ($script:State.FilterStatus -ne 'Todos') { $active += ('Situação: ' + $script:Ui.StatusFilter.SelectedItem.Content) }
    $script:Ui.VisibleCountText.ToolTip = $active -join ' | '
    if ($active.Count) { $script:Ui.VisibleCountText.Text += " · $($active.Count) filtro(s)" }
    $script:Ui.EmptyResultsText.Visibility = 'Collapsed'
    if ($view.IsEmpty) {
        $script:Ui.EmptyResultsText.Text = 'Nenhum registro corresponde aos filtros. Clique em Limpar para ver todos.'
        if ($active.Count) { $script:Ui.EmptyResultsText.Text = "Nenhum registro corresponde aos filtros: $($active -join ' | '). Clique em Limpar para ver todos." }
        if ($script:State.Results.Count -eq 0) { $script:Ui.EmptyResultsText.Text = 'Selecione um CSV para visualizar os usuários.' }
        $script:Ui.EmptyResultsText.Visibility = 'Visible'
    }
}

function Clear-UiFilters {
    $script:State.FilterUpdating = $true
    try {
        $script:Ui.SearchBox.Text = ''
        $script:Ui.DomainFilter.SelectedIndex = 0
        $script:Ui.StatusFilter.SelectedIndex = 0
        $script:Ui.SortBox.SelectedIndex = 0
        $script:State.SortDirection = 'Ascending'
    } finally { $script:State.FilterUpdating = $false }
    Update-UiView
}

function Get-UiFingerprint([byte[]]$Bytes, [string]$Json, [string]$Encoding) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $contentHash = [BitConverter]::ToString($hash.ComputeHash($Bytes))
        $settings = [Text.Encoding]::UTF8.GetBytes($contentHash + '|' + $Json + '|' + $Encoding)
        return [BitConverter]::ToString($hash.ComputeHash($settings))
    } finally { $hash.Dispose() }
}

function Update-UiMode {
    $logins = $script:State.Mode -eq 'Logins'
    $script:Ui.PendingTitle.Text = 'PRONTOS PARA APLICAR'; $script:Ui.OkTitle.Text = 'CONFERIDOS / APLICADOS'
    $script:Ui.OperationTitle.Text = '3. Confira e aplique'
    $script:Ui.OperationHint.Text = 'Ordene clicando nas colunas. O filtro altera somente a visualização.'
    if ($logins) {
        $script:Ui.PendingTitle.Text = 'NOVO LOGIN PENDENTE'; $script:Ui.OkTitle.Text = 'JÁ COM NOVO LOGIN'
        $script:Ui.OperationTitle.Text = '3. Verificação de logins'
        $script:Ui.OperationHint.Text = 'Somente consulta. Compare o login esperado com o atual no AD.'
    }
    foreach ($column in $script:Ui.ResultsGrid.Columns) {
        if ($column.SortMemberPath -in @('CpfPlanilha','CpfAnterior','AcaoTexto')) {
            $column.Visibility = 'Visible'; if ($logins) { $column.Visibility = 'Collapsed' }
        }
        if ($column.SortMemberPath -eq 'LoginEncontrado') {
            $column.Header = 'Login encontrado'; if ($logins) { $column.Header = 'Login atual no AD' }
            $column.Width = New-Object Windows.Controls.DataGridLength(130)
            if ($logins) { $column.Width = New-Object Windows.Controls.DataGridLength(1.3, [Windows.Controls.DataGridLengthUnitType]::Star) }
        }
        if ($column.SortMemberPath -eq 'Login') {
            $column.Header = 'Novo login / ação'; if ($logins) { $column.Header = 'Novo login esperado' }
        }
    }
}

function Set-UiResults([object[]]$Results, [switch]$Preview) {
    $script:State.Results = $Results
    $script:State.Preview = [bool]$Preview
    $script:State.ResultsStale = $false
    $script:Ui.StaleResultsBanner.Visibility = 'Collapsed'
    Update-UiMode
    $display = foreach ($row in $Results) {
        $label = [string]$row.Status
        if ($script:StatusLabels.ContainsKey($label)) { $label = $script:StatusLabels[$label] }
        $review = $row.Status -notin ($script:Ignored + $script:Ready + $script:Confirmed + @('NOVO_LOGIN_PENDENTE'))
        $action = 'PREENCHER_CPF'
        if ($row.PSObject.Properties['Acao']) { $action = [string]$row.Acao }
        elseif ((ConvertTo-DomainKey $row.Login) -eq 'DESATIVAR') { $action = 'DESATIVAR' }
        $actionText = 'Preencher CPF'; if ($action -eq 'DESATIVAR') { $actionText = 'Desativar' }
        if ($action -eq 'VERIFICAR_LOGIN') { $actionText = 'Verificar login' }
        $foundLogin = ''; if ($row.PSObject.Properties['LoginEncontrado']) { $foundLogin = [string]$row.LoginEncontrado }
        $previousEnabled = ''; $currentEnabled = ''
        if ($row.PSObject.Properties['ContaAtivaAnterior'] -and $row.ContaAtivaAnterior -is [bool]) {
            $previousEnabled = 'Não'; if ($row.ContaAtivaAnterior) { $previousEnabled = 'Sim' }
        }
        if ($row.PSObject.Properties['ContaAtivaAtual'] -and $row.ContaAtivaAtual -is [bool]) {
            $currentEnabled = 'Não'; if ($row.ContaAtivaAtual) { $currentEnabled = 'Sim' }
        }
        [pscustomobject]@{
            Nome = $row.Nome; Login = $row.Login; Dominio = $row.Dominio; CpfPlanilha = $row.CpfPlanilha
            Acao = $action; AcaoTexto = $actionText; LoginEncontrado = $foundLogin; ContaAtivaAnterior = $previousEnabled; ContaAtivaAtual = $currentEnabled
            CpfAnterior = $row.CpfAnterior; Status = $row.Status; Situacao = $label; Revisar = $review; Detalhe = $row.Detalhe
            Servidor = $row.Servidor; OrigemServidor = $row.OrigemServidor
            DomainKey = (ConvertTo-DomainKey $row.Dominio)
            CpfPlanilhaDigits = ($row.CpfPlanilha -replace '[^0-9]', '')
            CpfAnteriorDigits = ($row.CpfAnterior -replace '[^0-9]', '')
            SearchText = (ConvertTo-DomainKey (('{0} {1} {2} {3} {4} {5} {6}' -f $row.Nome, $row.Login, $row.CpfPlanilha, $row.CpfAnterior, ($row.CpfPlanilha -replace '[^0-9]', ''), ($row.CpfAnterior -replace '[^0-9]', ''), $foundLogin)))
        }
    }
    if (-not $Preview) {
        foreach ($item in $script:Domains) {
            $found = @($Results | Where-Object { (ConvertTo-DomainKey $_.Dominio) -eq (ConvertTo-DomainKey $item.Dominio) -and $_.Servidor } | Select-Object -ExpandProperty Servidor -Unique)
            $item.Descoberto = $found -join ', '
        }
        $script:Ui.DomainsGrid.Items.Refresh()
    }
    $collection = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    foreach ($item in @($display)) { $collection.Add($item) }
    $script:State.ResultView = [Windows.Data.CollectionViewSource]::GetDefaultView($collection)
    $script:State.ResultView.Culture = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
    $script:State.ResultView.Filter = [Predicate[object]]{ param($Item) return Test-UiRowVisible $Item }
    $script:Ui.ResultsGrid.ItemsSource = $script:State.ResultView
    $selectedDomain = '__TODOS_DOMINIOS__'
    if ($script:Ui.DomainFilter.SelectedItem) { $selectedDomain = [string]$script:Ui.DomainFilter.SelectedItem.Value }
    $script:State.FilterUpdating = $true
    try {
        $options = @([pscustomobject]@{ Label = 'Todos os domínios'; Value = '__TODOS_DOMINIOS__' })
        $seen = @{}
        foreach ($item in @($display | Sort-Object Dominio)) {
            if ($item.DomainKey -and -not $seen.ContainsKey($item.DomainKey)) {
                $seen[$item.DomainKey] = $true
                $options += [pscustomobject]@{ Label = $item.Dominio; Value = $item.DomainKey }
            }
        }
        $script:Ui.DomainFilter.ItemsSource = $options
        $script:Ui.DomainFilter.SelectedValue = $selectedDomain
        if ($script:Ui.DomainFilter.SelectedIndex -lt 0) { $script:Ui.DomainFilter.SelectedIndex = 0 }
    } finally { $script:State.FilterUpdating = $false }
    $script:Ui.TotalCount.Text = [string]$Results.Count
    if ($Preview) {
        $script:Ui.PendingCount.Text = '—'; $script:Ui.OkCount.Text = '—'; $script:Ui.ReviewCount.Text = '—'
    } else {
        $pendingStates = $script:Ready; if ($script:State.Mode -eq 'Logins') { $pendingStates = @('NOVO_LOGIN_PENDENTE') }
        $script:Ui.PendingCount.Text = [string]@($Results | Where-Object { $_.Status -in $pendingStates }).Count
        $script:Ui.OkCount.Text = [string]@($Results | Where-Object { $_.Status -in $script:Confirmed }).Count
        $script:Ui.ReviewCount.Text = [string]@($display | Where-Object { $_.Revisar }).Count
    }
    Update-UiView
}

function Get-UiPreviewRows([object[]]$Rows) {
    foreach ($row in $Rows) {
        $status = 'AGUARDANDO'; $detail = ''; $action = 'PREENCHER_CPF'
        if ((ConvertTo-DomainKey $row.Login) -eq 'DESATIVAR') {
            $action = 'DESATIVAR'
            $detail = 'A conta será identificada pelo nome completo, somente no DOMÍNIO desta linha. CONCLUÍDO e CPF não são exigidos para desativação.'
            if (-not $script:Ui.DisableUsersBox.IsChecked) {
                $status = 'DESATIVACAO_DESLIGADA'
                $detail = 'A opção Permitir desativação está desligada. Esta linha não será executada.'
            }
        }
        elseif ((ConvertTo-DomainKey $row.Concluido) -notin @('TRUE', 'VERDADEIRO', '1', 'SIM', 'X')) {
            $status = 'NAO_CONCLUIDO'
            $detail = 'A coluna CONCLUÍDO está desmarcada ou não contém um valor de conclusão reconhecido no CSV. Esta linha é pulada.'
        }
        elseif (-not $row.Cpf) { $status = 'SEM_CPF_PLANILHA' }
        [pscustomobject]@{
            Nome = $row.Nome; Login = $row.Login; Dominio = $row.Dominio; Acao = $action; ConcluidoPlanilha = $row.Concluido
            LoginEncontrado = ''; ContaAtivaAnterior = ''; ContaAtivaAtual = ''
            CpfPlanilha = $row.Cpf; CpfAnterior = ''; Status = $status; Detalhe = $detail; Servidor = ''; OrigemServidor = ''
        }
    }
}

function Import-UiCsv([string]$Path) {
    $encoding = [string]$script:Ui.EncodingBox.SelectedItem.Tag
    # Um arquivo rejeitado nunca pode deixar o CSV anterior selecionado para execução.
    $script:State.Fingerprint = ''; $script:State.Csv = ''; $script:State.Rows = @(); $script:State.Report = ''
    $script:State.SourceStamp = ''; $script:State.LastError = ''
    $script:State.Mode = 'Sincronizacao'
    Clear-UiFilters
    Set-UiResults @() -Preview
    $script:Ui.CsvPath.Text = 'Nenhum CSV carregado'
    foreach ($item in $script:Domains) { $item.Descoberto = '' }
    $script:Ui.DomainsGrid.Items.Refresh()
    Update-UiButtons
    try {
        $rows = @(Import-CpfCsv -Path $Path -Encoding $encoding)
        if ($rows.Count -eq 0) { throw 'O CSV não contém registros de usuários.' }
    } catch {
        $script:Ui.CsvPath.Text = 'Não carregado: ' + $Path
        $script:Ui.DetailsText.Text = 'O arquivo não foi carregado. Corrija o CSV ou a codificação e selecione-o novamente.'
        throw
    }
    $script:State.Csv = (Resolve-Path -LiteralPath $Path).Path
    $script:State.Rows = $rows
    $script:State.Report = ''
    Clear-UiFilters
    $script:Ui.CsvPath.Text = $script:State.Csv
    foreach ($item in $script:Domains) { $item.Descoberto = '' }
    foreach ($domain in @($rows.Dominio | Where-Object { $_ } | Select-Object -Unique)) {
        if (@($script:Domains | Where-Object { (ConvertTo-DomainKey $_.Dominio) -eq (ConvertTo-DomainKey $domain) }).Count -eq 0) { $script:Domains.Add([pscustomobject]@{ Dominio = $domain; Servidor = ''; Descoberto = '' }) }
    }
    $preview = @(Get-UiPreviewRows $rows)
    Set-UiResults @($preview) -Preview
    $script:Ui.StatusText.Text = "CSV carregado: $($rows.Count) usuários. Nenhuma consulta ao AD realizada."
    $script:Ui.DetailsText.Text = 'Clique em Verificar logins para conferir quem já usa o novo login. Simular no AD prepara as ações de CPF/desativação.'
    Update-UiButtons
}

function Start-UiOperation([bool]$Apply = $false, [switch]$CheckLogins) {
    if ($script:State.Busy) { return }
    $snapshot = ''
    $pipeline = $null
    try {
        $script:State.LastError = ''
        if (-not $script:State.Csv) { throw 'Selecione um CSV primeiro.' }
        if ($Apply -and ($CheckLogins -or $script:State.Mode -eq 'Logins')) { throw 'A verificação de logins é somente consulta. Execute Simular no AD antes de aplicar ações.' }
        $json = Get-UiConfigJson -ForLogins:$CheckLogins
        $encoding = [string]$script:Ui.EncodingBox.SelectedItem.Tag
        $bytes = [IO.File]::ReadAllBytes($script:State.Csv)
        $fingerprint = Get-UiFingerprint $bytes $json $encoding
        if ($Apply -and (-not $script:State.Fingerprint -or $fingerprint -cne $script:State.Fingerprint)) {
            Reset-UiSimulation
            throw 'O CSV ou a configuração mudou. Execute uma nova simulação antes de aplicar.'
        }
        if ($Apply -and @($script:State.Results | Where-Object { $_.Status -in $script:Ready }).Count -eq 0) { throw 'Não há ações prontas para aplicar. Execute uma simulação.' }
        $snapshot = Join-Path ([IO.Path]::GetTempPath()) ('cpf-ad-input-' + [guid]::NewGuid().ToString('N') + '.csv')
        [IO.File]::WriteAllBytes($snapshot, $bytes)
        $null = New-Item -ItemType Directory -Path $script:State.ReportFolder -Force
        $mode = 'simulacao'; if ($Apply) { $mode = 'aplicacao' }
        if ($CheckLogins) { $mode = 'logins' }
        $report = Join-Path $script:State.ReportFolder ('cpf-ad-{0}-{1}-{2}.csv' -f $mode, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        $pipeline = [powershell]::Create()
        $planJson = ''; if ($Apply) { $planJson = ConvertTo-Json -InputObject @($script:State.Results) -Depth 5 -Compress }
        $parameters = @{ Csv = $snapshot; ConfigJson = $json; ReportPath = $report; Codificacao = $encoding; Aplicar = $Apply; PlanoJson = $planJson }
        if ($CheckLogins) { $parameters.VerificarLogins = $true }
        $null = $pipeline.AddCommand($script:State.WorkerPath).AddParameters($parameters)
        $script:State.Fingerprint = ''
        Set-UiResultsStale 'Operação em andamento. A tabela ainda mostra os resultados da execução anterior.'
        $script:State.Job = @{ Pipeline = $pipeline; Handle = $pipeline.BeginInvoke(); Snapshot = $snapshot; Fingerprint = $fingerprint; Apply = $Apply; Report = $report; CheckLogins = [bool]$CheckLogins }
        $script:State.Busy = $true
        $script:Ui.StatusText.Text = 'Consultando o AD e preparando o relatório. Aguarde...'
        if ($Apply) { $script:Ui.StatusText.Text = 'Aplicando as ações simuladas e confirmando cada alteração no AD. Aguarde...' }
        if ($CheckLogins) { $script:Ui.StatusText.Text = 'Verificando novos logins em todas as linhas, somente no domínio indicado. Nenhuma conta será alterada.' }
        Update-UiButtons
    } catch {
        if ($pipeline) { $pipeline.Dispose() }
        if ($snapshot -and (Test-Path -LiteralPath $snapshot)) { Remove-Item -LiteralPath $snapshot -Force }
        $script:State.Job = $null; $script:State.Busy = $false; $script:State.Fingerprint = ''
        Set-UiResultsStale 'A operação não foi concluída. Os resultados anteriores não autorizam uma nova aplicação; simule novamente.'
        Show-UiError (Get-UiErrorMessage $_)
        Update-UiButtons
    }
}

function Complete-UiOperation {
    $job = $script:State.Job
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    try {
        $output = @($job.Pipeline.EndInvoke($job.Handle))
        if ($job.Pipeline.HadErrors) { throw [string]$job.Pipeline.Streams.Error[0] }
        if ($output.Count -ne 1 -or -not $output[0].PSObject.Properties['Results']) { throw 'A execução não retornou um resultado válido. Consulte o relatório, se disponível.' }
        $nextMode = 'Sincronizacao'; if ($job.CheckLogins) { $nextMode = 'Logins' }
        if ($script:State.Mode -ne $nextMode) { Clear-UiFilters }
        $script:State.Mode = $nextMode
        Set-UiResults @($output[0].Results)
        $script:State.Report = $job.Report
        if ($job.Apply) {
            $script:Ui.StatusText.Text = 'Aplicação concluída. Confira as situações e o relatório de cada usuário.'
        } else {
            $current = Get-UiFingerprint ([IO.File]::ReadAllBytes($script:State.Csv)) (Get-UiConfigJson -ForLogins:$job.CheckLogins) ([string]$script:Ui.EncodingBox.SelectedItem.Tag)
            if ($current -ceq $job.Fingerprint) {
                $script:State.Fingerprint = $job.Fingerprint
                $file = Get-Item -LiteralPath $script:State.Csv -ErrorAction Stop
                $script:State.SourceStamp = '{0}:{1}' -f $file.LastWriteTimeUtc.Ticks, $file.Length
                $cpfCount = @($script:State.Results | Where-Object { $_.Status -eq 'SIMULADO_PREENCHER' }).Count
                $disableCount = @($script:State.Results | Where-Object { $_.Status -eq 'SIMULADO_DESATIVAR' }).Count
                $script:Ui.StatusText.Text = "Simulação: $cpfCount CPF(s) para preencher; $disableCount conta(s) para desativar. Nenhuma alteração no AD."
                if ($job.CheckLogins) {
                    $okCount = @($script:State.Results | Where-Object { $_.Status -eq 'JA_COM_NOVO_LOGIN' }).Count
                    $pendingCount = @($script:State.Results | Where-Object { $_.Status -eq 'NOVO_LOGIN_PENDENTE' }).Count
                    $script:Ui.StatusText.Text = "Logins: $okCount já estão com o novo login; $pendingCount ainda usam outro login. Nenhuma conta alterada."
                }
            } else {
                $script:Ui.StatusText.Text = 'O arquivo mudou durante a consulta. Os resultados são da cópia anterior; execute novamente.'
                Set-UiResultsStale $script:Ui.StatusText.Text
            }
        }
        $script:Ui.DetailsText.Text = 'Selecione uma linha para conferir a situação. O relatório inclui todos os detalhes da execução.'
    } catch {
        $script:State.Fingerprint = ''
        Set-UiResultsStale 'A execução não terminou normalmente. Consulte o relatório disponível e faça uma nova simulação antes de aplicar.'
        if (Test-Path -LiteralPath $job.Report) { $script:State.Report = $job.Report }
        Show-UiError (Get-UiErrorMessage $_)
    } finally {
        $job.Pipeline.Dispose()
        if (Test-Path -LiteralPath $job.Snapshot) { Remove-Item -LiteralPath $job.Snapshot -Force }
        $script:State.Job = $null; $script:State.Busy = $false
        Update-UiButtons
    }
}

try {
    $xml = [xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Interface-CpfAD.xaml') -Raw -Encoding UTF8)
    $reader = New-Object Xml.XmlNodeReader $xml
    try { $script:Window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $workArea = [Windows.SystemParameters]::WorkArea
    $script:Window.MinWidth = [Math]::Min(1080, $workArea.Width)
    $script:Window.MinHeight = [Math]::Min(620, $workArea.Height)
    $script:Window.Width = [Math]::Min(1280, $workArea.Width)
    $script:Window.Height = [Math]::Min(900, $workArea.Height)
    foreach ($name in @('SessionLabel','CsvPath','EncodingBox','BrowseButton','DisableUsersBox','ConfigExpander','DomainsGrid','AttributeBox','SaveConfigButton','TotalCount','PendingCount','OkCount','ReviewCount','PendingTitle','OkTitle','OperationTitle','OperationHint','OpenReportButton','SimulateButton','VerifyLoginsButton','ApplyButton','ResultsGrid','DetailsText','BusyBar','StatusText','SetupScroll','SummaryCards','SearchBox','DomainFilter','StatusFilter','SortBox','SortDirectionButton','ClearFiltersButton','VisibleCountText','EmptyResultsText','StaleResultsBanner','StaleResultsText')) { $script:Ui[$name] = $script:Window.FindName($name) }
    # A desativação exige habilitação em cada abertura, mesmo com configuração salva.
    $script:Ui.DisableUsersBox.IsChecked = $false
    $script:Ui.SessionLabel.Text = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $script:Ui.EncodingBox.SelectedIndex = 0
    $script:Ui.DomainFilter.ItemsSource = @([pscustomobject]@{ Label = 'Todos os domínios'; Value = '__TODOS_DOMINIOS__' })
    $script:Ui.DomainFilter.SelectedIndex = 0
    $script:Ui.StatusFilter.SelectedIndex = 0
    $script:Ui.SortBox.SelectedIndex = 0
    $config = Get-Content -LiteralPath $script:State.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Ui.AttributeBox.Text = [string]$config.AtributoCpf
    $script:Domains = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    foreach ($property in $config.Dominios.PSObject.Properties) { $script:Domains.Add([pscustomobject]@{ Dominio = $property.Name; Servidor = [string]$property.Value; Descoberto = '' }) }
    $script:Ui.DomainsGrid.ItemsSource = $script:Domains

    $script:Ui.BrowseButton.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = 'Selecionar CSV de usuários'; $dialog.Filter = 'Planilhas CSV (*.csv)|*.csv|Todos os arquivos (*.*)|*.*'
        if ($dialog.ShowDialog($script:Window)) { try { Import-UiCsv $dialog.FileName } catch { Show-UiError (Get-UiErrorMessage $_) } }
    })
    $script:Ui.EncodingBox.Add_SelectionChanged({
        Reset-UiSimulation
        if ($script:State.Csv) { try { Import-UiCsv $script:State.Csv } catch { Show-UiError (Get-UiErrorMessage $_) } }
    })
    $script:Ui.SearchBox.Add_TextChanged({ Update-UiView })
    $script:Ui.DomainFilter.Add_SelectionChanged({
        param($sender, $eventArgs)
        if ($script:State.FilterUpdating) { return }
        $value = '__TODOS_DOMINIOS__'
        if ($eventArgs.AddedItems.Count -gt 0) { $value = [string]$eventArgs.AddedItems[0].Value }
        Update-UiView -DomainValue $value
    })
    $script:Ui.StatusFilter.Add_SelectionChanged({ Update-UiView })
    $script:Ui.SortBox.Add_SelectionChanged({
        if (-not $script:State.FilterUpdating) { $script:State.SortDirection = 'Ascending'; Update-UiView }
    })
    $script:Ui.SortDirectionButton.Add_Click({
        if ($script:State.SortDirection -eq 'Ascending') { $script:State.SortDirection = 'Descending' } else { $script:State.SortDirection = 'Ascending' }
        Update-UiView
    })
    $script:Ui.ClearFiltersButton.Add_Click({ Clear-UiFilters })
    $script:Ui.ResultsGrid.Add_Sorting({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        $property = $eventArgs.Column.SortMemberPath
        if ([string]$script:Ui.SortBox.SelectedItem.Tag -eq $property -and $script:State.SortDirection -eq 'Ascending') { $script:State.SortDirection = 'Descending' }
        else { $script:State.SortDirection = 'Ascending' }
        $script:State.FilterUpdating = $true
        try {
            for ($i = 0; $i -lt $script:Ui.SortBox.Items.Count; $i++) {
                if ([string]$script:Ui.SortBox.Items[$i].Tag -eq $property) { $script:Ui.SortBox.SelectedIndex = $i; break }
            }
        } finally { $script:State.FilterUpdating = $false }
        Update-UiView
    })
    $script:Ui.AttributeBox.Add_TextChanged({ Reset-UiSimulation })
    $disableOptionChanged = {
        Reset-UiSimulation 'A opção de desativação mudou. Execute uma nova simulação antes de aplicar.'
        if ($script:State.Preview -and $script:State.Rows.Count) {
            Set-UiResults @(Get-UiPreviewRows $script:State.Rows) -Preview
            Update-UiButtons
        }
    }
    $script:Ui.DisableUsersBox.Add_Checked($disableOptionChanged)
    $script:Ui.DisableUsersBox.Add_Unchecked($disableOptionChanged)
    $script:Ui.DomainsGrid.Add_PreparingCellForEdit({ Reset-UiSimulation })
    $script:Ui.SaveConfigButton.Add_Click({
        try {
            $json = Get-UiConfigJson
            [IO.File]::WriteAllText($script:State.ConfigPath, (($json | ConvertFrom-Json) | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
            $script:Ui.StatusText.Text = 'Configuração salva. A permissão de desativação deve ser ativada novamente a cada abertura.'
        } catch { Show-UiError (Get-UiErrorMessage $_) }
    })
    $script:Ui.SimulateButton.Add_Click({ Start-UiOperation })
    $script:Ui.VerifyLoginsButton.Add_Click({ Start-UiOperation -CheckLogins })
    $script:Ui.ApplyButton.Add_Click({ Start-UiOperation -Apply $true })
    $script:Ui.OpenReportButton.Add_Click({
        try { Invoke-Item -LiteralPath $script:State.Report -ErrorAction Stop } catch { Show-UiError (Get-UiErrorMessage $_) }
    })
    $script:Ui.ResultsGrid.Add_SelectionChanged({
        $item = $script:Ui.ResultsGrid.SelectedItem
        if ($item) {
            $details = "$($item.Nome) — $($item.Situacao)."
            $details += " Ação: $($item.AcaoTexto)."
            if ($item.LoginEncontrado) { $details += " Login encontrado: $($item.LoginEncontrado)." }
            if ($item.ContaAtivaAnterior) { $details += " Conta ativa antes: $($item.ContaAtivaAnterior)." }
            if ($item.ContaAtivaAtual) { $details += " Conta ativa agora: $($item.ContaAtivaAtual)." }
            if ($item.Servidor) { $details += " Domínio: $($item.Dominio). Servidor: $($item.Servidor) ($($item.OrigemServidor))." }
            if ($item.Detalhe) { $details += ' ' + $item.Detalhe }
            $script:Ui.DetailsText.Text = $details; $script:Ui.DetailsText.ToolTip = $details
        }
    })
    $script:Window.Add_Closing({
        param($sender, $eventArgs)
        if ($script:State.Busy) { $eventArgs.Cancel = $true; $script:Ui.StatusText.Text = 'Aguarde a operação terminar antes de fechar a janela.' }
    })
    $script:Timer = New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:Timer.Add_Tick({ Complete-UiOperation; Test-UiSourceChanged })
    $script:Window.Add_Closed({ $script:Timer.Stop() })
    $script:Window.Add_SizeChanged({ Update-UiLayout })
    Update-UiLayout
    Update-UiButtons
    if (-not $NaoExibir) { $script:Timer.Start(); $null = $script:Window.ShowDialog() }
} catch {
    if ($NaoExibir) { throw }
    $null = [Windows.MessageBox]::Show($_.Exception.Message, 'Não foi possível abrir CPF AD', 'OK', 'Error')
    exit 1
}
