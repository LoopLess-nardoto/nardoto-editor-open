#include "models/MotionLibrary.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

// Aba Motion: a galeria lê o contrato de disco que o Nardoto Studio escreve.
class MotionLibraryTest : public QObject
{
    Q_OBJECT

private slots:
    void listaItensComMeta();
    void ignoraPastaSemMeta();
    void secaoDoProjeto();
    void pedirModificacaoGravaPedido();
    void statusAtualizaEstado();
    void usarExigeClipe();

private:
    static void escreverJson(const QString &path, const QJsonObject &obj)
    {
        QFile file(path);
        QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
        file.write(QJsonDocument(obj).toJson());
    }

    static QString criarItem(const QString &raiz, const QString &id, bool comClipe = true)
    {
        const QString pasta = QDir(raiz).filePath(id);
        QDir().mkpath(pasta);
        escreverJson(QDir(pasta).filePath(QStringLiteral("meta.json")),
                     QJsonObject{
                         {QStringLiteral("nome"), QStringLiteral("Título %1").arg(id)},
                         {QStringLiteral("motor"), QStringLiteral("hyperframes")},
                         {QStringLiteral("duracaoSegundos"), 4},
                         {QStringLiteral("largura"), 1920},
                         {QStringLiteral("altura"), 1080},
                         {QStringLiteral("campos"),
                          QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("titulo")},
                                                 {QStringLiteral("rotulo"), QStringLiteral("Título")},
                                                 {QStringLiteral("tipo"), QStringLiteral("texto")},
                                                 {QStringLiteral("valor"), QStringLiteral("Olá")}}}},
                     });
        if (comClipe) {
            QFile clipe(QDir(pasta).filePath(QStringLiteral("clipe.mov")));
            if (clipe.open(QIODevice::WriteOnly))
                clipe.write("x");
        }
        return QDir(pasta).absolutePath();
    }

    static int linhaDaPasta(const MotionLibrary &lib, const QString &pasta)
    {
        for (int i = 0; i < lib.rowCount(); ++i) {
            if (lib.data(lib.index(i), MotionLibrary::PastaRole).toString() == pasta)
                return i;
        }
        return -1;
    }
};

void MotionLibraryTest::listaItensComMeta()
{
    QTemporaryDir home;
    QVERIFY(home.isValid());
    const QString motion = home.filePath(QStringLiteral("motion"));
    MotionLibrary vazia(motion);
    QCOMPARE(vazia.rowCount(), 0);
    // As duas raízes globais são criadas para o vigia ter onde se pendurar.
    QVERIFY(QFileInfo(QDir(motion).filePath(QStringLiteral("modelos"))).isDir());
    QVERIFY(QFileInfo(QDir(motion).filePath(QStringLiteral("meus"))).isDir());

    criarItem(QDir(motion).filePath(QStringLiteral("modelos")), QStringLiteral("a"));
    const QString gerando =
        criarItem(QDir(motion).filePath(QStringLiteral("meus")), QStringLiteral("b"), false);

    MotionLibrary lib(motion);
    QCOMPARE(lib.rowCount(), 2);
    const QModelIndex primeiro = lib.index(0);
    QCOMPARE(lib.data(primeiro, MotionLibrary::IdRole).toString(), QStringLiteral("a"));
    QCOMPARE(lib.data(primeiro, MotionLibrary::NomeRole).toString(), QStringLiteral("Título a"));
    QCOMPARE(lib.data(primeiro, MotionLibrary::SecaoRole).toString(), QStringLiteral("modelos"));
    QCOMPARE(lib.data(primeiro, MotionLibrary::DuracaoRole).toDouble(), 4.0);
    QVERIFY(lib.data(primeiro, MotionLibrary::TemClipeRole).toBool());

    const int row = linhaDaPasta(lib, gerando);
    QVERIFY(row >= 0);
    QCOMPARE(lib.data(lib.index(row), MotionLibrary::SecaoRole).toString(), QStringLiteral("meus"));
    QVERIFY(!lib.data(lib.index(row), MotionLibrary::TemClipeRole).toBool());

    QCOMPARE(lib.contagens().value(QStringLiteral("modelos")).toInt(), 1);
    QCOMPARE(lib.contagens().value(QStringLiteral("meus")).toInt(), 1);

    const QVariantList campos = lib.campos(gerando);
    QCOMPARE(campos.size(), 1);
    QCOMPARE(campos.first().toMap().value(QStringLiteral("tipo")).toString(), QStringLiteral("texto"));
}

