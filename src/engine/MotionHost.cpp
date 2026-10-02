#include "MotionHost.h"
#include "AddonRegistry.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QElapsedTimer>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QProcess>
#include <QDateTime>
#include <QFile>
#include <QProcessEnvironment>
#include <QStandardPaths>
#include <QThread>
#include <QtEndian>

#include <atomic>

namespace drift {

namespace {

thread_local bool t_exact = false;
std::atomic<int> g_cacheFps{30};

// Diario do motor em %TEMP%/nardoto-motion.log: o editor e um app de janela, os qWarning somem, e
// "o motion ficou preto" so se explica olhando o que o processo auxiliar disse.
void motionLog(const QString &line)
{
    static QMutex mutex;
    QMutexLocker lock(&mutex);
    QFile file(QDir(QStandardPaths::writableLocation(QStandardPaths::TempLocation))
                   .filePath(QStringLiteral("nardoto-motion.log")));
    if (!file.open(QIODevice::Append | QIODevice::Text))
        return;
    file.write(QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss.zzz ")).toUtf8());
    file.write(line.toUtf8());
    file.write("\n");
}

constexpr int kHeaderBytes = 16;
constexpr quint32 kTypeJson = 1;
constexpr quint32 kTypeFrame = 2;
constexpr quint32 kTypeRingFrame = 3; // quadro numa vaga do anel em arquivo
constexpr int kFrameMetaBytes = 24;
constexpr int kMaxRestarts = 3;

// Sobe a partir de `start` procurando `rel`: o exe de dev mora em build-dev/Release, o
// motion-host na raiz do repo e o Electron no node_modules do Studio, uma pasta acima.
QString findUp(const QString &start, const QString &rel)
{
    QDir dir(start);
    for (int i = 0; i < 6; ++i) {
        const QString candidate = dir.filePath(rel);
        if (QFileInfo::exists(candidate))
            return QDir::cleanPath(candidate);
        if (!dir.cdUp())
            break;
    }
    return {};
}

// No app instalado o motor nao vem no instalador: e um extra da loja (tipo "motion-engine") com
// main.js, o Electron em electron/ e o ffmpeg. Vale o primeiro extra instalado que tiver o arquivo.
QString fromMotionAddon(const QString &rel)
{
    for (const QString &root : drift::addon::addonRootsForKind(QStringLiteral("motion-engine"))) {
        const QString candidate = QDir(root).filePath(rel);
        if (QFileInfo::exists(candidate))
            return QDir::cleanPath(candidate);
    }
    return {};
}

QString motionHostScript()
{
    const QString fromEnv = qEnvironmentVariable("NARDOTO_MOTION_HOST");
    if (!fromEnv.isEmpty() && QFileInfo::exists(fromEnv))
        return fromEnv;
    const QString dev = findUp(QCoreApplication::applicationDirPath(), QStringLiteral("motion-host/main.js"));
    return dev.isEmpty() ? fromMotionAddon(QStringLiteral("main.js")) : dev;
}

QString electronBinary()
{
    const QString fromEnv = qEnvironmentVariable("NARDOTO_ELECTRON");
    if (!fromEnv.isEmpty() && QFileInfo::exists(fromEnv))
        return fromEnv;
    const QString appDir = QCoreApplication::applicationDirPath();
#ifdef Q_OS_WIN
    const QStringList rels{QStringLiteral("motion-host/electron/electron.exe"),
                           QStringLiteral("node_modules/electron/dist/electron.exe")};
#elif defined(Q_OS_MACOS)
    const QStringList rels{QStringLiteral("motion-host/Electron.app/Contents/MacOS/Electron"),
                           QStringLiteral("node_modules/electron/dist/Electron.app/Contents/MacOS/Electron")};
#else
    const QStringList rels{QStringLiteral("motion-host/electron/electron"),
                           QStringLiteral("node_modules/electron/dist/electron")};
#endif
    for (const QString &rel : rels) {
        const QString found = findUp(appDir, rel);
        if (!found.isEmpty())
            return found;
    }
#ifdef Q_OS_WIN
    return fromMotionAddon(QStringLiteral("electron/electron.exe"));
#elif defined(Q_OS_MACOS)
    return fromMotionAddon(QStringLiteral("Electron.app/Contents/MacOS/Electron"));
#else
    return fromMotionAddon(QStringLiteral("electron/electron"));
#endif
}

} // namespace

// O export pede t = llround(i * 1e6 / fps); o adiantado e calculado somando o passo, e os dois
// diferem em 1-4 us por arredondamento (66666 x 66667). Casar pelo numero exato nunca casava e
// cada quadro ainda esperava os adiantados inuteis na fila (44 s em 192 s, medido). 50 us e
// 1/600 de quadro: o mesmo instante para qualquer animacao.
constexpr qint64 kPertoUs = 50;

template <typename Container>
auto acharPerto(Container &c, qint64 us)
{
    for (auto it = c.begin(); it != c.end(); ++it) {
        if (qAbs(qint64(*it - us)) <= kPertoUs)
            return it;
    }
    return c.end();
}

QHash<qint64, QImage>::iterator acharPertoImg(QHash<qint64, QImage> &c, qint64 us)
{
    for (auto it = c.begin(); it != c.end(); ++it) {
        if (qAbs(it.key() - us) <= kPertoUs)
            return it;
    }
    return c.end();
}

MotionHost &MotionHost::instance()
{
    static MotionHost host;
    return host;
}

MotionHost::MotionHost()
{
    m_thread = new QThread;
    m_thread->setObjectName(QStringLiteral("MotionHost"));
    moveToThread(m_thread);
    m_thread->start();
}

MotionHost::~MotionHost()
{
    // Estatico: morre no fim do programa. O processo filho cai sozinho quando o socket fecha.
    m_thread->quit();
    m_thread->wait(2000);
}

bool MotionHost::isMotionPath(const QString &path)
{
    return path.endsWith(QStringLiteral(".html"), Qt::CaseInsensitive)
           || path.endsWith(QStringLiteral(".htm"), Qt::CaseInsensitive);
}

void MotionHost::setExactForCurrentThread(bool exact)
{
    t_exact = exact;
}

void MotionHost::setCacheFps(int fps)
{
    if (fps > 0)
        g_cacheFps.store(fps);
}

QString MotionHost::cachedVideo(const QString &path, bool pedir)
{
    if (!isMotionPath(path) || qEnvironmentVariableIsSet("NARDOTO_MOTION_SEM_CACHE"))
        return {};
    const int fps = g_cacheFps.load();
    const QString chave = path + QLatin1Char('|') + QString::number(fps);
    {
        QMutexLocker lock(&m_mutex);
        if (const auto it = m_cacheFiles.constFind(chave); it != m_cacheFiles.constEnd())
            return it.value();
        if (!pedir || t_exact || m_restarts > kMaxRestarts || m_cachePedidos.contains(chave))
            return {};
        m_cachePedidos.insert(chave);
    }
    motionLog(QStringLiteral("pedindo cache: ") + chave);
    QMetaObject::invokeMethod(this, [this, path, fps] {
        ensureStarted();
        // 3840x2160 e so o teto: o motor nunca grava maior que a resolucao da composicao.
        const QJsonObject cmd{{QStringLiteral("cmd"), QStringLiteral("cache")},
                              {QStringLiteral("pasta"), path},
                              {QStringLiteral("largura"), 3840},
                              {QStringLiteral("altura"), 2160},
                              {QStringLiteral("fps"), fps}};
        sendLine(QJsonDocument(cmd).toJson(QJsonDocument::Compact));
    }, Qt::QueuedConnection);
    return {};
}

QString MotionHost::lastError() const
{
    QMutexLocker lock(&m_mutex);
    return m_lastError;
}

QString MotionHost::compKey(const QString &path, int maxWidth, int maxHeight) const
{
    return QStringLiteral("%1@%2x%3").arg(path).arg(maxWidth).arg(maxHeight);
}

qint64 MotionHost::durationUs(const QString &path)
{
    QMutexLocker lock(&m_mutex);
    for (const Comp &comp : std::as_const(m_comps)) {
        if (comp.path == path && comp.durationUs > 0)
            return comp.durationUs;
    }
    return 0;
}

QImage MotionHost::frame(const QString &path, qint64 sourceUs, int maxWidth, int maxHeight)
{
    if (!isMotionPath(path) || maxWidth <= 0 || maxHeight <= 0)
        return {};

    const bool exact = t_exact;
    const QString key = compKey(path, maxWidth, maxHeight);
    bool needOpen = false;
    quint32 seq = 0;
    {
        QMutexLocker lock(&m_mutex);
        if (m_restarts > kMaxRestarts)
            return {};
        auto it = m_comps.find(key);
        if (it == m_comps.end()) {
            Comp comp;
            comp.key = key;
            comp.path = path;
            comp.maxWidth = maxWidth;
            comp.maxHeight = maxHeight;
            it = m_comps.insert(key, comp);
            needOpen = true;
        }
        if (it->failed)
            return {};
        // Mesmo tempo do ultimo quadro (pausado, recomposicao sem mudanca): nada a pedir.
        if (!it->lastFrame.isNull() && it->lastFrameUs == sourceUs && it->lastFrameSeq == it->lastSeq)
            return it->lastFrame;
        if (exact) {
            // Ja pedido adiantado e a caminho: espera ele, sem pedir de novo.
            if (acharPertoImg(it->adiantados, sourceUs) == it->adiantados.end()
                && acharPerto(it->pedidosAdiantados, sourceUs) != it->pedidosAdiantados.end()) {
                QDeadlineTimer prazo(20000);
                while (true) {
                    it = m_comps.find(key);
                    if (it == m_comps.end() || it->failed
                        || acharPertoImg(it->adiantados, sourceUs) != it->adiantados.end()
                        || acharPerto(it->pedidosAdiantados, sourceUs) == it->pedidosAdiantados.end())
                        break;
                    if (!m_cond.wait(&m_mutex, prazo))
                        break;
                }
                if (it == m_comps.end()) {
                    m_exactFailure = tr("O motor de motion reiniciou durante o export");
                    return {};
                }
            }
            // Quadro que ja veio adiantado: entrega sem esperar o motor.
            if (auto pronto = acharPertoImg(it->adiantados, sourceUs); pronto != it->adiantados.end()) {
                const QImage img = pronto.value();
                it->adiantados.erase(pronto);
                if (img.isNull()) {
                    m_exactFailure = it->errorText.isEmpty()
                                         ? tr("O quadro de %1 s do motion não chegou").arg(double(sourceUs) / 1e6, 0, 'f', 3)
                                         : it->errorText;
                    return {};
                }
                agendarAdiantados(*it, key, path, maxWidth, maxHeight, sourceUs);
                return img;
            }
        }
        seq = ++m_nextSeq;
        it->lastSeq = seq;
        m_seqKey.insert(seq, Pending{key, sourceUs, exact});
        if (exact && qEnvironmentVariableIsSet("NARDOTO_MOTION_TRACE"))
            motionLog(QStringLiteral("pedido direto seq=%1 t=%2").arg(seq).arg(sourceUs));
    }

    if (needOpen)
        motionLog(QStringLiteral("abrindo composicao: ") + key);
    const double t = double(qMax<qint64>(0, sourceUs)) / 1e6;
    if (exact) {
        QMutexLocker lock(&m_mutex);
        if (auto it = m_comps.find(key); it != m_comps.end())
            agendarAdiantados(*it, key, path, maxWidth, maxHeight, sourceUs);
    }
    QMetaObject::invokeMethod(this, [this, key, path, maxWidth, maxHeight, needOpen, seq, t, exact] {
        ensureStarted();
        if (needOpen) {
            QJsonObject open{{QStringLiteral("cmd"), QStringLiteral("abrir")},
                             {QStringLiteral("id"), key},
                             {QStringLiteral("pasta"), path},
                             {QStringLiteral("larguraMax"), maxWidth},
                             {QStringLiteral("alturaMax"), maxHeight}};
            sendLine(QJsonDocument(open).toJson(QJsonDocument::Compact));
        }
        QJsonObject req{{QStringLiteral("cmd"), QStringLiteral("quadro")},
                        {QStringLiteral("id"), key},
                        {QStringLiteral("t"), t},
                        {QStringLiteral("seq"), qint64(seq)},
                        {QStringLiteral("exato"), exact}};
        sendLine(QJsonDocument(req).toJson(QJsonDocument::Compact));
    }, Qt::QueuedConnection);

    QElapsedTimer waited;
    waited.start();
    QMutexLocker lock(&m_mutex);
    auto found = m_comps.constFind(key);
    if (found == m_comps.constEnd())
        return {};
    // Prazo: o export espera o quadro certo; o preview so espera muito na primeira vez (o
    // processo e a composicao abrindo) e depois devolve o ultimo quadro que chegou, para o
    // playback nao travar enquanto o motor alcanca.
    const int waitMs = exact ? 20000 : (found->lastFrame.isNull() ? 6000 : 120);
    QDeadlineTimer deadline(waitMs);
    while (true) {
        // find() a cada volta: se o motor reiniciar, m_comps e limpo e o operator[] recriaria
        // uma entrada vazia (defeito apontado na revisao do Mega Brain).
        found = m_comps.constFind(key);
        if (found == m_comps.constEnd() || found->failed || found->lastFrameSeq >= seq
            || m_restarts > kMaxRestarts)
            break;
        if (!m_cond.wait(&m_mutex, deadline)) {
            motionLog(QStringLiteral("quadro nao chegou no prazo (%1 ms): %2 t=%3").arg(waitMs).arg(key).arg(t));
            break;
        }
    }
    found = m_comps.constFind(key);
    const bool chegou = found != m_comps.constEnd() && !found->failed && found->lastFrameSeq >= seq
                        && found->errorSeq < seq && found->lastFrameUs == sourceUs;
    if (exact && !chegou) {
        // Export: sem o quadro exato, nada de quadro anterior. O Exporter le e para com erro.
        if (found == m_comps.constEnd())
            m_exactFailure = tr("O motor de motion reiniciou durante o export");
        else if (!found->errorText.isEmpty() && found->errorSeq >= seq)
            m_exactFailure = found->errorText;
        else
            m_exactFailure = tr("O quadro de %1 s do motion não chegou").arg(t, 0, 'f', 3);
        motionLog(QStringLiteral("falha exata: ") + m_exactFailure);
        return {};
    }
    if (found == m_comps.constEnd())
        return {};
    const QImage out = found->lastFrame;
    if (qEnvironmentVariableIsSet("NARDOTO_MOTION_TRACE"))
        motionLog(QStringLiteral("entregue %1x%2 t=%3 exato=%4 espera=%5ms")
                      .arg(out.width()).arg(out.height()).arg(t).arg(exact).arg(waited.elapsed()));
    return out;
}

// Chamada com m_mutex travado. Passo = diferenca entre dois pedidos exatos seguidos (o quadro do
// export); pede ao motor os proximos kAdiantados quadros que ainda nao vieram nem foram pedidos.
void MotionHost::agendarAdiantados(Comp &comp, const QString &key, const QString &path, int maxWidth,
                                   int maxHeight, qint64 sourceUs)
{
    // Sem pedido exato anterior nao ha passo (o primeiro quadro do export).
    const qint64 passo = comp.ultimoExatoUs >= 0 ? sourceUs - comp.ultimoExatoUs : 0;
    comp.ultimoExatoUs = sourceUs;
    // tempos que ficaram para tras nao vao mais ser pedidos
    for (auto a = comp.adiantados.begin(); a != comp.adiantados.end();)
        a = a.key() < sourceUs - kPertoUs ? comp.adiantados.erase(a) : std::next(a);
    if (passo <= 0 || passo > 250000 || (comp.durationUs > 0 && sourceUs >= comp.durationUs))
        return;
    QList<QPair<quint32, double>> novos;
    for (int k = 1; k <= kAdiantados; ++k) {
        const qint64 alvo = sourceUs + k * passo;
        if (comp.durationUs > 0 && alvo > comp.durationUs + passo)
            break;
        if (acharPertoImg(comp.adiantados, alvo) != comp.adiantados.end()
            || acharPerto(comp.pedidosAdiantados, alvo) != comp.pedidosAdiantados.end())
            continue;
        const quint32 seq = ++m_nextSeq;
        m_seqKey.insert(seq, Pending{key, alvo, true});
        comp.pedidosAdiantados.insert(alvo);
        novos.append({seq, double(alvo) / 1e6});
    }
    if (novos.isEmpty())
        return;
    QMetaObject::invokeMethod(this, [this, key, novos] {
        for (const auto &[seq, t] : novos) {
            QJsonObject req{{QStringLiteral("cmd"), QStringLiteral("quadro")},
                            {QStringLiteral("id"), key},
                            {QStringLiteral("t"), t},
                            {QStringLiteral("seq"), qint64(seq)},
                            {QStringLiteral("exato"), true}};
            sendLine(QJsonDocument(req).toJson(QJsonDocument::Compact));
        }
    }, Qt::QueuedConnection);
    Q_UNUSED(path);
    Q_UNUSED(maxWidth);
    Q_UNUSED(maxHeight);
}

QString MotionHost::takeExactFailure()
{
    QMutexLocker lock(&m_mutex);
    return std::exchange(m_exactFailure, QString());
}

void MotionHost::ensureStarted()
{
    if (m_process && m_process->state() != QProcess::NotRunning)
        return;

    const QString script = motionHostScript();
    const QString electron = electronBinary();
    motionLog(QStringLiteral("iniciando: script=%1 electron=%2").arg(script, electron));
    if (script.isEmpty() || electron.isEmpty()) {
        // Sem o motor instalado: o caminho e baixar o extra, entao a mensagem diz isso.
        failAll(tr("O motor de motion não está instalado. Baixe o \"Motor de motion\" em Extras."));
        QMutexLocker lock(&m_mutex);
        m_restarts = kMaxRestarts + 1;
        return;
    }

    if (!m_server) {
        m_server = new QLocalServer(this);
        connect(m_server, &QLocalServer::newConnection, this, &MotionHost::onNewConnection);
        const QString name = QStringLiteral("nardoto-motion-%1").arg(QCoreApplication::applicationPid());
        QLocalServer::removeServer(name);
        if (!m_server->listen(name)) {
            failAll(tr("Não foi possível abrir o canal do motor de motion: %1").arg(m_server->errorString()));
            return;
        }
    }

    m_ready = false;
    m_process = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    // Herdado de terminais do VS Code e do Claude: faria o electron.exe rodar como Node puro.
    env.remove(QStringLiteral("ELECTRON_RUN_AS_NODE"));
    m_process->setProcessEnvironment(env);
    m_process->setStandardOutputFile(QProcess::nullDevice());
    connect(m_process, &QProcess::readyReadStandardError, this, [this] {
        const QString text = QString::fromUtf8(m_process->readAllStandardError()).trimmed();
        if (!text.isEmpty())
            motionLog(QStringLiteral("electron: ") + text);
    });
    connect(m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        motionLog(QStringLiteral("erro do processo: ") + (m_process ? m_process->errorString() : QString()));
    });
    connect(m_process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus) {
        motionLog(QStringLiteral("processo encerrou, codigo %1").arg(code));
        m_ready = false;
        if (m_socket) {
            m_socket->deleteLater();
            m_socket = nullptr;
        }
        m_process->deleteLater();
        m_process = nullptr;
        QMutexLocker lock(&m_mutex);
        ++m_restarts;
        m_lastError = tr("O motor de motion encerrou (código %1)").arg(code);
        // Ao reiniciar, cada composicao precisa ser aberta de novo: esquecer o registro faz o
        // proximo frame() mandar "abrir" outra vez.
        m_comps.clear();
        m_seqKey.clear();
        m_cond.wakeAll();
    });
    motionLog(QStringLiteral("canal: ") + m_server->fullServerName());
    m_process->start(electron, {script, QStringLiteral("--canal=%1").arg(m_server->fullServerName())});
}

