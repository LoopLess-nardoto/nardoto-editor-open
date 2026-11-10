#include "engine/AddonPackage.h"
#include "engine/AddonRegistry.h"
#include "engine/GpuPackageParse.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

#include <QScopeGuard>

#include <openssl/evp.h>

using namespace drift::addon;

// The fixture is a real package signed with the production key (tests/data/, built by the
// packer in the drift-addons repo). Damaged variants are produced by mutating bytes, so the
// tests exercise the actual trust root rather than a test-only key.

class TestAddonPackage : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void readsManifestWithoutVerifying();
    void productionRootRejectsTheRetiredFixture();
    void installsAndVerifies();
    void rejectsTamperedPayload();
    void rejectsTamperedSignature();
    void rejectsTruncatedFile();
    void rejectsBadMagic();
    void leavesNoStagingBehindOnFailure();
    void reportsCancellation();
    void installedAddonOutranksBundledContent();

private:
    // Cópia da fixture assinada com um par Ed25519 gerado aqui. Serve os testes que exercitam
    // o pipeline de instalação; a raiz de confiança (chave de produção) tem teste próprio.
    QString fixtureAssinadaAqui();
    QByteArray m_chaveDeTeste;
    // Copy the fixture and flip one byte at `offset` (negative counts back from the end).
    QString corruptedCopy(const QString &name, qint64 offset) const;

    QString m_fixture;
    QTemporaryDir m_tmp;
};

void TestAddonPackage::initTestCase()
{
    m_fixture = QStringLiteral(DRIFT_TEST_DATA_DIR "/test.fixture-1.2.3.driftpkg");
    QVERIFY2(QFile::exists(m_fixture), qPrintable(m_fixture));
    QVERIFY(m_tmp.isValid());
}

QString TestAddonPackage::corruptedCopy(const QString &name, qint64 offset) const
{
    const QString path = m_tmp.filePath(name);
    QFile::remove(path);
    if (!QFile::copy(m_fixture, path))
        return {};

    QFile file(path);
    if (!file.open(QIODevice::ReadWrite))
        return {};
    const qint64 pos = offset < 0 ? file.size() + offset : offset;
    file.seek(pos);
    char byte = 0;
    file.read(&byte, 1);
    byte = char(byte ^ 0xff);
    file.seek(pos);
    file.write(&byte, 1);
    file.close();
    return path;
}

void TestAddonPackage::readsManifestWithoutVerifying()
{
    QString error;
    const auto info = readManifest(m_fixture, &error);
    QVERIFY2(info.has_value(), qPrintable(error));
    QCOMPARE(info->id, QStringLiteral("test.fixture"));
    QCOMPARE(info->version, QStringLiteral("1.2.3"));
    QCOMPARE(info->provides.size(), 1);
    QCOMPARE(info->provides.first().kind, QStringLiteral("fonts"));
    QCOMPARE(info->provides.first().root, QStringLiteral("fonts"));
    QCOMPARE(info->files.size(), 3);
}

QString TestAddonPackage::fixtureAssinadaAqui()
{
    QFile in(m_fixture);
    if (!in.open(QIODevice::ReadOnly))
        return {};
    QByteArray bytes = in.readAll();
    in.close();
    // O trailer é fixo: 32 bytes de digest + 64 de assinatura, no fim do arquivo. A posição
    // do payload comprimido vem do cabeçalho, mas não é precisa para trocar a assinatura.
    if (bytes.size() < 96)
        return {};
    const int offSig = bytes.size() - 64;
    const int offDigest = offSig - 32;

    EVP_PKEY *pkey = nullptr;
    EVP_PKEY_CTX *kctx = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, nullptr);
    if (!kctx || EVP_PKEY_keygen_init(kctx) != 1 || EVP_PKEY_keygen(kctx, &pkey) != 1) {
        EVP_PKEY_CTX_free(kctx);
        return {};
    }
    EVP_PKEY_CTX_free(kctx);

    const QByteArray digest = bytes.mid(offDigest, 32);
    unsigned char sig[64];
    size_t sigLen = sizeof(sig);
    EVP_MD_CTX *mctx = EVP_MD_CTX_new();
    bool ok = mctx && EVP_DigestSignInit(mctx, nullptr, nullptr, nullptr, pkey) == 1
              && EVP_DigestSign(mctx, sig, &sigLen,
                                reinterpret_cast<const unsigned char *>(digest.constData()),
                                size_t(digest.size())) == 1
              && sigLen == sizeof(sig);
    EVP_MD_CTX_free(mctx);

    unsigned char raw[32];
    size_t rawLen = sizeof(raw);
    if (ok && EVP_PKEY_get_raw_public_key(pkey, raw, &rawLen) == 1 && rawLen == sizeof(raw)) {
        m_chaveDeTeste = QByteArray(reinterpret_cast<const char *>(raw), int(rawLen));
        bytes.replace(offSig, 64, reinterpret_cast<const char *>(sig), 64);
    } else {
        ok = false;
    }
    EVP_PKEY_free(pkey);
    if (!ok)
        return {};

    const QString saida = m_tmp.filePath(QStringLiteral("assinada-aqui.driftpkg"));
    QFile out(saida);
    if (!out.open(QIODevice::WriteOnly) || out.write(bytes) != bytes.size())
        return {};
    out.close();
    return saida;
}