void MotionLibraryTest::ignoraPastaSemMeta()
{
    QTemporaryDir home;
    QVERIFY(home.isValid());
    const QString motion = home.filePath(QStringLiteral("motion"));
    const QString meus = QDir(motion).filePath(QStringLiteral("meus"));
    QDir().mkpath(QDir(meus).filePath(QStringLiteral("sem-meta")));
    QFile solto(QDir(meus).filePath(QStringLiteral("sem-meta/clipe.mov")));
    QVERIFY(solto.open(QIODevice::WriteOnly));
    solto.close();
    criarItem(meus, QStringLiteral("com-meta"));

    MotionLibrary lib(motion);
    QCOMPARE(lib.rowCount(), 1);
    QCOMPARE(lib.data(lib.index(0), MotionLibrary::IdRole).toString(), QStringLiteral("com-meta"));
}

void MotionLibraryTest::secaoDoProjeto()
{
    QTemporaryDir home;
    QVERIFY(home.isValid());
    const QString motion = home.filePath(QStringLiteral("motion"));
    const QString projetoDir = home.filePath(QStringLiteral("projeto"));
    criarItem(QDir(projetoDir).filePath(QStringLiteral("motion")), QStringLiteral("abertura"));

    MotionLibrary lib(motion);
    QVERIFY(!lib.temProjeto());
    QCOMPARE(lib.rowCount(), 0);

    lib.setProjectFile(QDir(projetoDir).filePath(QStringLiteral("video.drift")));
    QVERIFY(lib.temProjeto());
    QCOMPARE(lib.rowCount(), 1);
    QCOMPARE(lib.data(lib.index(0), MotionLibrary::SecaoRole).toString(), QStringLiteral("projeto"));

    lib.setProjectFile({});
    QVERIFY(!lib.temProjeto());
    QCOMPARE(lib.rowCount(), 0);
}

void MotionLibraryTest::pedirModificacaoGravaPedido()
{
    QTemporaryDir home;
    QVERIFY(home.isValid());
    const QString motion = home.filePath(QStringLiteral("motion"));
    const QString pasta = criarItem(QDir(motion).filePath(QStringLiteral("meus")), QStringLiteral("c"));

    MotionLibrary lib(motion);
    const QDateTime antes = QDateTime::currentDateTimeUtc().addSecs(-1);
    QVERIFY(lib.pedirModificacao(pasta, QVariantMap{{QStringLiteral("titulo"), QStringLiteral("Novo")},
                                                    {QStringLiteral("tamanho"), 72}}));

    QFile file(QDir(pasta).filePath(QStringLiteral("pedido.json")));
    QVERIFY(file.open(QIODevice::ReadOnly));
    const QJsonObject pedido = QJsonDocument::fromJson(file.readAll()).object();
    const QJsonObject valores = pedido.value(QStringLiteral("valores")).toObject();
    QCOMPARE(valores.value(QStringLiteral("titulo")).toString(), QStringLiteral("Novo"));
    QCOMPARE(valores.value(QStringLiteral("tamanho")).toInt(), 72);
    const QDateTime criadoEm =
        QDateTime::fromString(pedido.value(QStringLiteral("criadoEm")).toString(), Qt::ISODateWithMs);
    QVERIFY(criadoEm.isValid());
    QVERIFY(criadoEm >= antes);
    // Nada de temporário esquecido ao lado do pedido.
    QCOMPARE(QDir(pasta).entryList({QStringLiteral("pedido.json*")}, QDir::Files).size(), 1);

    // Sem status.json o pedido fica pendente.
    QVERIFY(lib.data(lib.index(0), MotionLibrary::PedidoPendenteRole).toBool());

    QSignalSpy erros(&lib, &MotionLibrary::erro);
    QVERIFY(!lib.pedirModificacao(home.filePath(QStringLiteral("nao-existe")), {}));
    QCOMPARE(erros.count(), 1);
}