void MotionHost::onNewConnection()
{
    QLocalSocket *socket = m_server->nextPendingConnection();
    if (!socket)
        return;
    if (m_socket)
        m_socket->deleteLater();
    m_socket = socket;
    m_buffer.clear();
    motionLog(QStringLiteral("motor conectou"));
    connect(m_socket, &QLocalSocket::readyRead, this, &MotionHost::onReadyRead);
}

void MotionHost::sendLine(const QByteArray &json)
{
    if (!m_ready || !m_socket) {
        m_pendingLines.append(json);
        return;
    }
    m_socket->write(json);
    m_socket->write("\n");
}

void MotionHost::onReadyRead()
{
    m_buffer.append(m_socket->readAll());
    // Percorre por posicao e corta o buffer uma vez so no fim. Antes, cada quadro de 8 MB era
    // copiado (mid) e o resto do buffer deslocado (remove) -- com os adiantados chegando em
    // rajada, dezenas de MB movidos a cada quadro.
    qsizetype pos = 0;
    while (m_buffer.size() - pos >= kHeaderBytes) {
        const qsizetype magic = m_buffer.indexOf("NMH1", pos);
        if (magic < 0) {
            pos = qMax(pos, m_buffer.size() - 3);
            break;
        }
        pos = magic;
        if (m_buffer.size() - pos < kHeaderBytes)
            break;
        const auto *raw = reinterpret_cast<const uchar *>(m_buffer.constData() + pos);
        const quint32 type = qFromLittleEndian<quint32>(raw + 4);
        const quint32 size = qFromLittleEndian<quint32>(raw + 8);
        if (m_buffer.size() - pos < qsizetype(kHeaderBytes) + qsizetype(size))
            break;
        // sem copia: os tratadores leem e copiam o que precisam antes de o buffer mudar
        const QByteArray body = QByteArray::fromRawData(m_buffer.constData() + pos + kHeaderBytes, qsizetype(size));
        pos += kHeaderBytes + qsizetype(size);
        if (type == kTypeJson)
            handleJson(body);
        else if (type == kTypeFrame)
            handleFrame(body);
        else if (type == kTypeRingFrame)
            handleRingFrame(body);
    }
    if (pos > 0)
        m_buffer.remove(0, pos);
}

