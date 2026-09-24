#include "MotionLibrary.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QUrl>

namespace {

const QString kMeta = QStringLiteral("meta.json");
const QString kClipe = QStringLiteral("clipe.mov");
const QString kPrevia = QStringLiteral("previa.mp4");
const QString kMiniatura = QStringLiteral("miniatura.jpg");
const QString kPedido = QStringLiteral("pedido.json");
const QString kStatus = QStringLiteral("status.json");

QJsonObject lerJson(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(file.readAll()).object();
}

// URL com a data de modificação na query: o cache de imagens do QML guarda por URL, e o
// Studio regrava a miniatura no mesmo caminho quando gera uma versão nova.
QString urlComVersao(const QString &path)
{
    const QFileInfo info(path);
    if (!info.exists())
        return {};
    QUrl url = QUrl::fromLocalFile(info.absoluteFilePath());
    url.setQuery(QStringLiteral("v=%1").arg(info.lastModified().toMSecsSinceEpoch()));
    return url.toString();
}

QDateTime lerData(const QJsonObject &obj, const QString &key)
{
    return QDateTime::fromString(obj.value(key).toString(), Qt::ISODateWithMs);
}

} // namespace

MotionLibrary::MotionLibrary(const QString &motionDir, QObject *parent)
    : QAbstractListModel(parent)
    , m_motionDir(motionDir.isEmpty()
                      ? QDir(QDir::homePath()).filePath(QStringLiteral("nardoto-editor/motion"))
                      : motionDir)
{
    // As duas raízes globais existem desde o começo: sem elas o vigia não teria onde se
    // pendurar e o primeiro item gerado pelo Studio só apareceria depois de reabrir o editor.
    QDir().mkpath(QDir(m_motionDir).filePath(QStringLiteral("modelos")));
    QDir().mkpath(QDir(m_motionDir).filePath(QStringLiteral("meus")));

    m_debounce.setSingleShot(true);
    m_debounce.setInterval(250);
    connect(&m_debounce, &QTimer::timeout, this, &MotionLibrary::recarregar);
    connect(&m_vigia, &QFileSystemWatcher::directoryChanged, this, [this] { m_debounce.start(); });
    connect(&m_vigia, &QFileSystemWatcher::fileChanged, this, [this] { m_debounce.start(); });

    recarregar();
}

int MotionLibrary::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_itens.size());
}

QVariant MotionLibrary::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_itens.size())
        return {};
    const Item &item = m_itens.at(index.row());
    switch (role) {
    case IdRole:
        return item.id;
    case Qt::DisplayRole:
    case NomeRole:
        return item.nome;
    case SecaoRole:
        return item.secao;
    case PastaRole:
        return item.pasta;
    case MotorRole:
        return item.motor;
    case MiniaturaRole:
        return item.miniatura;
    case PreviaRole:
        return item.previa;
    case TemClipeRole:
        return item.temClipe;
    case DuracaoRole:
        return item.duracao;
    case EstadoRole:
        return item.estado;
    case MensagemRole:
        return item.mensagem;
    case DestinoRole:
        return item.destino;
    case PedidoPendenteRole:
        return item.pedidoPendente;
    default:
        return {};
    }
}

QHash<int, QByteArray> MotionLibrary::roleNames() const
{
    return {
        {IdRole, "id"},
        {NomeRole, "nome"},
        {SecaoRole, "secao"},
        {PastaRole, "pasta"},
        {MotorRole, "motor"},
        {MiniaturaRole, "miniatura"},
        {PreviaRole, "previa"},
        {TemClipeRole, "temClipe"},
        {DuracaoRole, "duracao"},
        {EstadoRole, "estado"},
        {MensagemRole, "mensagem"},
        {DestinoRole, "destino"},
        {PedidoPendenteRole, "pedidoPendente"},
    };
}

QVariantMap MotionLibrary::contagens() const
{
    QVariantMap out{{QStringLiteral("modelos"), 0}, {QStringLiteral("meus"), 0},
                    {QStringLiteral("projeto"), 0}};
    for (const Item &item : m_itens)
        out[item.secao] = out.value(item.secao).toInt() + 1;
    return out;
}

