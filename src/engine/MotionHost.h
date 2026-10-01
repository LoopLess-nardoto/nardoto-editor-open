#pragma once

#include <QHash>
#include <QSet>
#include <QImage>
#include <QMutex>
#include <QObject>
#include <QString>
#include <QWaitCondition>

class QFile;
class QLocalServer;
class QLocalSocket;
class QProcess;
class QThread;

namespace drift {

// Motion ao vivo: um clipe de imagem cujo caminho e um .html (composicao HyperFrames) nao e
// decodificado como imagem parada. O quadro do tempo t vem do motion-host, um processo Electron
// offscreen que abre a composicao e devolve o quadro exato daquele instante. Assim a composicao
// aparece no preview sem renderizar, e o export usa o mesmo motor.
//
// O editor nao embute navegador: conversa com o processo por um socket local (named pipe no
// Windows, Unix socket no Mac). Protocolo descrito em motion-host/main.js.
//
// frame() e chamado pelas threads do compositor (preview e export) e bloqueia ate o quadro chegar
// ou o prazo vencer. Todo o I/O mora numa thread propria, dona do socket e do processo.
class MotionHost : public QObject
{
    Q_OBJECT
public:
    static MotionHost &instance();

    static bool isMotionPath(const QString &path);

    // Quadro da composicao em `path` no tempo `sourceUs`, cabendo em maxWidth x maxHeight.
    // No preview o prazo e curto e, se o quadro novo nao chegou, volta o ultimo que chegou (o
    // playback nao pode travar). No modo exato (export) espera o quadro certo.
    QImage frame(const QString &path, qint64 sourceUs, int maxWidth, int maxHeight);

    // Duracao da composicao em microssegundos (0 se ainda nao abriu ou falhou).
    qint64 durationUs(const QString &path);

    // O Exporter liga isto na thread dele: ali todo quadro tem que ser o exato.
    static void setExactForCurrentThread(bool exact);

    // Cache em video (ver motion-host/main.js): o motor grava a composicao inteira em segundo
    // plano e, pronto o arquivo, preview e export leem ele como um video comum -- o export deixa
    // de esperar o navegador desenhar. Devolve o caminho do cache pronto ou vazio. Com pedir, a
    // primeira consulta fora do export manda gravar (no export a gravacao disputaria com ele).
    QString cachedVideo(const QString &path, bool pedir = true);
    // fps em que o cache e gravado: o do projeto (o compositor atualiza a cada quadro).
    static void setCacheFps(int fps);

    // Ultimo erro do motor (processo nao encontrado, composicao com defeito...), para a UI.
    QString lastError() const;

    // Falha de um quadro exato (export): devolve a mensagem e limpa. O Exporter confere a cada
    // quadro e para com erro -- nunca entrega o quadro anterior no lugar.
    QString takeExactFailure();

signals:
    // A composicao mudou no disco (o chat editou o index.html): o preview deve pedir o quadro de
    // novo. Emitido na thread do motor.
    void compositionChanged(const QString &path);

private:
    MotionHost();
    ~MotionHost() override;

    struct Comp
    {
        QString key;
        QString path;
        int maxWidth = 0;
        int maxHeight = 0;
        bool opened = false;
        bool failed = false;
        qint64 durationUs = 0;
        quint32 lastSeq = 0;      // ultimo pedido feito
        quint32 lastFrameSeq = 0; // seq do ultimo quadro recebido
        qint64 lastFrameUs = -1;  // tempo do ultimo quadro recebido
        quint32 errorSeq = 0;     // ultimo pedido que o motor respondeu com erro
        // Export: quadros adiantados (tempo da fonte -> quadro). O motor desenha N+1..N+K
        // enquanto o editor comprime N; o pedido seguinte ja encontra o quadro aqui.
        QHash<qint64, QImage> adiantados;
        QSet<qint64> pedidosAdiantados;
        qint64 ultimoExatoUs = -1;
        QString errorText;
        QImage lastFrame;
    };

    // Rodam na thread do motor.
    void ensureStarted();
    void onNewConnection();
    void onReadyRead();
    void handleJson(const QByteArray &body);
    void handleFrame(const QByteArray &body);
    void handleRingFrame(const QByteArray &body);
    void handlePixels(quint32 seq, int width, int height, int stride, const uchar *pixels);
    void sendLine(const QByteArray &json);
    void failAll(const QString &error);

    QString compKey(const QString &path, int maxWidth, int maxHeight) const;
    void agendarAdiantados(Comp &comp, const QString &key, const QString &path, int maxWidth,
                           int maxHeight, qint64 sourceUs);
    static constexpr int kAdiantados = 4;

    QThread *m_thread = nullptr;
    QLocalServer *m_server = nullptr;
    QLocalSocket *m_socket = nullptr;
    QProcess *m_process = nullptr;
    QByteArray m_buffer;
    // Aneis em arquivo do motor (caminho -> arquivo mapeado). Ver motion-host/main.js.
    QHash<QString, QFile *> m_rings;
    QList<QByteArray> m_pendingLines; // comandos feitos antes de o processo conectar
    bool m_ready = false;
    int m_restarts = 0;
    quint32 m_nextSeq = 0;
    struct Pending
    {
        QString key;
        qint64 sourceUs = 0;
        bool exact = false; // pedido do export/print: nunca e descartado pela limpeza do preview
    };
    QHash<quint32, Pending> m_seqKey; // seq do pedido -> composicao e tempo (o quadro so traz o seq)

    mutable QMutex m_mutex;
    QWaitCondition m_cond;
    QHash<QString, Comp> m_comps;
    QHash<QString, QString> m_cacheFiles; // "caminho|fps" -> arquivo do cache pronto
    QSet<QString> m_cachePedidos;         // "caminho|fps" ja pedidos (falha nao repete)
    QString m_lastError;
    QString m_exactFailure;
};

} // namespace drift
