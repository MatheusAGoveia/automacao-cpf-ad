# Conferir CPF e desativar usuários no Active Directory a partir de CSV

A automação lê o CSV baixado do Google Sheets. Para preencher CPF, processa somente usuários marcados como **CONCLUÍDO** com CPF informado: confere nome completo e login no AD e preenche apenas o atributo **CPF** vazio. A opção **Permitir desativação de usuários** habilita uma segunda ação para linhas cujo **NOVO LOGIN** seja `desativar`.

CPF existente nunca é substituído. Na desativação, CONCLUÍDO e CPF não são exigidos: a conta é identificada pelo nome completo, somente no domínio da coluna **DOMÍNIO**. Se a mesma pessoa existir nos dois domínios, apenas a conta no domínio informado será processada. Conta já desativada não recebe nova alteração. A automação não unifica, renomeia ou exclui contas e não altera a planilha.

## Usar pela interface

Dê dois cliques em **`Abrir-Interface.cmd`**. A janela utiliza os componentes do Windows e não exige instalação de bibliotecas adicionais.

1. Clique em **Selecionar CSV** e escolha o arquivo baixado. A tabela exibe a prévia sem consultar o AD.
2. A coluna **DOMÍNIO** do CSV identifica automaticamente o destino de cada usuário: `BETIM.PMB` vai para Betim e `SAÚDE.BETIM` vai para Saúde. Deixe **Servidor manual (opcional)** vazio para a descoberta automática.
3. Se também quiser processar `desativar`, marque **Permitir desativação de usuários**. Ela começa desligada a cada abertura. Clique em **Simular no AD**. O Windows localiza um controlador gravável com ADWS para cada domínio e a tela mostra **Controlador localizado**. Confira **Ação prevista**, **Login encontrado** e **Domínio** de cada conta. A janela continua respondendo enquanto a consulta acontece.
4. Use **Buscar nome, login ou CPF**, **Domínio** e **Situação** para localizar registros. A busca aceita nome sem acento e CPF sem pontuação. Ordene clicando no cabeçalho da coluna ou usando **Ordenar por** e **A–Z/Z–A**. **Limpar** restaura a visualização completa.
5. Clique em **Aplicar todos (N)** para executar as N ações prontas na simulação: preencher CPF ou desativar conta. A mensagem de conclusão da simulação e a dica do botão separam os totais por ação. Os filtros alteram somente a visualização. O botão só fica disponível depois de uma simulação válida; as contas e seus estados são conferidos novamente antes de alterar o AD.
6. Clique em **Abrir relatório** para abrir o CSV com todos os resultados.

A tabela mantém espaço reservado mesmo em janelas menores. As configurações começam recolhidas e a área superior tem sua própria rolagem quando necessário, para não esconder os usuários.

**Todos os domínios** retira apenas a restrição por domínio; busca e situação continuam valendo. O rodapé informa quantos filtros estão ativos. Se a tabela ficar vazia, a mensagem central mostra esses filtros. Clique em **Limpar** para voltar a todos os registros.

Se mudar o arquivo, a codificação, o atributo, os servidores ou a permissão de desativação, é necessário simular novamente. A tela identifica os resultados anteriores como desatualizados e retira a indicação de usuários prontos. Mudanças externas no CSV também são detectadas; no clique de aplicação, o conteúdo completo é conferido novamente. Se um novo CSV for inválido, o arquivo anterior deixa de estar selecionado para evitar execução com dados antigos.

Cada execução usa uma cópia temporária do CSV; mudanças no original durante o processamento não modificam o trabalho em curso. A cópia é removida ao terminar. A janela aguarda a operação terminar antes de permitir o fechamento.

Não é necessário informar os servidores manualmente. A descoberta depende de acesso à rede/DNS dos domínios. Se um domínio não puder ser localizado, suas linhas são sinalizadas; o programa não procura esses usuários no outro domínio nem usa o domínio do computador como alternativa.