void MotionLibrary::setProjectFile(const QString &projectFilePath)
{
    const QString dir = projectFilePath.isEmpty()
                            ? QString()
                            : QFileInfo(projectFilePath).absoluteDir().absolutePath();
    if (dir == m_projetoDir)
        return;
    m_projetoDir = dir;
    emit raizesChanged();
    recarregar();
}

bool MotionLibrary::lerItem(const QString &pasta, const QString &secao, Item &out)
{
    const QDir dir(pasta);
    const QString metaPath = dir.filePath(kMeta);
    if (!QFileInfo::exists(metaPath))
        return false;

    const QJsonObject meta = lerJson(metaPath);
    out.id = dir.dirName();
    out.nome = meta.value(QStringLiteral("nome")).toString();
    if (out.nome.isEmpty())
        out.nome = out.id;
    out.secao = secao;
    out.pasta = dir.absolutePath();
    out.motor = meta.value(QStringLiteral("motor")).toString();
    out.duracao = meta.value(QStringLiteral("duracaoSegundos")).toDouble();
    out.temClipe = QFileInfo::exists(dir.filePath(kClipe));
    out.miniatura = urlComVersao(dir.filePath(kMiniatura));
    out.previa = urlComVersao(dir.filePath(kPrevia));

    const QString statusPath = dir.filePath(kStatus);
    const bool temStatus = QFileInfo::exists(statusPath);
    const QJsonObject status = temStatus ? lerJson(statusPath) : QJsonObject();
    out.estado = status.value(QStringLiteral("estado")).toString();
    out.mensagem = status.value(QStringLiteral("mensagem")).toString();
    out.destino = status.value(QStringLiteral("destino")).toString();

    // Pedido sem resposta: há pedido.json e o status (se existe) é mais antigo que ele.
    const QString pedidoPath = dir.filePath(kPedido);
    if (QFileInfo::exists(pedidoPath)) {
        if (!temStatus) {
            out.pedidoPendente = true;
        } else {
            const QDateTime pedidoEm = lerData(lerJson(pedidoPath), QStringLiteral("criadoEm"));
            const QDateTime statusEm = lerData(status, QStringLiteral("atualizadoEm"));
            out.pedidoPendente = pedidoEm.isValid() && statusEm.isValid() && statusEm < pedidoEm;
        }
    }
    return true;
}

void MotionLibrary::escanearRaiz(const QString &raiz, const QString &secao, QList<Item> &out)
{
    const QDir dir(raiz);
    if (!dir.exists())
        return;
    const QStringList pastas =
        dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name | QDir::IgnoreCase);
    for (const QString &nome : pastas) {
        Item item;
        if (lerItem(dir.filePath(nome), secao, item))
            out.append(item);
    }
}

QList<MotionLibrary::Item> MotionLibrary::escanear() const
{
    QList<Item> itens;
    const QDir motion(m_motionDir);
    escanearRaiz(motion.filePath(QStringLiteral("modelos")), QStringLiteral("modelos"), itens);
    escanearRaiz(motion.filePath(QStringLiteral("meus")), QStringLiteral("meus"), itens);
    if (!m_projetoDir.isEmpty())
        escanearRaiz(QDir(m_projetoDir).filePath(QStringLiteral("motion")),
                     QStringLiteral("projeto"), itens);
    return itens;
}

void MotionLibrary::recarregar()
{
    aplicar(escanear());
    atualizarVigia();
}

// Mesma lista de pastas: atualiza as linhas no lugar, para o hover e o formulário aberto não
// serem recriados a cada status.json que o Studio escreve. Lista diferente: reset.
void MotionLibrary::aplicar(const QList<Item> &novos)
{
    bool mesmasPastas = novos.size() == m_itens.size();
    for (int i = 0; mesmasPastas && i < novos.size(); ++i)
        mesmasPastas = novos.at(i).pasta == m_itens.at(i).pasta;

    if (!mesmasPastas) {
        beginResetModel();
        m_itens = novos;
        endResetModel();
        emit itensChanged();
        return;
    }

    bool mudou = false;
    for (int i = 0; i < novos.size(); ++i) {
        if (novos.at(i) == m_itens.at(i))
            continue;
        m_itens[i] = novos.at(i);
        const QModelIndex idx = index(i);
        emit dataChanged(idx, idx);
        mudou = true;
    }
    if (mudou)
        emit itensChanged();
}