void MotionHost::handleJson(const QByteArray &body)
{
    const QJsonObject msg = QJsonDocument::fromJson(body).object();
    const QString evento = msg.value(QStringLiteral("evento")).toString();
    const QString resposta = msg.value(QStringLiteral("resposta")).toString();
    const QString id = msg.value(QStringLiteral("id")).toString();

    if (evento == QStringLiteral("pronto")) {
        motionLog(QStringLiteral("motor pronto: ") + QString::fromUtf8(body));
        m_ready = true;
        const QList<QByteArray> pending = std::exchange(m_pendingLines, {});
        for (const QByteArray &line : pending)
            sendLine(line);
        return;
    }

    if (resposta == QStringLiteral("abrir")) {
        motionLog(QStringLiteral("abrir: ") + QString::fromUtf8(body.left(400)));
        QMutexLocker lock(&m_mutex);
        auto it = m_comps.find(id);
        if (it == m_comps.end())
            return;
        it->opened = msg.value(QStringLiteral("ok")).toBool();
        it->failed = !it->opened;
        it->durationUs = qint64(msg.value(QStringLiteral("duracao")).toDouble() * 1e6);
        if (it->failed) {
            m_lastError = msg.value(QStringLiteral("erro")).toString();
            qWarning("MotionHost: %s", qPrintable(m_lastError));
        }
        m_cond.wakeAll();
        return;
    }

    if (evento == QStringLiteral("cache-pronto") || evento == QStringLiteral("cache-erro")) {
        const QString pasta = msg.value(QStringLiteral("pasta")).toString();
        const QString chave = pasta + QLatin1Char('|') + QString::number(msg.value(QStringLiteral("fps")).toInt());
        if (evento == QStringLiteral("cache-erro")) {
            motionLog(QStringLiteral("cache falhou: ") + QString::fromUtf8(body.left(400)));
            return;
        }
        const QString arquivo = msg.value(QStringLiteral("arquivo")).toString();
        motionLog(QStringLiteral("cache pronto: ") + chave + QStringLiteral(" -> ") + arquivo);
        {
            QMutexLocker lock(&m_mutex);
            // Pedido descartado pelo "mudou" enquanto gravava: o arquivo e do desenho antigo.
            if (!m_cachePedidos.contains(chave))
                return;
            m_cacheFiles.insert(chave, arquivo);
        }
        emit compositionChanged(pasta);
        return;
    }

    if (evento == QStringLiteral("mudou")) {
        QString path;
        {
            QMutexLocker lock(&m_mutex);
            auto it = m_comps.find(id);
            if (it == m_comps.end())
                return;
            it->durationUs = qint64(msg.value(QStringLiteral("duracao")).toDouble() * 1e6);
            it->lastFrameUs = -1; // o mesmo tempo agora tem outro desenho
            path = it->path;
            // O cache e do desenho antigo: volta ao vivo e o proximo quadro pede um novo.
            const QString prefixo = path + QLatin1Char('|');
            m_cacheFiles.removeIf([&](const auto &e) { return e.key().startsWith(prefixo); });
            m_cachePedidos.removeIf([&](const QString &k) { return k.startsWith(prefixo); });
        }
        emit compositionChanged(path);
        return;
    }

    if (evento == QStringLiteral("erro")) {
        motionLog(QStringLiteral("erro do motor: ") + QString::fromUtf8(body.left(400)));
        // Quadro que falhou: libera quem espera com o quadro anterior em vez de segurar ate o prazo.
        const quint32 seq = quint32(msg.value(QStringLiteral("seq")).toInteger());
        QMutexLocker lock(&m_mutex);
        const Pending pendente = m_seqKey.take(seq);
        const QString &key = pendente.key;
        auto it = m_comps.find(key.isEmpty() ? id : key);
        if (it != m_comps.end() && it->pedidosAdiantados.remove(pendente.sourceUs)) {
            // Adiantado que falhou: marca o tempo com quadro vazio; frame() vira falha exata.
            it->errorText = msg.value(QStringLiteral("erro")).toString();
            it->adiantados.insert(pendente.sourceUs, QImage());
            m_cond.wakeAll();
            return;
        }
        if (it != m_comps.end()) {
            if (seq > it->lastFrameSeq)
                it->lastFrameSeq = seq;
            it->errorSeq = qMax(it->errorSeq, seq);
            it->errorText = msg.value(QStringLiteral("erro")).toString();
        }
        m_lastError = msg.value(QStringLiteral("erro")).toString();
        m_cond.wakeAll();
    }
}

