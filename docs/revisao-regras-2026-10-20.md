# Revisão das regras — 20/10/2026

Foram corrigidas falhas na importação e na validação de destino e melhorada a indicação do estado da interface. O preenchimento de CPF continua restrito a campos vazios de usuários cuja unificação já está concluída na planilha. Uma atualização solicitada depois desta revisão acrescentou a opção explícita de desativação, descrita abaixo e no README.

| Condição | Comportamento final |
| --- | --- |
| CONCLUÍDO desmarcado ou não reconhecido em linha de CPF | Pular a linha |
| CPF não informado no CSV em linha de CPF | Pular a linha |
| Linha sem nome/domínio/login/CPF, mesmo com checkbox | Ignorar na importação |
| CPF inválido ou zeros iniciais perdidos | Sinalizar para revisão; não completar nem gravar |
| DOMÍNIO informado no CSV | Descobrir o controlador correspondente; não procurar o usuário no outro AD |
| Servidor manual de domínio diferente | Bloquear antes da busca do usuário |
| Login presente | Buscar o login exato e conferir o nome completo |
| Login ausente | Exigir um único resultado pelo nome completo |
| Nome/login não conferem ou há homônimos | Não gravar |
| NOVO LOGIN = desativar, opção desligada | Pular e informar que a desativação não está habilitada |
| NOVO LOGIN = desativar, opção ligada | Identificar nome completo único somente no domínio da linha, independentemente de CONCLUÍDO e CPF; desativar apenas se ativo |
| Conta já desativada | Informar o estado sem nova escrita |
| NOVO LOGIN contém excluir/remover | Pular; a automação não executa essas ações |
| Mesmo GUID com ações de CPF e desativação | Bloquear as duas ações para revisão |
| CPF no AD já preenchido | Preservar; indicar se confere ou diverge |
| CPF no AD vazio | Gravar somente os 11 dígitos e confirmar por releitura |
| Mesmo GUID com CPFs diferentes no CSV | Bloquear todo o grupo |
| Mesmo GUID e CPF repetidos | Planejar somente a primeira linha e identificar as repetições |
| GUIDs distintos com CPF igual | Manter contas independentes |
| Arquivo ou configuração mudou após simular | Invalidar o plano e exigir nova simulação |

O parser agora rejeita cabeçalhos que se tornam iguais após normalização, como CONCLUÍDO/CONCLUIDO ou CPF/“ CPF ”. Antes, a segunda coluna podia substituir silenciosamente a primeira. O arquivo inteiro é validado antes de retornar registros; aspas abertas ou quantidade incorreta de campos não permitem processar parcialmente o CSV.

A validação do controlador usa o domínio real informado pelo RootDSE e o cache considera domínio e servidor. Isso impede que uma configuração manual errada reutilize um controlador de outro domínio. O executor também confere os dados e a conclusão de todos os registros do plano antes de obter o adaptador do AD.

Na interface, falha ao carregar um CSV limpa a seleção anterior. Alterações no CSV ou na configuração retiram a indicação de “pronto” e exibem um aviso de resultados desatualizados. Erros de execução mostram a causa e mantêm a aplicação bloqueada até uma nova simulação válida. Busca, filtros e ordenação continuam apenas visuais, e o botão informa o total do plano.

Validação após a atualização: 29 cenários do motor, 6 do executor/plano, 24 de desativação e 70 verificações de interface em Windows PowerShell 5.1 e PowerShell 7.6.3. Os testes usam dados fictícios e comandos AD falsos. Nenhum usuário real foi consultado ou alterado nesta revisão. As imagens da interface normal e compacta foram inspecionadas.
