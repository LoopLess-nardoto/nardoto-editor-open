#pragma once

#include <QObject>
#include <QPointer>

class AppController;

// Coloca o clipe.mov de um motion graphic na timeline: importa para o painel de mídia,
// espera a sondagem (a duração só é certa depois dela) e põe numa trilha nova no topo, no
// playhead. A espera é por sinal, sem QEventLoop na thread da interface.
class MotionPlacer : public QObject
{
    Q_OBJECT

public:
    explicit MotionPlacer(AppController *controller, QObject *parent = nullptr);

public slots:
    void colocar(const QString &clipePath);

signals:
    void colocado(const QString &clipePath);
    void erro(const QString &mensagem);

private:
    QPointer<AppController> m_controller;
};
