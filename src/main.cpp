#include "engine/AudioFileWriter.h"
#include "engine/EmojiCatalog.h"
#include "engine/FontCatalog.h"
#include "engine/ReverseProxyCache.h"
#ifndef Q_OS_ANDROID
#include "mcp/McpStdio.h"
#endif
#include "models/AddonManager.h"
#include "models/AppController.h"
#include "models/AssetLibrary.h"
#include "models/EditorState.h"
#include "models/FileDialogs.h"
#include "models/Haptics.h"
#include "models/LayoutStore.h"
#include "models/UpdateChecker.h"
#include "engine/VaapiZeroCopy.h"
#include "ClipPreviewImageProvider.h"
#include "DriftImageProvider.h"
#include "MulticamImageProvider.h"
#include "SegmentImageProvider.h"
#include "TextStylePreviewImageProvider.h"
#include "preview/PreviewItem.h"

// QApplication (not QGuiApplication) is required so QFileDialog can use the
// native platform file picker, which routes through xdg-desktop-portal.
#include <QApplication>
#include <QCoreApplication>
#include <QDirIterator>
#include <QEvent>
#include <QFileOpenEvent>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QIcon>
#include <QImageReader>
#include <QLoggingCategory>
#include <QQmlAbstractUrlInterceptor>
#include <QQmlApplicationEngine>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QSurfaceFormat>
#include <QTimer>
#include <QtQml/qqml.h>
#include <QFile>

#ifdef Q_OS_ANDROID
#include "core/Project.h"
#include "engine/FrameCompositor.h"

#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStandardPaths>
#endif

extern "C" {
#include <libavutil/log.h>
}

namespace {

bool verboseLoggingRequested(int argc, char *argv[])
{
    if (qEnvironmentVariableIntValue("DRIFT_VERBOSE") != 0)
        return true;
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--verbose") == 0)
            return true;
    }
    return false;
}

QString devQmlDirectory()
{
    const QString configured = qEnvironmentVariable("NARDOTO_QML_DEV_DIR").trimmed();
    if (configured.isEmpty())
        return {};

    const QDir directory(configured);
    if (!QFileInfo::exists(directory.filePath(QStringLiteral("Main.qml")))) {
        qWarning("QML de desenvolvimento não encontrado em %s", qPrintable(configured));
        return {};
    }
    return directory.absolutePath();
}

class DevQmlUrlInterceptor final : public QQmlAbstractUrlInterceptor
{
public:
    explicit DevQmlUrlInterceptor(QString sourceDirectory)
        : m_sourceDirectory(sourceDirectory)
    {
    }

    QUrl intercept(const QUrl &url, DataType) override
    {
        static constexpr auto resourcePrefix = "/qt/qml/Drift/";
        if (url.scheme() != QLatin1String("qrc") || !url.path().startsWith(resourcePrefix))
            return url;

        const QString relativePath = url.path().mid(qstrlen(resourcePrefix));
        const QString localPath = QDir(m_sourceDirectory).filePath(relativePath);
        return QFileInfo::exists(localPath) ? QUrl::fromLocalFile(localPath) : url;
    }

private:
    QString m_sourceDirectory;
};

// FFmpeg logs at INFO and Qt prints every qDebug/qInfo, which buries the failures worth acting on
// under per-frame filtergraph chatter. qWarning is this codebase's failure channel, so it stays on
// either way. QT_LOGGING_RULES is applied after these (EnvironmentRules outrank ApiRules), so it
// still overrides them.
void applyLogLevel(bool verbose)
{
    QLoggingCategory::setFilterRules(verbose
                                         ? QStringLiteral("*.debug=true\n"
                                                          "*.info=true\n"
                                                          "qt.*.debug=false")
                                         : QStringLiteral("*.debug=false\n"
                                                          "*.info=false"));
    av_log_set_level(verbose ? AV_LOG_VERBOSE : AV_LOG_ERROR);
}

class FileOpenFilter : public QObject
{
public:
    explicit FileOpenFilter(AppController *controller, QObject *parent = nullptr)
        : QObject(parent)
        , m_controller(controller)
    {
    }

protected:
    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (event->type() == QEvent::FileOpen) {
            const auto *open = static_cast<QFileOpenEvent *>(event);
            m_controller->queueExternalProject(open->url());
            return true;
        }
        return QObject::eventFilter(watched, event);
    }

private:
    AppController *m_controller = nullptr;
};

