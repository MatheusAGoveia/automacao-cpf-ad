#requires -Version 5.1
[CmdletBinding()]
param([string]$Imagem)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Interface-CpfAD.ps1') -NaoExibir
$temp = Join-Path ([IO.Path]::GetTempPath()) ('cpf-ad-ui-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$State.ReportFolder = Join-Path $temp 'relatorios'
$State.ConfigPath = Join-Path $temp 'dominios.json'
$passed = 0
function Assert-Ui($Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++; Write-Host "OK: $Message" }
function Wait-UiJob {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($State.Busy -and [DateTime]::UtcNow -lt $deadline) { Complete-UiOperation; Start-Sleep -Milliseconds 25 }
    if ($State.Busy) { throw 'Worker não terminou no prazo do teste.' }
}
function Measure-UiLayout([int]$Width, [int]$Height) {
    Update-UiLayout $Height
    $view = $Window.Content
    $view.Measure((New-Object Windows.Size($Width, $Height)))
    $view.Arrange((New-Object Windows.Rect(0, 0, $Width, $Height)))
    $view.UpdateLayout()
    $view.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ContextIdle)
    $view.UpdateLayout()
}
function Save-UiImage([string]$Path, [int]$Width = 1260, [int]$Height = 850) {
    Measure-UiLayout $Width $Height
    $view = $Window.Content
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($Width, $Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($view)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $file = [IO.File]::Create($Path)
    try { $encoder.Save($file) } finally { $file.Dispose() }
}
try {
    Assert-Ui (-not $Ui.ApplyButton.IsEnabled) 'Aplicar começa bloqueado'
    Assert-Ui (-not $Ui.SimulateButton.IsEnabled) 'Simular exige CSV'
    Assert-Ui (-not $Ui.DisableUsersBox.IsChecked) 'Permitir desativação começa desmarcado'
    Assert-Ui ($Window.Height -le [Windows.SystemParameters]::WorkArea.Height -and $Window.Width -le [Windows.SystemParameters]::WorkArea.Width) 'Janela inicial cabe na área útil da tela'
    $csv = Join-Path $temp 'usuarios.csv'
    $text = @'
NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO
Pessoa Exemplo A,BETIM.PMB,pessoa.a,00000000191,TRUE
Pessoa Exemplo B,BETIM.PMB,pessoa.b,000.000.002-72,TRUE
Pessoa Exemplo C,BETIM.PMB,pessoa.c,000.000.003-53,FALSE
Pessoa Exemplo D,SAUDE.BETIM,pessoa.d,,TRUE
Pessoa Exemplo E,BETIM.PMB,pessoa.e,000.000.003-53,TRUE
'@
    [IO.File]::WriteAllText($csv, $text, (New-Object Text.UTF8Encoding($false)))
    Import-UiCsv $csv
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 5) 'Prévia mostra todas as linhas sem acessar o AD'
    $pendingRow = @($Ui.ResultsGrid.Items | Where-Object { $_.Login -eq 'pessoa.c' })[0]
    $Ui.ResultsGrid.SelectedItem = $pendingRow
    Assert-Ui ($pendingRow.Situacao -eq 'Pendente na planilha' -and $Ui.DetailsText.Text -like '*CONCLUÍDO*') 'Situação pendente explica a marcação ausente na planilha'
    Assert-Ui ($Domains.Count -eq 2) 'Saúde com ou sem acento identifica o mesmo domínio na interface'
    Assert-Ui ($Ui.SimulateButton.IsEnabled -and -not $Ui.ApplyButton.IsEnabled) 'Importar libera somente simulação'
    $invalidCsv = Join-Path $temp 'invalido.csv'
    [IO.File]::WriteAllText($invalidCsv, 'nome,cpf')
    $rejected = $false
    try { Import-UiCsv $invalidCsv } catch { $rejected = $true }
    Assert-Ui ($rejected -and -not $State.Csv -and $Ui.ResultsGrid.Items.Count -eq 0 -and -not $Ui.SimulateButton.IsEnabled) 'CSV inválido limpa o arquivo anterior e impede execução com dados antigos'
    Import-UiCsv $csv
    Measure-UiLayout 1060 650
    Assert-Ui ($Ui.ResultsGrid.ActualHeight -ge 120) 'Tabela conserva espaço útil em janela baixa de 1060x650'
    $Ui.ConfigExpander.IsExpanded = $true
    Measure-UiLayout 1060 650
    Assert-Ui ($Ui.ResultsGrid.ActualHeight -ge 120 -and $Ui.SetupScroll.ComputedVerticalScrollBarVisibility -eq 'Visible') 'Configuração expandida usa rolagem sem esconder a planilha'
    $Ui.ConfigExpander.IsExpanded = $false

    $Ui.SearchBox.Text = 'PESSÓA EXEMPLO A'
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 1 -and $Ui.ResultsGrid.Items[0].Login -eq 'pessoa.a') 'Busca de nome ignora caixa e acentos'
    $Ui.SearchBox.Text = '00000000272'
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 1) 'Busca de CPF sem pontuação encontra CPF formatado'
    $Ui.DomainFilter.SelectedValue = 'SAUDE.BETIM'
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 0 -and $Ui.EmptyResultsText.Visibility -eq 'Visible') 'Filtros combinados mostram estado vazio e preservam os dados'
    $Ui.ClearFiltersButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 5 -and $Ui.VisibleCountText.Text -eq 'Exibindo 5 de 5') 'Limpar restaura todos os registros e a contagem'
    $Ui.DomainFilter.SelectedValue = 'SAUDE.BETIM'
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 1) 'Selecionar Saúde mostra somente Saúde'
    $Ui.DomainFilter.SelectedIndex = 0
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 5 -and -not $State.FilterDomain) 'Selecionar Todos os domínios diretamente restaura Betim e Saúde'
    $Ui.DomainFilter.SelectedValue = 'SAUDE.BETIM'
    $removedItems = New-Object Collections.ArrayList
    $addedItems = New-Object Collections.ArrayList
    $null = $removedItems.Add($Ui.DomainFilter.SelectedItem)
    $null = $addedItems.Add($Ui.DomainFilter.Items[0])
    $selectionEvent = New-Object Windows.Controls.SelectionChangedEventArgs([Windows.Controls.Primitives.Selector]::SelectionChangedEvent, $removedItems, $addedItems)
    $Ui.DomainFilter.RaiseEvent($selectionEvent)
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 5 -and -not $State.FilterDomain) 'Evento Todos usa a nova seleção mesmo quando o controle ainda expõe a anterior'
    $Ui.DomainFilter.SelectedIndex = 0
    Set-UiResults @($State.Results) -Preview
    Assert-Ui ($Ui.DomainFilter.SelectedValue -eq '__TODOS_DOMINIOS__' -and $Ui.ResultsGrid.Items.Count -eq 5) 'Todos permanece selecionado após reconstruir os resultados'
    $Ui.SearchBox.Text = 'pessoa.a'
    $Ui.DomainFilter.SelectedValue = 'SAUDE.BETIM'
    $Ui.DomainFilter.SelectedIndex = 0
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 1 -and $Ui.VisibleCountText.Text -like '*1 filtro(s)*') 'Todos remove o domínio e informa a busca que permanece ativa'
    Clear-UiFilters
    $Ui.StatusFilter.SelectedIndex = 4
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 2) 'Filtro Ignorados mostra pendentes e linhas sem CPF'
    Clear-UiFilters
    $Ui.SortBox.SelectedIndex = 1
    $Ui.SortDirectionButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    Assert-Ui ($Ui.ResultsGrid.Items[0].Login -eq 'pessoa.e') 'Ordenação por login decrescente funciona'
    $sorting = $Ui.ResultsGrid.GetType().GetMethod('OnSorting', [Reflection.BindingFlags]'Instance,NonPublic')
    $sortEvent = New-Object Windows.Controls.DataGridSortingEventArgs($Ui.ResultsGrid.Columns[2])
    $invokeArgs = New-Object object[] 1
    $invokeArgs[0] = $sortEvent.PSObject.BaseObject
    $null = $sorting.Invoke($Ui.ResultsGrid, $invokeArgs)
    $sortEvent = New-Object Windows.Controls.DataGridSortingEventArgs($Ui.ResultsGrid.Columns[2])
    $invokeArgs[0] = $sortEvent.PSObject.BaseObject
    $null = $sorting.Invoke($Ui.ResultsGrid, $invokeArgs)
    Assert-Ui ($Ui.ResultsGrid.Items[0].Login -eq 'pessoa.d' -and $Ui.SortBox.SelectedItem.Tag -eq 'Dominio') 'Cabeçalho ordena domínio e inverte a direção no segundo clique'
    Clear-UiFilters
    $Ui.SortBox.SelectedIndex = 3
    $orderedCpfs = @($Ui.ResultsGrid.Items | Where-Object { $_.CpfPlanilha })
    Assert-Ui ($orderedCpfs[0].Login -eq 'pessoa.a' -and $orderedCpfs[1].Login -eq 'pessoa.b') 'Ordenação de CPF ignora pontuação em formatos mistos'
    Clear-UiFilters
    foreach ($item in $Domains) { $item.Servidor = 'dc.exemplo.test' }
    $Ui.DomainsGrid.Items.Refresh()
    $Ui.SaveConfigButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    $savedConfig = Get-Content -LiteralPath $State.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Ui ($savedConfig.Dominios.'BETIM.PMB' -eq 'dc.exemplo.test') 'Botão Salvar persiste a configuração em JSON'
    Assert-Ui ($savedConfig.FormatoCpf -eq 'Numeros') 'Interface salva CPF numérico fixo'
    foreach ($item in $Domains) { $item.Servidor = '' }
    $Ui.DomainsGrid.Items.Refresh()

    $fakeWorker = @'
