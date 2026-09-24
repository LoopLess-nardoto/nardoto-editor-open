#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QFileSystemWatcher>
#include <QList>
#include <QString>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

// Galeria da aba Motion: clipes de motion graphics que o Nardoto Studio gera em disco.
//
// Contrato de disco (compartilhado com o Studio, que escreve os arquivos):
//   <raiz>/<id>/meta.json    nome, motor, duração, tamanho e campos editáveis
//   <raiz>/<id>/clipe.mov    ProRes 4444 com alfa, o arquivo que vai para a timeline
//   <raiz>/<id>/previa.mp4   prévia opaca em laço para o hover
//   <raiz>/<id>/miniatura.jpg
//   <raiz>/<id>/pedido.json  escrito AQUI quando a pessoa pede uma modificação
//   <raiz>/<id>/status.json  escrito pelo Studio (renderizando, pronto, erro)
// Raízes: <motion>/modelos, <motion>/meus e <pasta do projeto>/motion. Pasta sem meta.json
// é ignorada; sem clipe.mov o item aparece como "gerando" e não pode ser usado.
class MotionLibrary : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(bool temProjeto READ temProjeto NOTIFY raizesChanged)
    Q_PROPERTY(QVariantMap contagens READ contagens NOTIFY itensChanged)

public:
    enum Roles {
        IdRole = Qt::UserRole + 1,
        NomeRole,
        SecaoRole,
        PastaRole,
        MotorRole,
        MiniaturaRole,
        PreviaRole,
        TemClipeRole,
        DuracaoRole,
        EstadoRole,
        MensagemRole,
        DestinoRole,
        PedidoPendenteRole,
    };

    // `motionDir` é a pasta que contém modelos/ e meus/. Vazio usa
    // ~/nardoto-editor/motion (o caminho do contrato); os testes passam uma pasta temporária.
    explicit MotionLibrary(const QString &motionDir = {}, QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;

    bool temProjeto() const { return !m_projetoDir.isEmpty(); }
    QVariantMap contagens() const;
    QString motionDir() const { return m_motionDir; }

    // Arquivo do projeto aberto (.drift). Vazio para projeto ainda não salvo, o que esconde
    // a seção "Deste projeto".
    void setProjectFile(const QString &projectFilePath);

    // Os métodos abaixo recebem a pasta do item (papel `pasta`), única entre as seções.
    Q_INVOKABLE QVariantList campos(const QString &pasta) const;
    // Grava pedido.json de forma atômica (temporário + rename). O Studio vigia o arquivo.
    Q_INVOKABLE bool pedirModificacao(const QString &pasta, const QVariantMap &valores);
    // Pede para colocar clipe.mov na trilha do topo, no playhead. Quem executa é o
    // MotionPlacer (importa e espera a sondagem terminar sem travar a interface).
    Q_INVOKABLE bool usar(const QString &pasta);
    Q_INVOKABLE void recarregar();

signals:
    void itensChanged();
    void raizesChanged();
    void usoPedido(const QString &clipePath);
    void erro(const QString &mensagem);

private:
    struct Item
    {
        QString id;
        QString nome;
        QString secao;
        QString pasta;
        QString motor;
        QString miniatura;
        QString previa;
        bool temClipe = false;
        double duracao = 0.0;
        QString estado;
        QString mensagem;
        QString destino;
        bool pedidoPendente = false;

        bool operator==(const Item &other) const = default;
    };

    QList<Item> escanear() const;
    static void escanearRaiz(const QString &raiz, const QString &secao, QList<Item> &out);
    static bool lerItem(const QString &pasta, const QString &secao, Item &out);
    void aplicar(const QList<Item> &novos);
    void atualizarVigia();
    int indiceDaPasta(const QString &pasta) const;

    QString m_motionDir;
    QString m_projetoDir;
    QList<Item> m_itens;
    QFileSystemWatcher m_vigia;
    QTimer m_debounce;
};
