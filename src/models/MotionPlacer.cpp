#include "MotionPlacer.h"

#include "AppController.h"
#include "AssetLibrary.h"

#include <QTimer>

namespace {
constexpr int kEsperaMaximaMs = 15000;
}

MotionPlacer::MotionPlacer(AppController *controller, QObject *parent)
    : QObject(parent)
    , m_controller(controller)
{
}

void MotionPlacer::colocar(const QString &clipePath)
{
    AppController *controller = m_controller;
    AssetLibrary *lib = controller ? controller->assetLibrary() : nullptr;
    if (!lib) {
        emit erro(tr("No project is open to receive the motion graphic."));
        return;
    }

    const QStringList ids = lib->importLocalPaths({clipePath});
    if (ids.isEmpty()) {
        emit erro(tr("Could not import the motion graphic."));
        return;
    }
    const QString assetId = ids.first();
    // O playhead de agora, não o de quando a sondagem terminar.
    const double atSeconds = controller->playheadSeconds();

    const auto concluir = [this, lib, assetId, atSeconds, clipePath]() -> bool {
        if (!m_controller || lib->isImportPending(assetId))
            return false;
        const int index = lib->indexOfId(assetId);
        if (index < 0) {
            emit erro(tr("Could not import the motion graphic."));
            return true;
        }
        m_controller->addClipFromAssetOnNewTrack(index, atSeconds);
        emit colocado(clipePath);
        return true;
    };
    if (concluir())
        return;

    // Contexto próprio por pedido: desconecta tudo de uma vez ao terminar ou estourar o tempo.
    auto *espera = new QObject(this);
    auto *limite = new QTimer(espera);
    limite->setSingleShot(true);
    const auto encerrar = [lib, espera, limite] {
        limite->stop();
        QObject::disconnect(lib, nullptr, espera, nullptr);
        espera->deleteLater();
    };
    connect(lib, &AssetLibrary::assetMetadataChanged, espera, [concluir, encerrar] {
        if (concluir())
            encerrar();
    });
    connect(limite, &QTimer::timeout, espera, [this, encerrar] {
        emit erro(tr("The motion graphic took too long to import."));
        encerrar();
    });
    limite->start(kEsperaMaximaMs);
}