void MotionHost::handleFrame(const QByteArray &body)
{
    if (body.size() < kFrameMetaBytes)
        return;
    const auto *raw = reinterpret_cast<const uchar *>(body.constData());
    const quint32 seq = qFromLittleEndian<quint32>(raw);
    const int width = int(qFromLittleEndian<quint32>(raw + 4));
    const int height = int(qFromLittleEndian<quint32>(raw + 8));
    const int stride = int(qFromLittleEndian<quint32>(raw + 12));
    if (width <= 0 || height <= 0 || body.size() < kFrameMetaBytes + qint64(stride) * height)
        return;
    handlePixels(seq, width, height, stride, raw + kFrameMetaBytes);
}

// Quadro numa vaga do anel em arquivo: o cano trouxe so o aviso (seq, tamanho, vaga, caminho).
void MotionHost::handleRingFrame(const QByteArray &body)
{
    if (body.size() <= kFrameMetaBytes)
        return;
    const auto *raw = reinterpret_cast<const uchar *>(body.constData());
    const quint32 seq = qFromLittleEndian<quint32>(raw);
    const int width = int(qFromLittleEndian<quint32>(raw + 4));
    const int height = int(qFromLittleEndian<quint32>(raw + 8));
    const int stride = int(qFromLittleEndian<quint32>(raw + 12));
    const quint32 vaga = qFromLittleEndian<quint32>(raw + 16);
    const QString caminho = QString::fromUtf8(body.mid(kFrameMetaBytes));
    if (width <= 0 || height <= 0)
        return;
    QFile *arquivo = m_rings.value(caminho);
    if (!arquivo) {
        arquivo = new QFile(caminho, this);
        if (!arquivo->open(QIODevice::ReadOnly)) {
            motionLog(QStringLiteral("anel nao abriu: ") + caminho);
            delete arquivo;
            return;
        }
        m_rings.insert(caminho, arquivo);
    }
    const qint64 bytes = qint64(stride) * height;
    // mapeia por vaga: o arquivo pode crescer? nao -- tamanho fixo desde a criacao
    uchar *base = arquivo->map(qint64(vaga) * bytes, bytes);
    if (!base) {
        motionLog(QStringLiteral("anel nao mapeou: ") + caminho);
        return;
    }
    handlePixels(seq, width, height, stride, base);
    arquivo->unmap(base);
}