// O vigia olha as raízes (item novo ou removido), a pasta de cada item (arquivo criado ou
// trocado por rename, que é como o Studio grava) e os JSON editados no lugar. Depois de
// cada mudança de diretório os caminhos são re-adicionados, porque um rename tira o
// arquivo antigo da lista do vigia.
void MotionLibrary::atualizarVigia()
{
    QStringList desejados;
    const QDir motion(m_motionDir);
    QStringList raizes{motion.filePath(QStringLiteral("modelos")),
                       motion.filePath(QStringLiteral("meus"))};
    if (!m_projetoDir.isEmpty()) {
        const QString raizProjeto = QDir(m_projetoDir).filePath(QStringLiteral("motion"));
        // Sem motion/ ainda, vigia a pasta do projeto para ver a subpasta nascer.
        raizes.append(QFileInfo(raizProjeto).isDir() ? raizProjeto : m_projetoDir);
    }
    for (const QString &raiz : raizes) {
        if (QFileInfo(raiz).isDir())
            desejados.append(QDir(raiz).absolutePath());
    }
    for (const Item &item : m_itens) {
        desejados.append(item.pasta);
        for (const QString &arquivo : {kMeta, kStatus}) {
            const QString path = QDir(item.pasta).filePath(arquivo);
            if (QFileInfo::exists(path))
                desejados.append(path);
        }
    }

    const QStringList atuais = m_vigia.files() + m_vigia.directories();
    QStringList sobrando;
    for (const QString &path : atuais) {
        if (!desejados.contains(path))
            sobrando.append(path);
    }
    if (!sobrando.isEmpty())
        m_vigia.removePaths(sobrando);
    QStringList faltando;
    for (const QString &path : desejados) {
        if (!atuais.contains(path))
            faltando.append(path);
    }
    if (!faltando.isEmpty())
        m_vigia.addPaths(faltando);
}

int MotionLibrary::indiceDaPasta(const QString &pasta) const
{
    const QString alvo = QDir(pasta).absolutePath();
    for (int i = 0; i < m_itens.size(); ++i) {
        if (m_itens.at(i).pasta == alvo)
            return i;
    }
    return -1;
}

QVariantList MotionLibrary::campos(const QString &pasta) const
{
    const QJsonObject meta = lerJson(QDir(pasta).filePath(kMeta));
    return meta.value(QStringLiteral("campos")).toArray().toVariantList();
}

bool MotionLibrary::pedirModificacao(const QString &pasta, const QVariantMap &valores)
{
    const int row = indiceDaPasta(pasta);
    if (row < 0) {
        emit erro(tr("This motion graphic is no longer on disk."));
        return false;
    }

    const QJsonObject pedido{
        {QStringLiteral("valores"), QJsonObject::fromVariantMap(valores)},
        {QStringLiteral("criadoEm"),
         QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs)},
    };
    QSaveFile file(QDir(m_itens.at(row).pasta).filePath(kPedido));
    if (!file.open(QIODevice::WriteOnly)
        || file.write(QJsonDocument(pedido).toJson(QJsonDocument::Indented)) < 0
        || !file.commit()) {
        emit erro(tr("Could not save the change request."));
        return false;
    }

    // Reflete já o pedido pendente, sem esperar o vigia.
    recarregar();
    return true;
}

bool MotionLibrary::usar(const QString &pasta)
{
    const int row = indiceDaPasta(pasta);
    if (row < 0 || !m_itens.at(row).temClipe) {
        emit erro(tr("This motion graphic is still being generated."));
        return false;
    }
    emit usoPedido(QDir(m_itens.at(row).pasta).filePath(kClipe));
    return true;
}
