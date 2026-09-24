#include "UpdateChecker.h"

#include "VersionCompare.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSettings>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <shellapi.h>
#endif

// Configured in CMakeLists.txt (DRIFT_UPDATE_FEED_URL) and injected as a compile definition, the
// same way the addon service is, so a fork points at its own repository without touching code.
// A translation unit built outside the `drift` target gets no feed rather than a stale one.
#ifndef DRIFT_UPDATE_FEED_URL
#define DRIFT_UPDATE_FEED_URL ""
#endif

namespace {

// Once a day. The feed is GitHub's own API and the check is a single conditional-ish GET, but
// there is no reason to ask more often than releases happen.
constexpr qint64 kCheckIntervalSeconds = 24 * 60 * 60;

// Long enough that the first frame, the project restore and the addon index refresh are all past
// before a socket is opened. Nothing in the app waits on this.
constexpr int kStartupDelayMs = 5000;

constexpr int kTransferTimeoutMs = 15000;
// The installer is ~90 MB; this is an inactivity timeout, not a total one.
constexpr int kDownloadTimeoutMs = 60000;

// Name of the Windows installer asset in every release (installer/windows/nardoto-editor.nsi).
const QString kInstallerAssetName = QStringLiteral("NardotoEditor-Setup-x64.exe");
const QString kCurrentVersion = QStringLiteral(DRIFT_VERSION);

QString feedUrl()
{
    const QByteArray override = qgetenv("NARDOTO_UPDATE_FEED_URL");
    return override.isEmpty() ? QStringLiteral(DRIFT_UPDATE_FEED_URL) : QString::fromUtf8(override);
}

QString settingsKey(const char *name)
{
    return QLatin1String("updates/") + QLatin1String(name);
}

void prepareGithubRequest(QNetworkRequest &request, int timeoutMs)
{
    // GitHub's API rejects requests that send no User-Agent, and pins response shape to an API
    // version so a future default cannot change the fields parsed below.
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QLatin1String("NardotoEditor/") + kCurrentVersion);
    request.setRawHeader("Accept", "application/vnd.github+json");
    request.setRawHeader("X-GitHub-Api-Version", "2022-11-28");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(timeoutMs);
}

} // namespace

UpdateChecker::UpdateChecker(QObject *parent)
    : QObject(parent), m_network(new QNetworkAccessManager(this))
{
    m_skippedVersion = QSettings().value(settingsKey("skippedVersion")).toString();

    // The installer only starts once the editor is really gone: it refuses to copy over a
    // running executable, and quitting here goes through the unsaved-changes prompt first.
    if (auto *app = QCoreApplication::instance())
        connect(app, &QCoreApplication::aboutToQuit, this, &UpdateChecker::launchPendingInstaller);

    if (!supported() || !enabled())
        return;

    const QDateTime last = QSettings().value(settingsKey("lastCheck")).toDateTime();
    if (last.isValid() && last.secsTo(QDateTime::currentDateTimeUtc()) < kCheckIntervalSeconds)
        return;

    QTimer::singleShot(kStartupDelayMs, this, [this] { check(false); });
}

UpdateChecker::~UpdateChecker() = default;

bool UpdateChecker::supported() const
{
    return !feedUrl().isEmpty();
}

bool UpdateChecker::enabled() const
{
    return QSettings().value(settingsKey("enabled"), true).toBool();
}

void UpdateChecker::setEnabled(bool enabled)
{
    if (enabled == this->enabled())
        return;
    QSettings().setValue(settingsKey("enabled"), enabled);
    emit enabledChanged();
}

bool UpdateChecker::checking() const
{
    return m_checking;
}

bool UpdateChecker::updateAvailable() const
{
    return !m_latestVersion.isEmpty() && m_latestVersion != m_skippedVersion;
}

QString UpdateChecker::currentVersion() const
{
    return kCurrentVersion;
}

QString UpdateChecker::latestVersion() const
{
    return m_latestVersion;
}

QString UpdateChecker::releaseNotes() const
{
    return m_releaseNotes;
}

QString UpdateChecker::releaseUrl() const
{
    return m_releaseUrl;
}

QString UpdateChecker::status() const
{
    return m_status;
}

bool UpdateChecker::canInstall() const
{
    return !m_installerUrl.isEmpty();
}

bool UpdateChecker::downloading() const
{
    return m_downloading;
}

double UpdateChecker::downloadProgress() const
{
    return m_downloadProgress;
}

bool UpdateChecker::installerReady() const
{
    return !m_installerPath.isEmpty();
}

void UpdateChecker::setChecking(bool checking)
{
    if (m_checking == checking)
        return;
    m_checking = checking;
    emit checkingChanged();
}

void UpdateChecker::setStatus(const QString &status)
{
    if (m_status == status)
        return;
    m_status = status;
    emit statusChanged();
}

void UpdateChecker::checkNow()
{
    // Asking explicitly un-skips: the user wants to be told about whatever is out there.
    if (!m_skippedVersion.isEmpty()) {
        m_skippedVersion.clear();
        QSettings().remove(settingsKey("skippedVersion"));
    }
    check(true);
}

void UpdateChecker::skipVersion()
{
    if (m_latestVersion.isEmpty())
        return;
    m_skippedVersion = m_latestVersion;
    QSettings().setValue(settingsKey("skippedVersion"), m_skippedVersion);
    emit resultChanged();
}

void UpdateChecker::openDownloadPage()
{
    if (!m_releaseUrl.isEmpty())
        QDesktopServices::openUrl(QUrl(m_releaseUrl));
}