#ifdef Q_OS_ANDROID
// On-device render check. With <AppDataLocation>/selftest.json in place, composite one frame and
// write selftest.png beside it instead of starting the UI. This is tools/renderframe moved onto
// the device: it exercises FFmpeg decode, the GLES offscreen context, the shader translation and
// package discovery with no QML, no preview item and no clock in the way.
bool runSelfTest()
{
    QString dir;
    QString projectPath;
    const QStringList candidates =
        QStandardPaths::standardLocations(QStandardPaths::AppDataLocation);
    for (const QString &candidate : candidates) {
        const QString path = QDir(candidate).filePath(QStringLiteral("selftest.json"));
        if (QFile::exists(path)) {
            dir = candidate;
            projectPath = path;
            break;
        }
    }

    if (projectPath.isEmpty()) {
        qWarning("selftest: no selftest.json in any of: %s",
                 qPrintable(candidates.join(QLatin1String(", "))));
        return false;
    }

    qWarning("selftest: loading %s", qPrintable(projectPath));

    QFile file(projectPath);
    if (!file.open(QIODevice::ReadOnly)) {
        qWarning("selftest: cannot open %s", qPrintable(projectPath));
        return true;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    if (!doc.isObject()) {
        qWarning("selftest: not a JSON object");
        return true;
    }

    QString error;
    drift::Project project = drift::Project::fromJson(doc.object(), &error);
    if (!error.isEmpty()) {
        qWarning("selftest: project load failed: %s", qPrintable(error));
        return true;
    }

    const drift::TimeUs timeUs = qEnvironmentVariableIntValue("DRIFT_SELFTEST_TIME_US");

    FrameCompositor compositor;
    compositor.setProject(&project);
    const QImage frame = compositor.compositeAt(timeUs);
    if (frame.isNull()) {
        qWarning("selftest: compositor returned an empty frame at %lld us",
                 static_cast<long long>(timeUs));
        return true;
    }

    const QString outPath = QDir(dir).filePath(QStringLiteral("selftest.png"));
    if (!frame.save(outPath))
        qWarning("selftest: failed to write %s", qPrintable(outPath));
    else
        qWarning("selftest: wrote %s (%dx%d)", qPrintable(outPath), frame.width(), frame.height());

    return true;
}
#endif // Q_OS_ANDROID

} // namespace

