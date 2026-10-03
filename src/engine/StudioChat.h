#pragma once

#include <QJsonObject>
#include <QString>

namespace drift {

// Coloca um texto na CAIXA do chat do Nardoto Studio (acao "chat_inserir" do MCP Studio), sem
// enviar: a pessoa revisa e manda. Porta 9879 (janela 1 do Studio) ou NARDOTO_STUDIO_PORTA.
// Devolve vazio quando deu certo, senao a mensagem de erro (Studio fechado, por exemplo).
// `imagem` (opcional): PNG que entra como anexo na caixa, junto do texto.
QString inserirNoChatDoStudio(const QString &texto, const QString &imagem = {});

// Chamada generica a uma acao do servidor local do Studio ({action, params} -> data). Bloqueia
// ate a resposta ou o prazo: chame fora da thread da interface quando a acao demora (busca,
// download). Em falha devolve objeto vazio e a mensagem em `erro`. `semConexao` (opcional) vira true
// quando o Studio nao foi alcancado (fechado, nao respondeu ao aperto de mao ou recusou), para quem
// precisa distinguir isso de um erro do proprio Studio sem comparar texto traduzido.
QJsonObject chamarStudio(const QString &acao, const QJsonObject &params, int prazoMs, QString *erro,
                         bool *semConexao = nullptr);

} // namespace drift
