#pragma once

#include <QObject>
#include <QString>

class QNetworkAccessManager;

// Asks GitHub once a day whether there is a newer release than this build, and raises a badge in
// the header when there is. On Windows the release carries the app's own installer, so the badge
// leads to a real update: the installer is downloaded here, the editor closes through its normal
// unsaved-changes prompt, and the installer runs (silent, then relaunches the editor). Elsewhere
// the honest end of the flow is still the release page in the user's browser.
//
// Builds that a package manager owns are configured with an empty DRIFT_UPDATE_FEED_URL and get
// none of this — see supported(). NARDOTO_UPDATE_FEED_URL in the environment overrides the feed,
// which is how the whole path is exercised against a local server before a release exists.
class UpdateChecker : public QObject
{
    Q_OBJECT
    // False when the build was configured with an empty feed URL. The badge and the settings row
    // are both hidden then, rather than showing a control that can never do anything.
    Q_PROPERTY(bool supported READ supported CONSTANT)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(bool checking READ checking NOTIFY checkingChanged)
    Q_PROPERTY(bool updateAvailable READ updateAvailable NOTIFY resultChanged)
    Q_PROPERTY(QString currentVersion READ currentVersion CONSTANT)
    Q_PROPERTY(QString latestVersion READ latestVersion NOTIFY resultChanged)
    // The release's Markdown body, rendered as Markdown by the dialog.
    Q_PROPERTY(QString releaseNotes READ releaseNotes NOTIFY resultChanged)
    Q_PROPERTY(QString releaseUrl READ releaseUrl NOTIFY resultChanged)
    // Result of the last check in one line, for the settings row. Empty until something is worth
    // saying; a failed background check says nothing at all.
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    // True when the release ships an installer this platform can run (Windows). The dialog then
    // offers to update in place instead of opening the release page.
    Q_PROPERTY(bool canInstall READ canInstall NOTIFY resultChanged)
    Q_PROPERTY(bool downloading READ downloading NOTIFY downloadChanged)
    Q_PROPERTY(double downloadProgress READ downloadProgress NOTIFY downloadChanged)
    // The installer is on disk and runs as soon as the editor quits.
    Q_PROPERTY(bool installerReady READ installerReady NOTIFY downloadChanged)

public:
    explicit UpdateChecker(QObject *parent = nullptr);
    ~UpdateChecker() override;

    bool supported() const;
    bool enabled() const;
    void setEnabled(bool enabled);
    bool checking() const;
    bool updateAvailable() const;
    QString currentVersion() const;
    QString latestVersion() const;
    QString releaseNotes() const;
    QString releaseUrl() const;
    QString status() const;
    bool canInstall() const;
    bool downloading() const;
    double downloadProgress() const;
    bool installerReady() const;

    // User pressed "Check now": ignores the once-a-day throttle and the skipped version, and
    // reports failures and "you are up to date" through status().
    Q_INVOKABLE void checkNow();

    // Stops this version being advertised again. The next release clears it by being newer.
    Q_INVOKABLE void skipVersion();

    Q_INVOKABLE void openDownloadPage();

    // Downloads the installer; when it is on disk, installerReady flips and the main window
    // closes itself. Without an installer for this platform, falls back to the release page.
    Q_INVOKABLE void downloadAndInstall();

signals:
    void enabledChanged();
    void checkingChanged();
    void resultChanged();
    void statusChanged();
    void downloadChanged();

private:
    void check(bool manual);
    void applyRelease(const QByteArray &json, bool manual);
    void setChecking(bool checking);
    void setStatus(const QString &status);
    void launchPendingInstaller();

    bool m_checking = false;
    QString m_latestVersion;
    QString m_releaseNotes;
    QString m_releaseUrl;
    QString m_installerUrl;
    QString m_installerPath;
    QString m_skippedVersion;
    QString m_status;
    bool m_downloading = false;
    double m_downloadProgress = 0.0;
    QNetworkAccessManager *m_network = nullptr;
};
