#include "StudioChat.h"

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QRandomGenerator>
#include <QTcpSocket>

namespace drift {

namespace {

constexpr int kPrazoMs = 2000;

// Le exatamente n bytes (o que sobrou do handshake vem primeiro).
bool lerExato(QTcpSocket &s, QByteArray &sobra, qsizetype n, QByteArray *saida, int prazoMs = kPrazoMs)
{
    while (sobra.size() < n) {
        if (!s.waitForReadyRead(prazoMs))
            return false;
        sobra += s.readAll();
    }
    *saida = sobra.left(n);
    sobra.remove(0, n);
    return true;
}

// Quadro de texto do cliente: o protocolo exige mascara em tudo que o cliente manda.
QByteArray quadro(quint8 opcode, const QByteArray &dados)
{
    QByteArray f;
    f.append(char(0x80 | opcode));
    const qsizetype n = dados.size();
    if (n < 126) {
        f.append(char(0x80 | n));
    } else if (n < 65536) {
        f.append(char(0x80 | 126));
        f.append(char((n >> 8) & 0xff));
        f.append(char(n & 0xff));
    } else {
        f.append(char(0x80 | 127));
        for (int i = 7; i >= 0; --i)
            f.append(char((quint64(n) >> (8 * i)) & 0xff));
    }
    const quint32 m = QRandomGenerator::global()->generate();
    const char mascara[4] = {char(m >> 24), char(m >> 16), char(m >> 8), char(m)};
    f.append(mascara, 4);
    for (qsizetype i = 0; i < n; ++i)
        f.append(char(dados.at(i) ^ mascara[i % 4]));
    return f;
}

} // namespace

// WebSocket minimo: o Qt deste build nao tem o QtWebSockets, e uma mensagem so nao justifica a
// dependencia. Sem cabecalho Origin de proposito: o Studio recusa chat_inserir vindo de pagina web.
QString inserirNoChatDoStudio(const QString &texto, const QString &imagem)
{
    QString erro;
    chamarStudio(QStringLiteral("chat_inserir"),
                 QJsonObject{{QStringLiteral("texto"), texto}, {QStringLiteral("imagem"), imagem}},
                 kPrazoMs, &erro);
    return erro;
}

QJsonObject chamarStudio(const QString &acao, const QJsonObject &params, int prazoMs, QString *erroSaida,
                         bool *semConexao)
{
    if (semConexao)
        *semConexao = false;
    const auto falha = [erroSaida](const QString &msg) {
        if (erroSaida)
            *erroSaida = msg;
        return QJsonObject{};
    };
    if (erroSaida)
        erroSaida->clear();

    bool ok = false;
    int porta = qEnvironmentVariableIntValue("NARDOTO_STUDIO_PORTA", &ok);
    if (!ok || porta <= 0)
        porta = 9879;

    QTcpSocket s;
    s.connectToHost(QStringLiteral("127.0.0.1"), quint16(porta));
    if (!s.waitForConnected(kPrazoMs)) {
        if (semConexao)
            *semConexao = true;
        return falha(QObject::tr("O Nardoto Studio não está aberto."));
    }

    QByteArray chave(16, Qt::Uninitialized);
    for (char &c : chave)
        c = char(QRandomGenerator::global()->bounded(256));
    s.write("GET / HTTP/1.1\r\nHost: 127.0.0.1:" + QByteArray::number(porta)
            + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: "
            + chave.toBase64() + "\r\nSec-WebSocket-Version: 13\r\n\r\n");

    QByteArray sobra;
    while (!sobra.contains("\r\n\r\n")) {
        if (!s.waitForReadyRead(kPrazoMs)) {
            if (semConexao)
                *semConexao = true;
            return falha(QObject::tr("O Nardoto Studio não respondeu."));
        }
        sobra += s.readAll();
    }
    const qsizetype fimCab = sobra.indexOf("\r\n\r\n") + 4;
    if (!sobra.startsWith("HTTP/1.1 101")) {
        if (semConexao)
            *semConexao = true;
        return falha(QObject::tr("O Nardoto Studio recusou a conexão."));
    }
    sobra.remove(0, fimCab);

    const QJsonObject pedido{{QStringLiteral("id"), 1},
                             {QStringLiteral("action"), acao},
                             {QStringLiteral("params"), params}};
    s.write(quadro(0x1, QJsonDocument(pedido).toJson(QJsonDocument::Compact)));

    // Resposta: quadros do servidor sem mascara. Ping (0x9) e outros controles sao pulados; um
    // texto pode vir em fragmentos (FIN=0 + continuacao 0x0) e e juntado ate o FIN.
    QByteArray corpo;
    for (;;) {
        QByteArray cab;
        if (!lerExato(s, sobra, 2, &cab, prazoMs))
            return falha(QObject::tr("O Nardoto Studio não respondeu a tempo."));
        const bool fim = quint8(cab.at(0)) & 0x80;
        const quint8 op = quint8(cab.at(0)) & 0x0f;
        quint64 n = quint8(cab.at(1)) & 0x7f;
        if (n >= 126) {
            QByteArray ext;
            if (!lerExato(s, sobra, n == 126 ? 2 : 8, &ext, prazoMs))
                return falha(QObject::tr("O Nardoto Studio não respondeu a tempo."));
            n = 0;
            for (char c : ext)
                n = (n << 8) | quint8(c);
        }
        QByteArray dados;
        if (n > (16u << 20) || !lerExato(s, sobra, qsizetype(n), &dados, prazoMs))
            return falha(QObject::tr("O Nardoto Studio não respondeu a tempo."));
        if (op == 0x8)
            return falha(QObject::tr("O Nardoto Studio fechou a conexão."));
        if (op != 0x1 && op != 0x0)
            continue;
        corpo += dados;
        if (fim)
            break;
    }

    s.write(quadro(0x8, {}));
    s.waitForBytesWritten(500);
    s.disconnectFromHost();

    const QJsonObject resposta = QJsonDocument::fromJson(corpo).object();
    if (resposta.value(QStringLiteral("success")).toBool())
        return resposta.value(QStringLiteral("data")).toObject();
    const QString erro = resposta.value(QStringLiteral("error")).toString();
    return falha(erro.isEmpty() ? QObject::tr("O Nardoto Studio não aceitou o pedido.") : erro);
}

} // namespace drift