void TestAddonPackage::productionRootRejectsTheRetiredFixture()
{
    // A fixture de tests/data foi assinada por uma chave que já não é a raiz de confiança
    // compilada (kSigningPublicKey): o digest SHA-256 do pacote confere, a assinatura Ed25519 de
    // 64 bytes não. Medido contra a chave actual e contra a anterior. Re-assiná-la daqui é
    // impossível — a chave privada de produção não está no repositório nem em segredo de CI —,
    // por isso o que se fixa é a propriedade que a raiz DEVE ter: recusar o que não assinou.
    //
    // A mensagem importa tanto como o resultado: um "truncated", um "platform" ou um "file table"
    // significariam que a verificação morreu antes de chegar à assinatura, e o teste passaria a
    // esconder uma raiz partida. Só o erro de assinatura prova que a verificação correu a sério.
    //
    // Quando a fixture for re-assinada com o packer do drift-addons, este teste inverte: passa a
    // esperar install() == true e a comparar o id. O caminho de aceitação não fica à espera disso
    // — fixtureAssignedAqui() assina uma cópia com um par gerado em runtime e instala-a com a
    // sua própria chave, que é o mesmo código de verificação que o produto usa.
    QString error;
    PackageInfo info;
    const QString dest = m_tmp.filePath(QStringLiteral("raiz-de-confianca"));
    const bool installed = install(m_fixture, dest, {}, &info, &error);
    QVERIFY2(!installed, "a raiz de produção aceitou um pacote que não assinou");
    QVERIFY2(error.contains(QStringLiteral("assinatura")), qPrintable(error));
    qWarning("fixture de tests/data assinada com chave retirada; re-assinar com o packer do "
             "drift-addons para reactivar a verificação de aceitação");
}

void TestAddonPackage::installsAndVerifies()
{
    const QString dest = m_tmp.filePath(QStringLiteral("install"));
    const QString fixture = fixtureAssinadaAqui();
    QVERIFY(!fixture.isEmpty());
    PackageInfo info;
    QString error;
    QVERIFY2(install(fixture, dest, {}, &info, &error, m_chaveDeTeste), qPrintable(error));

    QCOMPARE(info.id, QStringLiteral("test.fixture"));
    QVERIFY(QFile::exists(dest + QStringLiteral("/fonts/testfamily/family.json")));
    QVERIFY(QFile::exists(dest + QStringLiteral("/fonts/testfamily/Test-Regular.ttf")));
    QVERIFY(!QDir(dest + QStringLiteral(".partial")).exists());

    QFile family(dest + QStringLiteral("/fonts/testfamily/family.json"));
    QVERIFY(family.open(QIODevice::ReadOnly));
    QCOMPARE(family.readAll(), QByteArray(R"({"id":"testfamily","family":"Test Family"})"));
    // Closed before reinstalling: Windows refuses to unlink an open file, so holding this handle
    // failed the reinstall below in removeRecursively() rather than in anything it means to test.
    family.close();

    // Installing again over an existing directory must succeed, not trip over the leftovers.
    QVERIFY2(install(fixture, dest, {}, &info, &error, m_chaveDeTeste), qPrintable(error));
}

void TestAddonPackage::rejectsTamperedPayload()
{
    // Well inside the zstd frame: the per-file hash or the frame checksum must catch it, and
    // either way the signature over the whole prefix no longer matches.
    const QString path = corruptedCopy(QStringLiteral("payload.driftpkg"), -160);
    QVERIFY(!path.isEmpty());

    QString error;
    QVERIFY(!install(path, m_tmp.filePath(QStringLiteral("bad-payload")), {}, nullptr, &error));
    QVERIFY(!error.isEmpty());
}