param($Csv, $ConfigJson, $ReportPath, $Codificacao, [bool]$Aplicar, $PlanoJson)
$ErrorActionPreference = 'Stop'
Import-Module '__CORE__' -Force
$rows = @(Import-CpfCsv -Path $Csv -Encoding $Codificacao)
$global:CpfAdUiDirectory = @{}
$index = 0
foreach ($row in $rows) {
    $index++
    $name = $row.Nome; if ($row.Login -eq 'pessoa.e' -and -not $Aplicar) { $name = 'Cadastro Diferente' }
    $cpf = ''; if ($row.Login -eq 'pessoa.b' -and -not $Aplicar) { $cpf = $row.Cpf }
    $identity = [guid]('00000000-0000-0000-0000-{0:D12}' -f $index)
    $login = $row.Login; if ($login.Trim() -ieq 'desativar') { $login = 'pessoa.desativar.' + $index }
    $enabled = $name -ne 'Pessoa Já Desativada'
    $global:CpfAdUiDirectory[[string]$index] = [pscustomobject]@{ Domain = (ConvertTo-DomainKey $row.Dominio); Name = $name; DisplayName = $name; SamAccountName = $login; ObjectGUID = $identity; CPF = $cpf; Enabled = $enabled }
}
New-Module -Name ActiveDirectory -ScriptBlock {
    function Get-ADDomainController { [CmdletBinding()] param([switch]$Discover,$DomainName,[switch]$Writable,$Service) [pscustomobject]@{ HostName = @('dc.' + $DomainName); Domain = $DomainName } }
    function Get-ADRootDSE {
        [CmdletBinding()] param($Server)
        $dnsDomain = $Server -replace '^dc\.', ''
        [pscustomobject]@{ schemaNamingContext = 'CN=Schema'; dnsHostName = $Server; defaultNamingContext = ('DC=' + ($dnsDomain -replace '\.', ',DC=')) }
    }
    function Get-ADObject { [CmdletBinding()] param($Server,$SearchBase,$LDAPFilter,$Properties) [pscustomobject]@{ isSingleValued = $true } }
    function Get-ADUser {
        [CmdletBinding()] param($Server,$LDAPFilter,$Properties,$Identity)
        $domain = $Server -replace '^dc\.', ''
        if ($Identity) { @($global:CpfAdUiDirectory.Values | Where-Object { $_.ObjectGUID -eq $Identity -and $_.Domain -ieq $domain }) | ForEach-Object { $_.PSObject.Copy() } }
        else {
            foreach ($user in $global:CpfAdUiDirectory.Values) {
                if ($user.Domain -ine $domain) { continue }
                if ($LDAPFilter -eq ('(sAMAccountName=' + $user.SamAccountName + ')') -or $LDAPFilter -eq ('(|(name=' + $user.Name + ')(displayName=' + $user.Name + '))')) { $user.PSObject.Copy() }
            }
        }
    }
    function Set-ADUser {
        [CmdletBinding(SupportsShouldProcess)] param($Server,$Identity,$Add)
        if ($Add['CPF'] -notmatch '^[0-9]{11}$') { throw 'CPF deve conter somente 11 dígitos.' }
        ($global:CpfAdUiDirectory.Values | Where-Object { $_.ObjectGUID -eq $Identity }).CPF = $Add['CPF']
    }
    function Disable-ADAccount {
        [CmdletBinding(SupportsShouldProcess)] param($Server,$Identity)
        $users = @($global:CpfAdUiDirectory.Values | Where-Object { $_.ObjectGUID -eq $Identity -and $_.Domain -ieq ($Server -replace '^dc\.', '') })
        if ($users.Count -ne 1) { throw 'Conta de desativação não pertence ao domínio indicado.' }
        $users[0].Enabled = $false
    }
    Export-ModuleMember -Function Get-ADRootDSE,Get-ADObject,Get-ADUser,Set-ADUser,Get-ADDomainController,Disable-ADAccount
} | Import-Module -Global -Force
Start-Sleep -Milliseconds 150
& '__WORKER__' -Csv $Csv -ConfigJson $ConfigJson -ReportPath $ReportPath -Codificacao $Codificacao -Aplicar $Aplicar -PlanoJson $PlanoJson
'@
    $fakeWorker = $fakeWorker.Replace('__CORE__', (Join-Path $root 'CpfAd.psm1').Replace("'", "''"))
    $fakeWorker = $fakeWorker.Replace('__WORKER__', (Join-Path $root 'Executar-CpfAD.ps1').Replace("'", "''"))
    $worker = Join-Path $temp 'worker.ps1'
    [IO.File]::WriteAllText($worker, $fakeWorker, (New-Object Text.UTF8Encoding($true)))
    $State.WorkerPath = $worker
    Start-UiOperation
    Assert-Ui ($State.Busy -and -not $Ui.BrowseButton.IsEnabled -and -not $Ui.ApplyButton.IsEnabled) 'Worker assíncrono bloqueia início duplo e alterações'
    Wait-UiJob
    Assert-Ui (-not $State.LastError) "Simulação termina sem erro ($($State.LastError))"
    Assert-Ui ($Ui.ApplyButton.IsEnabled) 'Simulação válida libera aplicação'
    Assert-Ui ($Domains[0].Descoberto -eq 'dc.betim.pmb' -and -not $Domains[0].Servidor) 'Controlador automático aparece na tela sem preencher override manual'
    Assert-Ui ($Ui.PendingCount.Text -eq '1' -and $Ui.OkCount.Text -eq '1' -and $Ui.ReviewCount.Text -eq '1') 'Contadores distinguem prontos, conferidos e revisão'
    Assert-Ui ($Ui.OpenReportButton.IsEnabled) 'Relatório está disponível após simulação'
    [IO.File]::WriteAllText($csv, $text + "`r`n", (New-Object Text.UTF8Encoding($false)))
    Test-UiSourceChanged -Force
    $readyDisplayed = @($State.ResultView.SourceCollection | Where-Object { $_.Status -eq 'SIMULADO_PREENCHER' }).Count
    Assert-Ui (-not $State.Fingerprint -and $Ui.StaleResultsBanner.Visibility -eq 'Visible' -and $Ui.ApplyButton.Content -eq 'Aplicar todos (0)' -and $readyDisplayed -eq 0) 'Alteração externa do CSV invalida a simulação e retira a indicação de prontos'
    Measure-UiLayout 1060 650
    Assert-Ui ($Ui.ResultsGrid.ActualHeight -ge 100) 'Aviso de simulação desatualizada mantém a tabela visível em janela compacta'
    if ($Imagem) {
        $Ui.SessionLabel.Text = 'PRÉVIA DE TESTE · DADOS FICTÍCIOS'
        Save-UiImage ([IO.Path]::ChangeExtension($Imagem, 'desatualizada.png')) 1060 650
    }
    [IO.File]::WriteAllText($csv, $text, (New-Object Text.UTF8Encoding($false)))
    Start-UiOperation
    Wait-UiJob
    Assert-Ui ($Ui.ApplyButton.IsEnabled -and $Ui.StaleResultsBanner.Visibility -eq 'Collapsed') 'Nova simulação válida remove a indicação de resultados antigos'
    $fingerprint = $State.Fingerprint
    $Ui.StatusFilter.SelectedIndex = 2
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 1 -and $Ui.ResultsGrid.Items[0].Login -eq 'pessoa.b') 'Filtro Conferidos mostra somente CPF já conferido'
    $Ui.StatusFilter.SelectedIndex = 3
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 1 -and $Ui.ResultsGrid.Items[0].Login -eq 'pessoa.e') 'Filtro Revisar mostra divergências'
    $Ui.StatusFilter.SelectedIndex = 1
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 1 -and $Ui.ResultsGrid.Items[0].Login -eq 'pessoa.a') 'Filtro Prontos mostra alterações previstas'
    $Ui.DomainFilter.SelectedValue = 'SAUDE.BETIM'
    Assert-Ui ($State.Fingerprint -eq $fingerprint -and $State.Results.Count -eq 5 -and $Ui.ApplyButton.Content -eq 'Aplicar todos (1)') 'Filtro visual não altera o plano e o botão informa o total da aplicação'
    Clear-UiFilters

    # Cópia imutável: arquivo original muda antes de o worker ler os dados.
    Start-UiOperation
    [IO.File]::WriteAllText($csv, 'arquivo alterado')
    Wait-UiJob
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 5 -and -not $State.LastError) 'Worker usa a cópia original mesmo se CSV mudar'
    Assert-Ui (-not $Ui.ApplyButton.IsEnabled) 'CSV alterado durante simulação não libera aplicação'
    Assert-Ui ($Ui.StaleResultsBanner.Visibility -eq 'Visible' -and $Ui.PendingCount.Text -eq '—') 'Resultados de cópia anterior ficam identificados e sem contagem de prontos'
    [IO.File]::WriteAllText($csv, $text, (New-Object Text.UTF8Encoding($false)))

    Start-UiOperation
    Wait-UiJob
    $Domains[0].Servidor = 'outro.exemplo.test'
    Start-UiOperation -Apply $true
    Assert-Ui (-not $State.Busy -and -not $Ui.ApplyButton.IsEnabled -and $State.LastError -like '*mudou*') 'Configuração alterada bloqueia aplicação mesmo sem evento visual'
    $Domains[0].Servidor = ''
    Start-UiOperation
    Wait-UiJob
    Start-UiOperation -Apply $true
    Wait-UiJob
    if ($State.LastError) { throw "Erro de integração: $($State.LastError)" }
    $applied = @($State.Results | Where-Object { $_.Status -eq 'ATUALIZADO' }).Count
    if ($applied -ne 1) { throw ('Resultado inesperado da aplicação: ' + ($State.Results | ConvertTo-Json -Depth 4 -Compress)) }
    Assert-Ui ($applied -eq 1) 'Aplicação percorre UI, worker e motor de regras'
    Assert-Ui (@($State.Results | Where-Object { $_.Login -eq 'pessoa.e' -and $_.Status -eq 'NOME_DIVERGENTE' }).Count -eq 1) 'Mudança posterior no AD não inclui usuários fora da simulação aprovada'
    $savedReport = @(Import-Csv -LiteralPath $State.Report -Delimiter ';' -Encoding UTF8)
    Assert-Ui ($savedReport.Count -eq 5) 'Relatório final preserva todas as linhas do CSV'
    Assert-Ui (-not $Ui.ApplyButton.IsEnabled) 'Após aplicar é necessário simular novamente'

    Start-UiOperation
    Wait-UiJob
    $badWorker = Join-Path $temp 'erro.ps1'
    [IO.File]::WriteAllText($badWorker, "param(`$Csv,`$ConfigJson,`$ReportPath,`$Codificacao,`$Aplicar)`r`nthrow 'Erro fictício de conexão.'", (New-Object Text.UTF8Encoding($true)))
    $State.WorkerPath = $badWorker
    Start-UiOperation
    Wait-UiJob
    Assert-Ui ($State.LastError -like '*Erro fictício*' -and $Ui.SimulateButton.IsEnabled -and -not $Ui.ApplyButton.IsEnabled) 'Erro do worker é exibido e libera controles sem liberar aplicação'
    Assert-Ui ($Ui.StaleResultsBanner.Visibility -eq 'Visible') 'Erro do worker identifica a tabela anterior como desatualizada'
    Assert-Ui ($State.LastError -notlike '*EndInvoke*') 'Erro do worker mostra a causa sem detalhes internos do PowerShell'
    $State.WorkerPath = $worker
    Start-UiOperation
    Wait-UiJob
    $Ui.AttributeBox.Text = 'outroCPF'
    Assert-Ui (-not $Ui.ApplyButton.IsEnabled) 'Edição na tela invalida a simulação'
    Assert-Ui ($Ui.StaleResultsBanner.Visibility -eq 'Visible' -and $Ui.ApplyButton.Content -eq 'Aplicar todos (0)') 'Edição da configuração não mantém indicação antiga de usuários prontos'
    $Ui.AttributeBox.Text = 'CPF'

    Start-UiOperation
    Wait-UiJob
    $mixedCsv = Join-Path $temp 'usuarios-acoes.csv'
    $mixedText = @'