## 1. Descoberta dos servidores e configuração opcional

Os servidores vazios em `dominios.json` significam **descobrir automaticamente**, também no uso pelo terminal. A associação vem da coluna DOMÍNIO do CSV. Caixa e acentos são normalizados: `SAÚDE.BETIM` e `SAUDE.BETIM` usam `saude.betim`; `BETIM.PMB` usa `betim.pmb`.

```json
{
  "AtributoCpf": "CPF",
  "FormatoCpf": "Numeros",
  "Dominios": {
    "BETIM.PMB": "",
    "SAÚDE.BETIM": ""
  }
}
```

O DC Locator confirma que o controlador encontrado pertence ao domínio solicitado. A descoberta é reutilizada durante a mesma execução, e busca, releitura e gravação ficam no mesmo controlador. A interface usa os GUIDs da simulação para conferir os usuários na aplicação mesmo que o DC Locator selecione outro controlador do mesmo domínio.

Como opção, preencha um servidor conhecido na interface e salve, ou edite o JSON. Um valor manual substitui a descoberta desse domínio, mas o programa confere se o controlador pertence ao domínio da linha antes de buscar usuários. Use somente o endereço do servidor, sem `https://` e sem barras. Para consultar um servidor conhecido no programa **Usuários e Computadores do Active Directory**, clique com o botão direito no domínio e abra **Alterar Controlador de Domínio**, sem alterar a seleção.

`AtributoCpf` corresponde ao nome LDAP mostrado no Editor de Atributos, **CPF** na imagem fornecida. O script verifica se ele existe e aceita um único valor. **Novas inserções no AD usam sempre 11 dígitos, sem pontos, traço ou espaços**, como `00000000191`. O CSV pode continuar com CPF formatado. A interface salva `FormatoCpf: Numeros`; configurações antigas com `Formatado` também gravam somente números. CPFs já preenchidos no AD continuam preservados.

## 2. Baixar o CSV

No Google Sheets, selecione a aba correta e use **Arquivo → Fazer download → Valores separados por vírgulas (.csv)**. Salve como `usuarios.csv` nesta pasta. Não abra e salve pelo Excel antes de executar, para preservar zeros à esquerda dos CPFs.

Cabeçalhos obrigatórios, como na imagem:

```text
NOME COMPLETO | DOMINIO | NOVO LOGIN | CPF | CONCLUÍDO
```

As demais colunas são ignoradas. O script aceita vírgula, ponto e vírgula ou tabulação como separador, UTF-8 com ou sem BOM e título antes do cabeçalho. Vírgulas e quebras de linha dentro de campos entre aspas são aceitas. O arquivo inteiro é validado antes de processar qualquer usuário: cabeçalhos equivalentes duplicados, aspas abertas e linhas com campos a mais ou a menos são rejeitados.

Linhas sem nome, domínio, login e CPF são ignoradas mesmo que contenham apenas um checkbox. Cada número de registro do relatório preserva a ordem original do CSV, contando cabeçalho e título; campos com quebras de linha podem fazer esse número diferir da linha física do arquivo.

## 3. Simular

Use Windows PowerShell 5.1 ou PowerShell 7 no Windows, com o módulo **ActiveDirectory/RSAT**, conexão à rede do AD e sua conta com acesso aos domínios. A execução utiliza a conta Windows da sessão; nenhuma senha é salva.

Nesta pasta, execute:

```powershell
.\Atualizar-CpfAD.ps1 -Csv .\usuarios.csv
```