void MotionHost::handlePixels(quint32 seq, int width, int height, int stride, const uchar *pixels)
{
    // BGRA premultiplicado em little-endian e exatamente o ARGB32_Premultiplied do Qt. O
    // compositor trabalha em RGBA8888 (mesmo formato das imagens paradas).
    const QImage view(pixels, width, height, stride, QImage::Format_ARGB32_Premultiplied);
    // Quadro opaco (o comum: composicao com fundo): pre-multiplicado e reto sao iguais, entao
    // basta trocar a ordem dos canais. Desfazer a pre-multiplicacao pixel a pixel so quando ha
    // transparencia de verdade.
    bool opaco = true;
    for (int y = 0; y < height && opaco; ++y) {
        const uchar *linha = pixels + qsizetype(y) * stride;
        for (int x = 3; x < width * 4; x += 4) {
            if (linha[x] != 255) {
                opaco = false;
                break;
            }
        }
    }
    QImage image;
    if (opaco) {
        image = view.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
        image.reinterpretAsFormat(QImage::Format_RGBA8888);
    } else {
        image = view.convertToFormat(QImage::Format_RGBA8888);
    }

    QMutexLocker lock(&m_mutex);
    const Pending pending = m_seqKey.take(seq);
    const QString &key = pending.key;
    auto it = m_comps.find(key);
    if (it == m_comps.end())
        return;
    // Preview: pedidos mais antigos desta composicao que o motor descartou (scrub rapido) nao vao
    // chegar. Pedido exato (export) nunca: o motor atende todos, em ordem -- e apagar aqui o direto
    // que estava a caminho, quando chegava um adiantado, fazia o export falhar (medido).
    if (!pending.exact) {
        for (auto s = m_seqKey.begin(); s != m_seqKey.end();) {
            if (s.key() < seq && s.value().key == key && !s.value().exact)
                s = m_seqKey.erase(s);
            else
                ++s;
        }
    }
    if (qEnvironmentVariableIsSet("NARDOTO_MOTION_TRACE"))
        motionLog(QStringLiteral("recebido seq=%1 t=%2 adiantado=%3 ultimoSeq=%4")
                      .arg(seq).arg(pending.sourceUs).arg(it->pedidosAdiantados.contains(pending.sourceUs))
                      .arg(it->lastFrameSeq));
    if (it->pedidosAdiantados.remove(pending.sourceUs)) {
        // Adiantado (export): guarda pelo tempo; frame() entrega quando for pedido. Nao mexe no
        // "ultimo quadro" -- ele e de quem esta esperando o pedido direto.
        it->adiantados.insert(pending.sourceUs, image);
        m_cond.wakeAll();
        return;
    }
    if (seq < it->lastFrameSeq)
        return;
    it->lastFrameSeq = seq;
    it->lastFrame = std::move(image);
    it->lastFrameUs = pending.sourceUs;
    m_cond.wakeAll();
}

void MotionHost::failAll(const QString &error)
{
    motionLog(QStringLiteral("falha: ") + error);
    QMutexLocker lock(&m_mutex);
    m_lastError = error;
    qWarning("MotionHost: %s", qPrintable(error));
    for (Comp &comp : m_comps)
        comp.failed = true;
    m_cond.wakeAll();
}

} // namespace drift