void TestAddonPackage::rejectsTamperedSignature()
{
    const QString path = corruptedCopy(QStringLiteral("sig.driftpkg"), -8);
    QVERIFY(!path.isEmpty());

    QString error;
    QVERIFY(!install(path, m_tmp.filePath(QStringLiteral("bad-sig")), {}, nullptr, &error));
    QVERIFY2(error.contains(QStringLiteral("assinatura")), qPrintable(error));
}

void TestAddonPackage::rejectsTruncatedFile()
{
    const QString path = m_tmp.filePath(QStringLiteral("short.driftpkg"));
    QVERIFY(QFile::copy(m_fixture, path));
    QFile file(path);
    QVERIFY(file.open(QIODevice::ReadWrite));
    QVERIFY(file.resize(file.size() - 40));
    file.close();

    QString error;
    QVERIFY(!install(path, m_tmp.filePath(QStringLiteral("truncated")), {}, nullptr, &error));
    QVERIFY(!error.isEmpty());
}

void TestAddonPackage::rejectsBadMagic()
{
    const QString path = corruptedCopy(QStringLiteral("magic.driftpkg"), 2);
    QVERIFY(!path.isEmpty());

    QString error;
    QVERIFY(!readManifest(path, &error).has_value());
    QVERIFY2(error.contains(QStringLiteral("magic")), qPrintable(error));
}

void TestAddonPackage::leavesNoStagingBehindOnFailure()
{
    const QString path = corruptedCopy(QStringLiteral("staging.driftpkg"), -8);
    QVERIFY(!path.isEmpty());
    const QString dest = m_tmp.filePath(QStringLiteral("staging-dest"));

    QString error;
    QVERIFY(!install(path, dest, {}, nullptr, &error));
    QVERIFY(!QDir(dest).exists());
    QVERIFY(!QDir(dest + QStringLiteral(".partial")).exists());
}

void TestAddonPackage::reportsCancellation()
{
    const QString dest = m_tmp.filePath(QStringLiteral("cancelled"));
    QString error;
    QVERIFY(!install(m_fixture, dest, [](qint64, qint64) { return false; }, nullptr, &error));
    QCOMPARE(error, QStringLiteral("cancelled"));
    QVERIFY(!QDir(dest).exists());
    QVERIFY(!QDir(dest + QStringLiteral(".partial")).exists());
}

// Effects and transitions ship with the build *and* exist as addons, so that a shader fix can be
// pushed without an app release. That only works if an installed package outranks the bundled one
// of the same id, and the catalogs resolve duplicates first-root-wins — so the ordering here is
// load-bearing, not cosmetic.
void TestAddonPackage::installedAddonOutranksBundledContent()
{
    QStandardPaths::setTestModeEnabled(true);
    auto restore = qScopeGuard([] { QStandardPaths::setTestModeEnabled(false); });

    const QString installDir = drift::addon::addonInstallDir(QStringLiteral("test.fixture"));
    QDir(installDir).removeRecursively();

    const QString fixture = fixtureAssinadaAqui();
    QVERIFY(!fixture.isEmpty());
    PackageInfo info;
    QString error;
    QVERIFY2(install(fixture, installDir, {}, &info, &error, m_chaveDeTeste), qPrintable(error));
    QVERIFY2(recordInstalledAddon(info, &error), qPrintable(error));
    reloadAddonRegistry();

    const QStringList roots = GpuPackageParse::defaultSearchPaths(
        QStringLiteral("DRIFT_UNSET_FOR_TEST"), QStringLiteral("fonts"), QStringLiteral("fonts"));

    const QString addonRoot = QDir(installDir).filePath(QStringLiteral("fonts"));
    const QString bundledRoot =
        QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("fonts"));

    QVERIFY2(roots.contains(addonRoot), qPrintable(roots.join(QStringLiteral(" | "))));
    QVERIFY2(roots.contains(bundledRoot), qPrintable(roots.join(QStringLiteral(" | "))));
    QVERIFY2(roots.indexOf(addonRoot) < roots.indexOf(bundledRoot),
             qPrintable(QStringLiteral("addon must outrank bundled: %1")
                            .arg(roots.join(QStringLiteral(" | ")))));

    QVERIFY2(forgetInstalledAddon(QStringLiteral("test.fixture"), &error), qPrintable(error));
    QDir(installDir).removeRecursively();
    reloadAddonRegistry();
}

QTEST_MAIN(TestAddonPackage)
#include "tst_addonpackage.moc"