NOME COMPLETO,DOMINIO,NOVO LOGIN,CPF,CONCLUÍDO
Pessoa Exemplo A,BETIM.PMB,pessoa.a,00000000191,TRUE
Pessoa Desativar,BETIM.PMB,desativar,,FALSE
Pessoa Desativar,SAÚDE.BETIM,pessoa.saude,,FALSE
Pessoa Já Desativada,SAÚDE.BETIM, desativar ,,FALSE
'@
    [IO.File]::WriteAllText($mixedCsv, $mixedText, (New-Object Text.UTF8Encoding($true)))
    Import-UiCsv $mixedCsv
    Assert-Ui (@($State.Results | Where-Object { $_.Status -eq 'DESATIVACAO_DESLIGADA' }).Count -eq 2) 'Prévia explica as duas ações desativar com opção desligada'
    $Ui.DisableUsersBox.IsChecked = $true
    $uiConfig = Get-UiConfigJson | ConvertFrom-Json
    Assert-Ui ($uiConfig.DesativarUsuarios -eq $true) 'Opção de desativação integra a configuração do worker'
    Assert-Ui (@($State.Results | Where-Object { $_.Acao -eq 'DESATIVAR' -and $_.Status -eq 'AGUARDANDO' }).Count -eq 2) 'Ativar opção atualiza a prévia mesmo sem CPF e sem CONCLUÍDO'
    Start-UiOperation
    Assert-Ui (-not $Ui.DisableUsersBox.IsEnabled) 'Opção de desativação fica bloqueada durante processamento'
    Wait-UiJob
    Assert-Ui (-not $State.LastError) "Simulação mista termina sem erro ($($State.LastError))"
    Assert-Ui ($Ui.PendingCount.Text -eq '2' -and $Ui.OkCount.Text -eq '1' -and $Ui.ApplyButton.Content -eq 'Aplicar todos (2)') 'Contadores incluem uma gravação CPF, uma desativação e uma conta já desativada'
    $disableDisplay = @($State.ResultView.SourceCollection | Where-Object { $_.Status -eq 'SIMULADO_DESATIVAR' })[0]
    Assert-Ui ($disableDisplay.AcaoTexto -eq 'Desativar' -and $disableDisplay.LoginEncontrado -eq 'pessoa.desativar.2') 'Tabela informa ação e login real encontrado no AD'
    $Ui.ResultsGrid.SelectedItem = $disableDisplay
    Assert-Ui ($Ui.DetailsText.Text -like '*BETIM.PMB*' -and $Ui.DetailsText.Text -like '*pessoa.desativar.2*') 'Detalhes da desativação identificam domínio e login'
    $Ui.StatusFilter.SelectedIndex = 1
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 2) 'Filtro Prontos reúne CPF e desativação'
    $Ui.StatusFilter.SelectedIndex = 2
    Assert-Ui ($Ui.ResultsGrid.Items.Count -eq 1 -and $Ui.ResultsGrid.Items[0].Status -eq 'JA_DESATIVADO') 'Filtro Conferidos inclui conta já desativada'
    Clear-UiFilters
    $fingerprintWithDisable = $State.Fingerprint
    $Ui.DisableUsersBox.IsChecked = $false
    Assert-Ui (-not $State.Fingerprint -and $Ui.StaleResultsBanner.Visibility -eq 'Visible' -and -not $Ui.ApplyButton.IsEnabled) 'Desligar desativação invalida a simulação antes de qualquer escrita'
    Assert-Ui (@($State.ResultView.SourceCollection | Where-Object { $_.Status -in @('SIMULADO_PREENCHER','SIMULADO_DESATIVAR') }).Count -eq 0) 'Invalidação remove prontidão dos dois tipos de ação'
    $Ui.DisableUsersBox.IsChecked = $true
    Start-UiOperation
    Wait-UiJob
    Assert-Ui ($State.Fingerprint -eq $fingerprintWithDisable -and $Ui.ApplyButton.IsEnabled) 'Nova simulação restabelece o plano com a opção habilitada'
    $Ui.DomainFilter.SelectedValue = 'SAUDE.BETIM'
    Start-UiOperation -Apply $true
    Wait-UiJob
    Assert-Ui (-not $State.LastError) "Aplicação mista termina sem erro ($($State.LastError))"
    Assert-Ui (@($State.Results | Where-Object { $_.Status -eq 'ATUALIZADO' }).Count -eq 1 -and @($State.Results | Where-Object { $_.Status -eq 'DESATIVADO' }).Count -eq 1) 'Aplicar todos executa CPF e desativação mesmo com filtro em outro domínio'
    $disabledResult = @($State.Results | Where-Object { $_.Status -eq 'DESATIVADO' })[0]
    Assert-Ui ($disabledResult.Dominio -eq 'BETIM.PMB' -and $disabledResult.ContaAtivaAnterior -eq $true -and $disabledResult.ContaAtivaAtual -eq $false) 'Aplicação confirma a mudança de estado somente no domínio indicado'
    Assert-Ui (@($State.Results | Where-Object { $_.Login -eq 'pessoa.saude' -and $_.Status -eq 'NAO_CONCLUIDO' }).Count -eq 1) 'Pessoa homônima no outro domínio segue fora da aplicação'
    $mixedReport = @(Import-Csv -LiteralPath $State.Report -Delimiter ';' -Encoding UTF8)
    Assert-Ui ($mixedReport.Count -eq 4 -and @($mixedReport | Where-Object { $_.Acao -eq 'DESATIVAR' -and $_.Status -eq 'DESATIVADO' }).Count -eq 1) 'Relatório misto preserva as quatro linhas, ação e estado confirmado'
    Clear-UiFilters
    $Ui.SessionLabel.Text = 'PRÉVIA DE TESTE · DADOS FICTÍCIOS'
    if ($Imagem) {
        Save-UiImage $Imagem
        $minimum = [IO.Path]::ChangeExtension($Imagem, 'minimo.png')
        Save-UiImage $minimum 1060 740
        $compact = [IO.Path]::ChangeExtension($Imagem, 'compacto.png')
        Save-UiImage $compact 1060 650
        $Ui.ConfigExpander.IsExpanded = $true
        $expanded = [IO.Path]::ChangeExtension($Imagem, 'config-expandida.png')
        Save-UiImage $expanded 1060 650
        Write-Host "Imagens: $Imagem, $minimum, $compact e $expanded"
    }
    Write-Host "$passed verificações de interface passaram. Nenhum AD real acessado."
} finally {
    $Timer.Stop()
    if ($State.Job) {
        $State.Job.Pipeline.Stop(); $State.Job.Pipeline.Dispose()
        if (Test-Path -LiteralPath $State.Job.Snapshot) { Remove-Item -LiteralPath $State.Job.Snapshot -Force }
    }
    $target = [IO.Path]::GetFullPath($temp)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cpf-ad-ui-test-'
    if ($target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $target -Recurse -Force }
    $Window.Close()
}