Se o Windows bloquear a execução de scripts, use este comando, que define a política somente para o processo iniciado:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Atualizar-CpfAD.ps1 -Csv .\usuarios.csv
```

Para aplicar por esse comando, acrescente `-Aplicar` ao final. A política permanente do computador não é modificada.

Isso consulta o AD e gera um CSV em `relatorios`, sem alterar contas. Veja as linhas `SIMULADO_PREENCHER` e revise os demais resultados. Cada execução cria um novo relatório.

Para incluir desativações na simulação pelo terminal, use a opção explícita:

```powershell
.\Atualizar-CpfAD.ps1 -Csv .\usuarios.csv -DesativarUsuarios
```

Confira as linhas `SIMULADO_DESATIVAR` e o domínio de cada conta antes de repetir o comando com `-Aplicar`. Essa ação usa [Disable-ADAccount](https://learn.microsoft.com/en-us/powershell/module/activedirectory/disable-adaccount) e exige permissão para desativar as contas correspondentes.

## 4. Aplicar

```powershell
.\Atualizar-CpfAD.ps1 -Csv .\usuarios.csv -Aplicar
```

A conta precisa ter permissão para escrever no atributo CPF dos usuários correspondentes. O script consulta novamente o usuário antes da gravação e confirma o valor depois, sempre no mesmo controlador. Utiliza uma operação de adição em atributo de valor único; se outro processo preencher o atributo antes, a operação não substitui o valor existente. Falhas individuais são registradas, e os demais usuários continuam. Falha de escrita do relatório interrompe novas gravações.

Se o CSV veio de outro programa em Windows-1252:

```powershell
.\Atualizar-CpfAD.ps1 -Csv .\usuarios.csv -Codificacao windows-1252
```

## Regras de identificação

- Para preencher CPF, `CONCLUÍDO` aceita `TRUE`, `VERDADEIRO`, `1`, `SIM` ou `X`, sem diferença de maiúsculas. Outros valores são pulados.
- CPF: aceita 11 dígitos ou `000.000.000-00`; verifica os dígitos verificadores e rejeita valores inválidos, sem completar zeros perdidos.
- Com login: busca somente `sAMAccountName` exato e exige que `Name` ou `DisplayName` corresponda ao nome completo da planilha. Se o novo login ainda não foi aplicado no AD, sinaliza para revisão, sem tentar outra conta pelo nome.
- Sem login: busca `Name` ou `DisplayName` exato e exige um único resultado. Não procura por partes do nome.
- A conferência do nome ignora diferenças de acento, caixa e espaços repetidos; abreviações e sobrenomes diferentes bloqueiam a gravação.
- `desativar` em NOVO LOGIN, com a opção habilitada, identifica um único nome completo no domínio da linha e desativa apenas se a conta estiver ativa. Aceita maiúsculas e espaços nas extremidades, mas exige o conteúdo integral `desativar`; expressões como `não desativar` não acionam a função. CONCLUÍDO e CPF não são exigidos para essa ação.
- A desativação começa desligada a cada abertura. Com a opção desligada, linhas `desativar` são puladas. `excluir` e `remover` continuam como ações não suportadas; nenhuma conta é excluída.
- Homônimos dentro do domínio indicado são sinalizados para revisão. Não existe busca alternativa no outro domínio.
- CPFs diferentes em linhas resolvidas para o mesmo objeto do AD bloqueiam todas essas linhas antes de qualquer gravação.
- Linhas com o mesmo objeto do AD e a mesma ação são repetidas: somente a primeira fica apta e as demais apontam para ela no relatório. Na ação de CPF, os valores também precisam ser iguais. Objetos distintos com CPF igual continuam independentes.
- Se o mesmo objeto receber ações de CPF e desativação no CSV, as linhas ficam em conflito para revisão.
- A aplicação da interface confere nome, login, domínio, CPF, conclusão original, ação e identificação dos registros contra a simulação, além de validar novamente o GUID e o login encontrado no AD.

## Resultados

| Status | Significado |
| --- | --- |
| SIMULADO_PREENCHER | CPF vazio que seria preenchido; nenhuma escrita |
| SIMULADO_DESATIVAR | Conta ativa que seria desativada; nenhuma escrita |
| DESATIVADO | Desativação enviada e confirmada por releitura |
| JA_DESATIVADO | Conta já estava desativada; nenhuma escrita |
| DESATIVACAO_DESLIGADA | A opção de desativação está desligada; linha pulada |
| ATUALIZADO | CPF gravado e confirmado pela releitura |
| CPF_JA_CONFERE | CPF já corresponde ao CSV; nenhuma escrita |
| CPF_AD_DIVERGENTE | CPF existente diferente ou em formato inesperado; preservado |
| NAO_CONCLUIDO | Na tela: Pendente na planilha. CONCLUÍDO está desmarcado ou tem valor não reconhecido; a linha é pulada |
| SEM_CPF_PLANILHA | CPF não informado no CSV; a linha é pulada |
| CPF_INVALIDO / SEM_NOME | Dados insuficientes ou inválidos |
| DOMINIO_NAO_LOCALIZADO | A descoberta não encontrou/confirmou um controlador para o domínio; nenhuma busca em outro domínio |
| SEM_DOMINIO | A linha não informa o domínio do usuário no CSV |
| USUARIO_NAO_ENCONTRADO / USUARIO_AMBIGUO | Não foi possível identificar um único usuário |
| NOME_DIVERGENTE / LOGIN_DIVERGENTE / IDENTIDADE_ALTERADA | Identidade não conferiu; nenhuma gravação |
| CONFLITO_CSV | Mais de um CPF para o mesmo usuário; grupo bloqueado |
| CONFLITO_ACOES | CPF e desativação apontam para a mesma conta; grupo bloqueado |
| LINHA_REPETIDA | Mesmo objeto do AD e ação de uma linha anterior; processado apenas pela linha principal |
| ACAO_NAO_SUPORTADA | Na tela: Login contém uma ação. NOVO LOGIN contém excluir ou remover; a linha é pulada |
| ERRO_CONSULTA / ERRO_PROCESSAMENTO | Erro descrito na coluna Detalhe |
| GRAVACAO_INICIADA / GRAVADO_SEM_CONFIRMACAO | Operação interrompida ou sem confirmação; confira o usuário antes de repetir |
| DESATIVACAO_INICIADA / DESATIVADO_SEM_CONFIRMACAO | Desativação interrompida ou sem confirmação; confira a conta antes de repetir |
| PLANEJADO | Identificação concluída, mas execução interrompida antes de processar esta linha |

Os relatórios registram ação, conclusão original da planilha, domínio, login encontrado e estados da conta antes/depois, além de nomes, CPFs e identificadores do AD. Mantenha-os em pasta com o mesmo acesso restrito da planilha original. O Git ignora os relatórios e arquivos CSV; somente os exemplos fictícios na pasta `exemplos` são incluídos.

## Testes locais

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Testar-Automacao.ps1
pwsh.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Testar-Automacao.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Testar-Plano.ps1
pwsh.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Testar-Plano.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Testar-Desativacao.ps1
pwsh.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Testar-Desativacao.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -STA -File .\tests\Testar-Interface.ps1
pwsh.exe -NoProfile -ExecutionPolicy RemoteSigned -STA -File .\tests\Testar-Interface.ps1
```

Os testes usam AD simulado, com dados fictícios; não consultam nem alteram contas reais. A validação no ambiente real depende dos servidores e do CSV reais.

Referências técnicas: [Get-ADDomainController](https://learn.microsoft.com/en-us/powershell/module/activedirectory/get-addomaincontroller), [DC Locator](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/dc-locator), [Get-ADUser](https://learn.microsoft.com/en-us/powershell/module/activedirectory/get-aduser), [Set-ADUser, parâmetro Add](https://learn.microsoft.com/en-us/powershell/module/activedirectory/set-aduser#-add) e [Get-ADObject](https://learn.microsoft.com/en-us/powershell/module/activedirectory/get-adobject).