void UpdateChecker::downloadAndInstall()
{
    if (!canInstall()) {
        openDownloadPage();
        return;
    }
    // Already on disk: the window just needs to close again (the user may have cancelled the
    // unsaved-changes prompt the first time).
    if (installerReady()) {
        emit downloadChanged();
        return;
    }
    if (m_downloading)
        return;

    m_downloading = true;
    m_downloadProgress = 0.0;
    emit downloadChanged();
    setStatus(tr("Baixando o Nardoto Editor %1...").arg(m_latestVersion));

    QNetworkRequest request{QUrl(m_installerUrl)};
    prepareGithubRequest(request, kDownloadTimeoutMs);
    request.setRawHeader("Accept", "application/octet-stream");

    QNetworkReply *reply = m_network->get(request);
    connect(reply, &QNetworkReply::downloadProgress, this, [this](qint64 received, qint64 total) {
        m_downloadProgress = total > 0 ? double(received) / double(total) : 0.0;
        emit downloadChanged();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        m_downloading = false;

        if (reply->error() != QNetworkReply::NoError) {
            emit downloadChanged();
            setStatus(tr("Não foi possível baixar a atualização: %1").arg(reply->errorString()));
            return;
        }

        const QString dir = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
        const QString path = QDir(dir).filePath(kInstallerAssetName);
        QFile file(path);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)
            || file.write(reply->readAll()) < 0) {
            emit downloadChanged();
            setStatus(tr("Não foi possível gravar o instalador em %1").arg(path));
            return;
        }
        file.close();

        m_installerPath = path;
        m_downloadProgress = 1.0;
        emit downloadChanged();
        setStatus(tr("Instalador pronto. O editor vai fechar para atualizar."));
    });
}

// Runs the downloaded installer in update mode: no wizard, waits for this process to release the
// executable, and reopens the editor when done. Elevation comes from the installer's own manifest.
void UpdateChecker::launchPendingInstaller()
{
    if (m_installerPath.isEmpty())
        return;
#ifdef Q_OS_WIN
    const std::wstring path = QDir::toNativeSeparators(m_installerPath).toStdWString();
    ShellExecuteW(nullptr, L"open", path.c_str(), L"/ATUALIZAR", nullptr, SW_SHOWNORMAL);
#endif
    m_installerPath.clear();
}

void UpdateChecker::check(bool manual)
{
    if (m_checking || !supported())
        return;

    setChecking(true);
    setStatus(QString());

    QNetworkRequest request{QUrl(feedUrl())};
    prepareGithubRequest(request, kTransferTimeoutMs);

    QNetworkReply *reply = m_network->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, manual] {
        reply->deleteLater();
        setChecking(false);

        // A background check that failed says nothing: being offline is not an error the user
        // asked about. Only record the attempt when it actually reached GitHub, so a laptop that
        // launches offline all week still checks the day it has a connection.
        if (reply->error() != QNetworkReply::NoError) {
            if (manual)
                setStatus(tr("Couldn’t check for updates: %1").arg(reply->errorString()));
            return;
        }

        QSettings().setValue(settingsKey("lastCheck"), QDateTime::currentDateTimeUtc());
        applyRelease(reply->readAll(), manual);
    });
}

void UpdateChecker::applyRelease(const QByteArray &json, bool manual)
{
    const QJsonObject release = QJsonDocument::fromJson(json).object();

    // releases/latest already excludes drafts and pre-releases; the checks are here so a feed
    // that ever stops doing so cannot start advertising them.
    const QString tag = release.value(QStringLiteral("tag_name")).toString();
    const bool usable = !tag.isEmpty() && !release.value(QStringLiteral("draft")).toBool()
            && !release.value(QStringLiteral("prerelease")).toBool();
    if (!usable) {
        if (manual)
            setStatus(tr("Couldn’t check for updates: unexpected response."));
        return;
    }

    // Tags are "nardoto-v0.1.2" (the fork's own line; plain "v0.x" tags belong to the upstream
    // history): the version starts at the first digit, whatever the prefix.
    int firstDigit = 0;
    while (firstDigit < tag.size() && !tag.at(firstDigit).isDigit())
        ++firstDigit;
    const QString version = tag.mid(firstDigit);
    if (version.isEmpty() || drift::compareVersions(kCurrentVersion, version) >= 0) {
        // A previously-found update that has since been withdrawn stops being advertised.
        m_latestVersion.clear();
        m_releaseNotes.clear();
        m_releaseUrl.clear();
        m_installerUrl.clear();
        emit resultChanged();
        if (manual)
            setStatus(tr("Nardoto Editor %1 é a versão mais recente.").arg(kCurrentVersion));
        return;
    }

    m_latestVersion = version;
    m_releaseNotes = release.value(QStringLiteral("body")).toString();
    m_releaseUrl = release.value(QStringLiteral("html_url")).toString();
    m_installerUrl.clear();
#ifdef Q_OS_WIN
    const QJsonArray assets = release.value(QStringLiteral("assets")).toArray();
    for (const QJsonValue &asset : assets) {
        const QJsonObject object = asset.toObject();
        if (object.value(QStringLiteral("name")).toString() == kInstallerAssetName) {
            m_installerUrl = object.value(QStringLiteral("browser_download_url")).toString();
            break;
        }
    }
#endif
    emit resultChanged();
    if (manual)
        setStatus(tr("Nardoto Editor %1 está disponível.").arg(version));
}