int main(int argc, char *argv[])
{
    applyLogLevel(verboseLoggingRequested(argc, argv));

    bool mcpEnableRequested = false;
#ifndef Q_OS_ANDROID
    for (int i = 1; i < argc; ++i) {
        if (qstrcmp(argv[i], "--mcp-stdio") == 0) {
            QCoreApplication app(argc, argv);
            QCoreApplication::setApplicationName("Nardoto Editor");
            QCoreApplication::setOrganizationName("Nardoto");
            return drift::mcp::runStdioAttach();
        }
        if (qstrcmp(argv[i], "--mcp-enable") == 0)
            mcpEnableRequested = true;
    }
#endif

#ifdef Q_OS_ANDROID
    // Android is GLES-only; the desktop 3.3 core profile the engine asks for cannot be created
    // here at all. Both contexts that matter — the Qt Quick scene graph's and the compositor's
    // offscreen one in GlRuntime — must agree on the version before they can share textures.
    QSurfaceFormat androidFormat;
    androidFormat.setRenderableType(QSurfaceFormat::OpenGLES);
    androidFormat.setVersion(3, 0);
    androidFormat.setDepthBufferSize(0);
    androidFormat.setStencilBufferSize(0);
    QSurfaceFormat::setDefaultFormat(androidFormat);
#else
    // On NVIDIA/Wayland, leaving the API unspecified makes EGL interpret 3.3
    // as an invalid GLES version and fail with EGL_BAD_MATCH. Start from the
    // default format to retain the platform-selected window-buffer attributes.
    QSurfaceFormat format = QSurfaceFormat::defaultFormat();
    format.setRenderableType(QSurfaceFormat::OpenGL);
    format.setVersion(3, 3);
    format.setProfile(QSurfaceFormat::CoreProfile);
    QSurfaceFormat::setDefaultFormat(format);
#endif

    // Keep Qt Quick on OpenGL and create its global share context before the
    // application, enabling zero-copy texture handoff from the compositor.
    QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    QCoreApplication::setAttribute(Qt::AA_ShareOpenGLContexts);

#ifdef Q_OS_WIN
    // DirectWrite mis-maps glyphs in the qrc-embedded Inter used by Theme.fontFamily
    // (neighbouring letters, stray diacritics). FreeType renders the same file correctly.
    // An explicit QT_QPA_PLATFORM from the environment still wins.
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
        qputenv("QT_QPA_PLATFORM", "windows:fontengine=freetype");
#endif

    // Names must be set before reading QSettings for ui/scale, and QT_SCALE_FACTOR
    // must be in the environment before QApplication is constructed.
    QCoreApplication::setApplicationName("Nardoto Editor");
    QCoreApplication::setOrganizationName("Nardoto");
    AppController::applyStoredUiScale();
    // Qt's xcb plugin defaults to GLX, so eglGetCurrentDisplay() is null and
    // zero-copy sticky-disables. Only force EGL when the user opted in — default
    // X11 behaviour stays byte-identical. An explicit QT_XCB_GL_INTEGRATION still wins.
    drift::applyVaapiZeroCopyXcbEgl();

    QApplication app(argc, argv);
    if (!QImageReader::supportedImageFormats().contains("svg")) {
        qWarning("SVG icons will not display: Qt's SVG image plugin is missing or built "
                 "for a different Qt version than this binary. Install a matching qt6-svg "
                 "(same version as qt6-base).");
    }
    // Associates the window with the installed .desktop entry so shells (notably
    // Wayland) can find its icon and app metadata.
    QGuiApplication::setDesktopFileName(QStringLiteral("com.nardoto.Editor"));
    // Title bar / taskbar icon when no desktop entry is available (Windows, and
    // Linux runs from the build tree). The .exe still needs the Windows .rc icon
    // for Explorer and pinned-taskbar identity.
    QApplication::setWindowIcon(QIcon(QStringLiteral(":/app/nardoto-editor.png")));

    // qsTr/tr resolve when the QML engine loads, so translators must be installed first.
    // Protocol strings under src/mcp/ are excluded from the catalog; they stay English.
    AppController::installUiTranslators();

    // Registering the bundled fonts needs a QGuiApplication, and must happen before the compositor
    // thread starts touching QFontDatabase.
    reloadFontCatalog();
    reloadEmojiCatalog();

    // Noise-removal A/B snippets are scratch. Anything still here is from a previous session that
    // did not get to clean up after itself.
    drift::sweepDenoisePreviews();

#ifdef Q_OS_ANDROID
    // Every content:// write is staged through <cache>/staged and unlinked once the copy into the
    // document finishes, so a file still here is debris from an encode that was killed.
    {
        QDir staged(QStandardPaths::writableLocation(QStandardPaths::CacheLocation)
                    + QStringLiteral("/staged"));
        const QFileInfoList leftovers = staged.entryInfoList(QDir::Files);
        for (const QFileInfo &file : leftovers)
            QFile::remove(file.absoluteFilePath());
    }

    qWarning("app data locations: %s",
             qPrintable(QStandardPaths::standardLocations(QStandardPaths::AppDataLocation)
                            .join(QLatin1String(", "))));
    if (runSelfTest())
        return 0;
#endif

    // Reversed proxies are a pure cache: dropping one only costs the clip its smooth playback, so
    // they are pruned to a budget rather than kept forever the way mattes are.
    drift::ReverseProxyCache::instance().load();
    drift::ReverseProxyCache::instance().sweep(drift::ReverseProxyCache::kDefaultMaxBytes);

    qmlRegisterType<PreviewItem>("Drift", 1, 0, "PreviewItem");

    static AssetLibrary assetLibrary;
    static EditorState editorState(&assetLibrary);
    static FileDialogs fileDialogs;
    static AddonManager addonManager;
    static UpdateChecker updateChecker;
    static LayoutStore layoutStore;
    static drift::Haptics haptics;
    editorState.setAddonManager(&addonManager);
    qmlRegisterSingletonInstance("Drift", 1, 0, "AssetLibrary", &assetLibrary);
    qmlRegisterSingletonInstance("Drift", 1, 0, "BinFolderModel", editorState.binFolderModel());
    qmlRegisterSingletonInstance("Drift", 1, 0, "EditorState", &editorState);
    qmlRegisterSingletonInstance("Drift", 1, 0, "AppController", &editorState);
    qmlRegisterSingletonInstance("Drift", 1, 0, "FileDialogs", &fileDialogs);
    qmlRegisterSingletonInstance("Drift", 1, 0, "Addons", &addonManager);
    qmlRegisterSingletonInstance("Drift", 1, 0, "Updates", &updateChecker);
    qmlRegisterSingletonInstance("Drift", 1, 0, "LayoutMemory", &layoutStore);
    qmlRegisterSingletonInstance("Drift", 1, 0, "Haptics", &haptics);

    app.installEventFilter(new FileOpenFilter(&editorState, &app));
    editorState.queueExternalProject(
        AppController::startupProjectUrlFromArguments(app.arguments()));

    const QString qmlDevDirectory = devQmlDirectory();
    const QUrl desktopMainQml = qmlDevDirectory.isEmpty()
        ? QUrl{}
        : QUrl::fromLocalFile(QDir(qmlDevDirectory).filePath(QStringLiteral("Main.qml")));
    QQmlApplicationEngine engine;
    DevQmlUrlInterceptor qmlDevInterceptor(qmlDevDirectory);
    if (!qmlDevDirectory.isEmpty())
        engine.setUrlInterceptor(&qmlDevInterceptor);
    QObject::connect(&editorState, &AppController::uiLanguageChanged,
                     &engine, &QQmlEngine::retranslate);
    engine.addImageProvider(QStringLiteral("drift"), new DriftImageProvider());
    engine.addImageProvider(QStringLiteral("segment"), new SegmentImageProvider());
    engine.addImageProvider(QStringLiteral("clippreview"), new ClipPreviewImageProvider());
    engine.addImageProvider(QStringLiteral("multicam"), new MulticamImageProvider());
    engine.addImageProvider(QStringLiteral("textstyle"), new TextStylePreviewImageProvider());
    if (qmlDevDirectory.isEmpty()) {
        QObject::connect(
            &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
            [] { QGuiApplication::exit(-1); }, Qt::QueuedConnection);
    } else {
        QObject::connect(
            &engine, &QQmlApplicationEngine::objectCreationFailed,
            [] { qWarning("A recarga do QML de desenvolvimento falhou; a interface anterior foi mantida."); });
    }
    // Main.qml is the desktop layout. AndroidMain.qml is the touch entry point; the desktop tree
    // stays compiled so the touch port can reuse leaf components.
#ifdef Q_OS_ANDROID
    engine.loadFromModule("Drift", "AndroidMain");
#else
    if (qmlDevDirectory.isEmpty())
        engine.loadFromModule("Drift", "Main");
    else
        engine.load(desktopMainQml);

    // Aberto pelo chat do Nardoto Studio: o Acesso de agente já nasce ligado, sem a pessoa
    // mexer no interruptor nem copiar configuração. Sem a flag, continua desligado como antes.
    if (mcpEnableRequested)
        editorState.setMcpEnabled(true);
#endif

#ifndef Q_OS_ANDROID
    if (!qmlDevDirectory.isEmpty()) {
        auto *qmlDevWatcher = new QFileSystemWatcher(&app);
        auto *qmlDevReloadTimer = new QTimer(&app);
        qmlDevReloadTimer->setSingleShot(true);
        qmlDevReloadTimer->setInterval(180);

        const auto trackQmlFiles = [qmlDevWatcher, &qmlDevDirectory] {
            QStringList paths;
            paths.append(qmlDevDirectory);

            QDirIterator iterator(qmlDevDirectory, {QStringLiteral("*.qml")}, QDir::Files,
                                  QDirIterator::Subdirectories);
            while (iterator.hasNext())
                paths.append(iterator.next());

            QDirIterator directoryIterator(qmlDevDirectory, QDir::Dirs | QDir::NoDotAndDotDot,
                                           QDirIterator::Subdirectories);
            while (directoryIterator.hasNext())
                paths.append(directoryIterator.next());

            QStringList missing;
            const QStringList watched = qmlDevWatcher->files() + qmlDevWatcher->directories();
            for (const QString &path : paths) {
                if (!watched.contains(path))
                    missing.append(path);
            }
            if (!missing.isEmpty())
                qmlDevWatcher->addPaths(missing);
        };

        trackQmlFiles();
        const auto requestQmlReload = [&trackQmlFiles, qmlDevReloadTimer](const QString &) {
            trackQmlFiles();
            qmlDevReloadTimer->start();
        };
        QObject::connect(qmlDevWatcher, &QFileSystemWatcher::fileChanged, &app, requestQmlReload);
        QObject::connect(qmlDevWatcher, &QFileSystemWatcher::directoryChanged, &app, requestQmlReload);
        QObject::connect(qmlDevReloadTimer, &QTimer::timeout, &app,
                         [&engine, desktopMainQml] {
                             // Limpa primeiro apenas o cache de compilação. Os objetos QML atuais
                             // continuam vivos, para uma edição inválida não deixar o editor sem
                             // janela.
                             engine.clearComponentCache();
                             QQmlComponent candidate(&engine, desktopMainQml);
                             if (candidate.isError()) {
                                 for (const QQmlError &error : candidate.errors())
                                     qWarning("QML de desenvolvimento: %s", qPrintable(error.toString()));
                                 return;
                             }

                             const auto roots = engine.rootObjects();
                             for (QObject *root : roots)
                                 root->deleteLater();
                             QCoreApplication::sendPostedEvents(nullptr, QEvent::DeferredDelete);
                             engine.load(desktopMainQml);
                         });
        qInfo("QML de desenvolvimento ativo: %s", qPrintable(qmlDevDirectory));
    }
#endif

    return app.exec();
}