void MotionLibraryTest::statusAtualizaEstado()
{
    QTemporaryDir home;
    QVERIFY(home.isValid());
    const QString motion = home.filePath(QStringLiteral("motion"));
    const QString pasta = criarItem(QDir(motion).filePath(QStringLiteral("meus")), QStringLiteral("d"));

    MotionLibrary lib(motion);
    QVERIFY(lib.pedirModificacao(pasta, {{QStringLiteral("titulo"), QStringLiteral("X")}}));
    QCOMPARE(lib.data(lib.index(0), MotionLibrary::EstadoRole).toString(), QString());

    QSignalSpy mudou(&lib, &QAbstractItemModel::dataChanged);
    escreverJson(QDir(pasta).filePath(QStringLiteral("status.json")),
                 QJsonObject{{QStringLiteral("estado"), QStringLiteral("renderizando")},
                             {QStringLiteral("atualizadoEm"),
                              QDateTime::currentDateTimeUtc().addSecs(5).toString(Qt::ISODateWithMs)}});
    // O vigia pega a mudança sozinho (com debounce).
    QTRY_COMPARE_WITH_TIMEOUT(lib.data(lib.index(0), MotionLibrary::EstadoRole).toString(),
                              QStringLiteral("renderizando"), 5000);
    QVERIFY(mudou.count() >= 1);
    QVERIFY(!lib.data(lib.index(0), MotionLibrary::PedidoPendenteRole).toBool());

    escreverJson(QDir(pasta).filePath(QStringLiteral("status.json")),
                 QJsonObject{{QStringLiteral("estado"), QStringLiteral("erro")},
                             {QStringLiteral("mensagem"), QStringLiteral("Falhou o render")},
                             {QStringLiteral("atualizadoEm"),
                              QDateTime::currentDateTimeUtc().addSecs(6).toString(Qt::ISODateWithMs)}});
    lib.recarregar();
    QCOMPARE(lib.data(lib.index(0), MotionLibrary::EstadoRole).toString(), QStringLiteral("erro"));
    QCOMPARE(lib.data(lib.index(0), MotionLibrary::MensagemRole).toString(),
             QStringLiteral("Falhou o render"));
}

void MotionLibraryTest::usarExigeClipe()
{
    QTemporaryDir home;
    QVERIFY(home.isValid());
    const QString motion = home.filePath(QStringLiteral("motion"));
    const QString pronto = criarItem(QDir(motion).filePath(QStringLiteral("meus")), QStringLiteral("e"));
    const QString gerando =
        criarItem(QDir(motion).filePath(QStringLiteral("meus")), QStringLiteral("f"), false);

    MotionLibrary lib(motion);
    QSignalSpy pedidos(&lib, &MotionLibrary::usoPedido);
    QSignalSpy erros(&lib, &MotionLibrary::erro);

    QVERIFY(lib.usar(pronto));
    QCOMPARE(pedidos.count(), 1);
    QCOMPARE(pedidos.first().first().toString(), QDir(pronto).filePath(QStringLiteral("clipe.mov")));

    QVERIFY(!lib.usar(gerando));
    QCOMPARE(pedidos.count(), 1);
    QCOMPARE(erros.count(), 1);
}

QTEST_GUILESS_MAIN(MotionLibraryTest)
#include "tst_motionlibrary.moc"
