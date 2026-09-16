// Montagem de um vídeo narrado em uma única chamada: assemble_video.
//
// Espelha o que o Nardoto Studio já faz no CapCut (sync_engine / capcut_editor build): mídias
// na ordem em que chegam, tempo da narração dividido por igual entre elas, vídeo mais curto que
// a fatia mantém a duração natural, seis movimentos de câmera em rodízio nas imagens, música
// em loop com volume baixo abaixada sob a fala e a legenda pronta (SRT) por cima de tudo.
//
// Nada aqui abre caminho novo no AppController: a macro compõe as operações que já existem
// (import_media, place_clip, set_duration, set_keyframe, add_transition, duck_under,
// import_subtitle_file...) e fecha tudo num único passo de desfazer. Assim o chat monta um
// vídeo de quarenta cenas com uma chamada em vez de centenas, e a pessoa desfaz com um Ctrl+Z.
#include "mcp/McpDispatcher.h"
#include "mcp/McpJson.h"

#include "core/SrtIO.h"
#include "core/SubtitleCue.h"
#include "core/Time.h"
#include "models/AppController.h"

#include <QFileInfo>
#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>
#include <QUrl>
#include <QVariantMap>
#include <QVector>

#include <algorithm>
#include <cmath>
#include <limits>

namespace drift::mcp {
namespace {

// Este arquivo é uma continuação do McpDispatcher.cpp; os auxiliares do namespace anônimo de
// lá não são visíveis aqui, pela mesma razão do McpDispatcherExtended.cpp.
double numero(const QJsonValue &v, double fallback)
{
    return v.isDouble() ? v.toDouble() : fallback;
}

bool booleano(const QJsonValue &v, bool fallback)
{
    return v.isBool() ? v.toBool() : fallback;
}

QString texto(const QJsonObject &o, const char *chave)
{
    return o.value(QLatin1String(chave)).toString().trimmed();
}

QString caminhoLocal(const QString &bruto)
{
    const QString limpo = bruto.trimmed();
    if (limpo.startsWith(QLatin1String("file:")))
        return QUrl(limpo).toLocalFile();
    return limpo;
}

QStringList listaDeTextos(const QJsonValue &v)
{
    QStringList out;
    for (const QJsonValue &item : v.toArray()) {
        const QString s = item.toString().trimmed();
        if (!s.isEmpty())
            out.append(s);
    }
    return out;
}

bool sucesso(const QJsonObject &r)
{
    return r.value(QStringLiteral("ok")).toBool();
}

// Seis movimentos em rodízio por índice, os mesmos padrões do sync_engine do Studio. O quadro
// ampliado sempre cobre o canvas: com largura w(1+f), x pode ir de b.x - w*f (borda direita
// encostada) até b.x (borda esquerda encostada) sem mostrar fundo.
struct Quadro {
    double x = 0;
    double y = 0;
    double w = 0;
    double h = 0;
};

struct Movimento {
    Quadro de;
    Quadro para;
    const char *nome;
};

Movimento movimentoPara(int indice, const Quadro &b, double f)
{
    const double dx = b.w * f;
    const double dy = b.h * f;
    const double w = b.w * (1 + f);
    const double h = b.h * (1 + f);
    const Quadro centro{b.x - dx / 2, b.y - dy / 2, w, h};
    const Quadro esquerda{b.x - dx, b.y - dy / 2, w, h};
    const Quadro direita{b.x, b.y - dy / 2, w, h};
    const Quadro cantoSuperior{b.x, b.y, w, h};
    const Quadro cantoInferior{b.x - dx, b.y - dy, w, h};
    switch (indice % 6) {
    case 0:
        return {b, centro, "zoomIn"};
    case 1:
        return {centro, b, "zoomOut"};
    case 2:
        return {esquerda, direita, "panRight"};
    case 3:
        return {direita, esquerda, "panLeft"};
    case 4:
        return {b, cantoSuperior, "zoomInTopLeft"};
    default:
        return {cantoInferior, b, "zoomOutBottomRight"};
    }
}

} // namespace

QJsonObject McpDispatcher::applyOneAssemble(const QString &tool, const QJsonObject &args)
{
    if (tool == QLatin1String("assemble_video"))
        return opAssembleVideo(args);
    return err("unknown_op", tool);
}

QJsonObject McpDispatcher::opAssembleVideo(const QJsonObject &args)
{
    // --- 1. Argumentos: tudo conferido antes de encostar no projeto ---------------------
    QStringList midias;
    for (const QString &p : listaDeTextos(args.value(QStringLiteral("media"))))
        midias.append(caminhoLocal(p));
    if (midias.isEmpty())
        return err("bad_args", QStringLiteral("media required: at least one absolute image or video path"));

    const QString narracao = caminhoLocal(texto(args, "narration"));
    const QString legenda = caminhoLocal(texto(args, "subtitles"));
    const QString musica = caminhoLocal(texto(args, "music"));

    QString modo = texto(args, "media_mode").toLower();
    if (modo.isEmpty())
        modo = QStringLiteral("sequence");
    if (modo != QLatin1String("sequence") && modo != QLatin1String("cues"))
        return err("bad_args", QStringLiteral("media_mode must be sequence or cues"));
    if (modo == QLatin1String("cues") && legenda.isEmpty())
        return err("bad_args", QStringLiteral("media_mode cues needs subtitles"));

    const double duracaoImagem = numero(args.value(QStringLiteral("image_duration")), 5.0);
    if (duracaoImagem <= 0)
        return err("bad_args", QStringLiteral("image_duration must be > 0"));
    const double duracaoExplicita = std::max(0.0, numero(args.value(QStringLiteral("duration")), 0.0));

    QString movimento = texto(args, "motion").toLower();
    if (movimento.isEmpty())
        movimento = QStringLiteral("kenburns");
    if (movimento != QLatin1String("kenburns") && movimento != QLatin1String("none"))
        return err("bad_args", QStringLiteral("motion must be kenburns or none"));
    const double intensidade =
        std::clamp(numero(args.value(QStringLiteral("motion_amount")), 0.10), 0.01, 0.5);

    const QJsonObject transicao = args.value(QStringLiteral("transition")).toObject();
    const QStringList efeitos = listaDeTextos(args.value(QStringLiteral("effects")));
    const QString modeloDeEfeito = texto(args, "effect_template");

    const double volumeMusica =
        std::clamp(numero(args.value(QStringLiteral("music_volume")), 0.15), 0.0, 2.0);
    const bool abaixar = booleano(args.value(QStringLiteral("duck")), !narracao.isEmpty());
    const double quantoAbaixar =
        std::clamp(numero(args.value(QStringLiteral("duck_amount")), 0.3), 0.0, 1.0);
    const double fadeMusica = std::max(0.0, numero(args.value(QStringLiteral("music_fade_out")), 1.5));

    const QJsonObject titulo = args.value(QStringLiteral("title")).toObject();
    const QJsonObject canvas = args.value(QStringLiteral("canvas")).toObject();
    const QString presetLegenda = texto(args, "subtitle_preset");
    const QJsonObject estiloLegenda = args.value(QStringLiteral("subtitle_style")).toObject();

    QStringList faltando;
    auto conferir = [&](const QString &p) {
        if (!p.isEmpty() && !QFileInfo(p).isFile())
            faltando.append(p);
    };
    for (const QString &p : midias)
        conferir(p);
    conferir(narracao);
    conferir(legenda);
    conferir(musica);
    if (!faltando.isEmpty()) {
        QJsonObject e = err("not_found",
                            QStringLiteral("Some files do not exist. Search with your own filesystem "
                                           "tools and pass absolute paths; nothing was changed."));
        e.insert(QStringLiteral("missing"), QJsonArray::fromStringList(faltando));
        return e;
    }

    QList<SubtitleCue> cues;
    if (!legenda.isEmpty()) {
        QString erro;
        if (!parseSrtFile(legenda, &cues, &erro))
            return err("bad_args", QStringLiteral("Could not parse subtitles: %1").arg(erro));
        sortSubtitleCues(cues);
    }

    // --- 2. Um passo de desfazer para a montagem inteira ---------------------------------
    const QString rotulo = QStringLiteral("Montagem: %1 mídia(s)").arg(midias.size());
    m_controller->mcpBeginBatch();
    QJsonArray feito;
    QJsonArray avisos;
    auto rodar = [&](const char *tool, const QJsonObject &a) {
        const QJsonObject r = applyOne(QLatin1String(tool), a);
        feito.append(QJsonObject{{QStringLiteral("tool"), QLatin1String(tool)},
                                 {QStringLiteral("result"), r}});
        return r;
    };
    auto falhar = [&](const QJsonObject &r) {
        m_controller->mcpEndBatch(rotulo, feito.size() > 1);
        return QJsonObject{{QStringLiteral("ok"), false},
                           {QStringLiteral("error"), QStringLiteral("apply_failed")},
                           {QStringLiteral("stopped"), static_cast<int>(feito.size()) - 1},
                           {QStringLiteral("failed"), r},
                           {QStringLiteral("done"), feito}};
    };

    // Canvas: campo omitido herda do projeto.
    if (!canvas.isEmpty()) {
        const QJsonObject r = rodar(
            "set_project_setup",
            {{QStringLiteral("width"),
              static_cast<int>(numero(canvas.value(QStringLiteral("width")), m_controller->projectWidth()))},
             {QStringLiteral("height"),
              static_cast<int>(numero(canvas.value(QStringLiteral("height")), m_controller->projectHeight()))},
             {QStringLiteral("fps"),
              static_cast<int>(numero(canvas.value(QStringLiteral("fps")), m_controller->projectFps()))}});
        if (!sucesso(r))
            return falhar(r);
    }

    // Importa tudo numa chamada; os assets voltam na ordem dos caminhos.
    QStringList todos = midias;
    if (!narracao.isEmpty())
        todos.append(narracao);
    if (!musica.isEmpty())
        todos.append(musica);
    const QJsonObject importado =
        rodar("import_media", {{QStringLiteral("paths"), QJsonArray::fromStringList(todos)}});
    if (!sucesso(importado))
        return falhar(importado);
    const QJsonArray assets = importado.value(QStringLiteral("assets")).toArray();
    if (assets.size() != todos.size()) {
        return falhar(err("import_failed", QStringLiteral("Imported %1 of %2 files")
                                               .arg(assets.size())
                                               .arg(todos.size())));
    }

    struct Item {
        QString id;
        QString nome;
        QString tipo;
        double dur = 0;
    };
    auto itemEm = [&](int i) {
        const QJsonObject a = assets.at(i).toObject();
        return Item{a.value(QStringLiteral("id")).toString(), a.value(QStringLiteral("name")).toString(),
                    a.value(QStringLiteral("kind")).toString(), a.value(QStringLiteral("dur")).toDouble()};
    };
    const int n = midias.size();
    QList<Item> visuais;
    for (int i = 0; i < n; ++i)
        visuais.append(itemEm(i));
    const Item itemNarracao = narracao.isEmpty() ? Item{} : itemEm(n);
    const Item itemMusica = musica.isEmpty() ? Item{} : itemEm(n + (narracao.isEmpty() ? 0 : 1));
    for (const Item &v : visuais) {
        if (v.tipo == QLatin1String("audio")) {
            return falhar(err("type_mismatch",
                              QStringLiteral("media must be images or videos; %1 is audio").arg(v.nome)));
        }
    }
    if (!narracao.isEmpty() && itemNarracao.dur <= 0)
        return falhar(err("import_failed", QStringLiteral("Narration %1 has no duration").arg(itemNarracao.nome)));

    // Trilhas: add_track insere no topo, então a ordem de criação decide a pilha final
    // (imagens acima dos vídeos, vídeos acima da narração, narração acima da música). O editor
    // guarda imagem em trilha "shape" e vídeo em trilha "video", nunca juntos; como as mídias
    // nunca se sobrepõem no tempo, a sequência continua uma só aos olhos de quem assiste.
    // Legenda e título entram por último e sobem sozinhos.
    bool temImagem = false;
    bool temVideo = false;
    for (const Item &v : visuais) {
        if (v.tipo == QLatin1String("image"))
            temImagem = true;
        else
            temVideo = true;
    }
    int trilhaMusica = -1;
    int trilhaNarracao = -1;
    int trilhaVideo = -1;
    int trilhaImagem = -1;
    auto novaTrilha = [&](const char *tipo, int &indice) {
        const QJsonObject r = rodar("add_track", {{QStringLiteral("type"), QLatin1String(tipo)}});
        if (sucesso(r)) {
            for (int *t : {&trilhaMusica, &trilhaNarracao, &trilhaVideo, &trilhaImagem}) {
                if (*t >= 0)
                    ++*t;
            }
            indice = 0;
        }
        return r;
    };
    if (!musica.isEmpty()) {
        const QJsonObject r = novaTrilha("audio", trilhaMusica);
        if (!sucesso(r))
            return falhar(r);
    }
    if (!narracao.isEmpty()) {
        const QJsonObject r = novaTrilha("audio", trilhaNarracao);
        if (!sucesso(r))
            return falhar(r);
    }
    if (temVideo) {
        const QJsonObject r = novaTrilha("video", trilhaVideo);
        if (!sucesso(r))
            return falhar(r);
    }
    if (temImagem) {
        const QJsonObject r = novaTrilha("shape", trilhaImagem);
        if (!sucesso(r))
            return falhar(r);
    }

    // Narração no zero: é ela que dita o tempo total.
    QString clipeNarracao;
    double alvo = duracaoExplicita;
    if (!narracao.isEmpty()) {
        const QJsonObject r = rodar("place_clip", {{QStringLiteral("asset"), itemNarracao.id},
                                                   {QStringLiteral("track"), trilhaNarracao},
                                                   {QStringLiteral("at"), 0.0}});
        if (!sucesso(r))
            return falhar(r);
        clipeNarracao = r.value(QStringLiteral("id")).toString();
        const double dur = r.value(QStringLiteral("dur")).toDouble();
        alvo = dur > 0 ? dur : itemNarracao.dur;
    }

    // Fatias: com alvo, tempo igual entre as mídias. Vídeo mais curto que a fatia fica com a
    // duração natural e devolve o resto para os outros, repetindo até nenhum vídeo ficar aquém.
    QVector<double> fatia(n, 0.0);
    QVector<bool> fixo(n, false);
    if (alvo > 0) {
        bool mudou = true;
        while (mudou) {
            mudou = false;
            double ocupado = 0;
            int livres = 0;
            for (int i = 0; i < n; ++i) {
                if (fixo[i])
                    ocupado += visuais[i].dur;
                else
                    ++livres;
            }
            const double f = livres > 0 ? std::max(0.0, (alvo - ocupado) / livres) : 0.0;
            for (int i = 0; i < n; ++i) {
                if (!fixo[i] && visuais[i].tipo == QLatin1String("video") && visuais[i].dur > 0
                    && visuais[i].dur < f - 0.001) {
                    fixo[i] = true;
                    mudou = true;
                }
            }
            for (int i = 0; i < n; ++i)
                fatia[i] = fixo[i] ? visuais[i].dur : f;
        }
        for (int i = 0; i < n; ++i) {
            if (!fixo[i] && fatia[i] < 0.1) {
                fatia[i] = 0.5;
                avisos.append(QStringLiteral("%1 got a minimal 0.5 s slice: the videos alone fill the %2 s target")
                                  .arg(visuais[i].nome)
                                  .arg(alvo, 0, 'f', 2));
            }
        }
    } else {
        for (int i = 0; i < n; ++i) {
            fatia[i] = (visuais[i].tipo == QLatin1String("video") && visuais[i].dur > 0) ? visuais[i].dur
                                                                                          : duracaoImagem;
            alvo += fatia[i];
        }
    }

    // Modo cues: cada corte vai para o início de fala mais próximo, para a troca de mídia cair
    // junto com a frase. Só fronteiras entre mídias livres se movem; vídeo com duração natural
    // fica onde está.
    if (modo == QLatin1String("cues") && !cues.isEmpty() && n > 1) {
        QVector<double> borda(n + 1, 0.0);
        for (int i = 0; i < n; ++i)
            borda[i + 1] = borda[i] + fatia[i];
        for (int k = 1; k < n; ++k) {
            if (fixo[k - 1] || fixo[k])
                continue;
            const double desejado = borda[k];
            const double minimo = borda[k - 1] + 0.5;
            const double maximo = borda[k + 1] - 0.5;
            double melhor = desejado;
            double distancia = std::numeric_limits<double>::max();
            for (const SubtitleCue &c : cues) {
                const double t = usToSeconds(c.startUs);
                if (t < minimo || t > maximo)
                    continue;
                const double d = std::abs(t - desejado);
                if (d < distancia) {
                    distancia = d;
                    melhor = t;
                }
            }
            borda[k] = melhor;
        }
        for (int i = 0; i < n; ++i)
            fatia[i] = borda[i + 1] - borda[i];
    }

    // --- 3. Mídias em sequência na trilha de vídeo ---------------------------------------
    double cursor = 0.0;
    QJsonArray clipes;
    QStringList idsVisuais;
    for (int i = 0; i < n; ++i) {
        const Item &v = visuais[i];
        // A última imagem estica até o alvo quando os vídeos curtos deixaram buraco no fim.
        if (i == n - 1 && alvo > 0 && v.tipo == QLatin1String("image") && cursor + fatia[i] < alvo)
            fatia[i] = alvo - cursor;

        const bool ehImagem = v.tipo == QLatin1String("image");
        const QJsonObject colocado = rodar("place_clip", {{QStringLiteral("asset"), v.id},
                                                          {QStringLiteral("track"), ehImagem ? trilhaImagem : trilhaVideo},
                                                          {QStringLiteral("at"), cursor}});
        if (!sucesso(colocado))
            return falhar(colocado);
        const QString id = colocado.value(QStringLiteral("id")).toString();
        const QJsonObject ajustado = rodar("set_duration", {{QStringLiteral("clip"), id},
                                                            {QStringLiteral("duration"), fatia[i]}});
        if (!sucesso(ajustado))
            return falhar(ajustado);
        const double inicio = ajustado.value(QStringLiteral("start")).toDouble();
        const double dur = ajustado.value(QStringLiteral("dur")).toDouble();
        if (dur + 0.01 < fatia[i]) {
            avisos.append(QStringLiteral("%1 is %2 s, shorter than its %3 s slice")
                              .arg(v.nome)
                              .arg(dur, 0, 'f', 2)
                              .arg(fatia[i], 0, 'f', 2));
        }
        cursor = inicio + dur;

        QJsonObject linha{{QStringLiteral("id"), id},
                          {QStringLiteral("name"), v.nome},
                          {QStringLiteral("kind"), v.tipo},
                          {QStringLiteral("start"), inicio},
                          {QStringLiteral("duration"), dur}};

        // Movimento nas imagens: chaves de x/y/width/height nas duas pontas do clipe.
        if (movimento == QLatin1String("kenburns") && v.tipo == QLatin1String("image") && dur > 0) {
            const QPair<int, int> onde = m_controller->mcpLocateClip(id);
            const QVariantMap atual = m_controller->mcpCompactClip(onde.first, onde.second, true);
            const Quadro base{atual.value(QStringLiteral("x")).toDouble(),
                              atual.value(QStringLiteral("y")).toDouble(),
                              atual.value(QStringLiteral("w")).toDouble(),
                              atual.value(QStringLiteral("h")).toDouble()};
            if (base.w > 0 && base.h > 0) {
                const Movimento m = movimentoPara(i, base, intensidade);
                struct Chave {
                    const char *prop;
                    double de;
                    double para;
                };
                const Chave chaves[] = {{"x", m.de.x, m.para.x},
                                        {"y", m.de.y, m.para.y},
                                        {"width", m.de.w, m.para.w},
                                        {"height", m.de.h, m.para.h}};
                for (const Chave &c : chaves) {
                    for (int ponta = 0; ponta < 2; ++ponta) {
                        const QJsonObject k = applyOne(
                            QStringLiteral("set_keyframe"),
                            {{QStringLiteral("clip"), id},
                             {QStringLiteral("prop"), QLatin1String(c.prop)},
                             {QStringLiteral("at"), ponta == 0 ? inicio : inicio + dur},
                             {QStringLiteral("value"), ponta == 0 ? c.de : c.para}});
                        if (!sucesso(k))
                            return falhar(k);
                    }
                }
                linha.insert(QStringLiteral("motion"), QLatin1String(m.nome));
            } else {
                avisos.append(QStringLiteral("%1: motion skipped, the clip has no canvas size yet").arg(v.nome));
            }
        }

        // Efeitos por mídia visual.
        for (const QString &e : efeitos) {
            const QJsonObject r = applyOne(QStringLiteral("add_effect"),
                                           {{QStringLiteral("clip"), id}, {QStringLiteral("effect"), e}});
            if (!sucesso(r))
                return falhar(r);
        }
        if (!modeloDeEfeito.isEmpty()) {
            const QJsonObject r = applyOne(QStringLiteral("apply_effect_template"),
                                           {{QStringLiteral("clip"), id},
                                            {QStringLiteral("template"), modeloDeEfeito}});
            if (!sucesso(r))
                return falhar(r);
        }
        if (!efeitos.isEmpty() || !modeloDeEfeito.isEmpty())
            linha.insert(QStringLiteral("effects"), static_cast<int>(efeitos.size()) + (modeloDeEfeito.isEmpty() ? 0 : 1));

        clipes.append(linha);
        idsVisuais.append(id);
    }
    if (alvo > 0 && cursor + 0.05 < alvo) {
        avisos.append(QStringLiteral("The media ends at %1 s but the target is %2 s; add media or end with an image")
                          .arg(cursor, 0, 'f', 2)
                          .arg(alvo, 0, 'f', 2));
    }

    // Transições entre mídias vizinhas. Uma transição liga dois clipes da MESMA trilha, então
    // só entra entre imagem-imagem ou vídeo-vídeo; a troca imagem/vídeo fica em corte seco.
    int transicoes = 0;
    if (!transicao.isEmpty() && idsVisuais.size() > 1) {
        QString tipo = texto(transicao, "kind");
        if (tipo.isEmpty())
            tipo = QStringLiteral("crossfade");
        const double dur = numero(transicao.value(QStringLiteral("duration")), 0.5);
        int puladas = 0;
        for (int i = 0; i + 1 < idsVisuais.size(); ++i) {
            if (visuais[i].tipo != visuais[i + 1].tipo) {
                ++puladas;
                continue;
            }
            const QJsonObject r = applyOne(QStringLiteral("add_transition"),
                                           {{QStringLiteral("clip"), idsVisuais.at(i)},
                                            {QStringLiteral("kind"), tipo},
                                            {QStringLiteral("duration"), dur}});
            if (!sucesso(r))
                return falhar(r);
            ++transicoes;
        }
        if (puladas > 0) {
            avisos.append(QStringLiteral("%1 image/video boundary(ies) got a hard cut: transitions only join clips on the same lane")
                              .arg(puladas));
        }
    }

    // --- 4. Música em loop até cobrir, volume baixo, fade no fim, abaixada sob a fala -------
    QJsonArray clipesMusica;
    if (!musica.isEmpty() && itemMusica.dur > 0 && alvo > 0) {
        double t = 0.0;
        int guarda = 0;
        while (t + 0.05 < alvo && guarda++ < 500) {
            const QJsonObject r = rodar("place_clip", {{QStringLiteral("asset"), itemMusica.id},
                                                       {QStringLiteral("track"), trilhaMusica},
                                                       {QStringLiteral("at"), t}});
            if (!sucesso(r))
                return falhar(r);
            const QString id = r.value(QStringLiteral("id")).toString();
            double inicio = r.value(QStringLiteral("start")).toDouble();
            double dur = r.value(QStringLiteral("dur")).toDouble();
            const double falta = alvo - inicio;
            if (dur > falta + 0.01) {
                const QJsonObject a = rodar("set_duration", {{QStringLiteral("clip"), id},
                                                             {QStringLiteral("duration"), falta}});
                if (!sucesso(a))
                    return falhar(a);
                inicio = a.value(QStringLiteral("start")).toDouble();
                dur = a.value(QStringLiteral("dur")).toDouble();
            }
            const QJsonObject vol = applyOne(QStringLiteral("set_volume"),
                                             {{QStringLiteral("clip"), id}, {QStringLiteral("value"), volumeMusica}});
            if (!sucesso(vol))
                return falhar(vol);
            clipesMusica.append(id);
            if (dur <= 0.01)
                break;
            t = inicio + dur;
        }
        if (fadeMusica > 0 && !clipesMusica.isEmpty()) {
            const QJsonObject r = applyOne(QStringLiteral("set_fade"),
                                           {{QStringLiteral("clip"), clipesMusica.last().toString()},
                                            {QStringLiteral("out"), fadeMusica}});
            if (!sucesso(r))
                return falhar(r);
        }
        if (abaixar && !clipeNarracao.isEmpty()) {
            for (const QJsonValue &id : clipesMusica) {
                const QJsonObject r = applyOne(QStringLiteral("duck_under"),
                                               {{QStringLiteral("clip"), id.toString()},
                                                {QStringLiteral("over_clips"), QJsonArray{clipeNarracao}},
                                                {QStringLiteral("amount"), quantoAbaixar}});
                if (!sucesso(r))
                    return falhar(r);
            }
        }
    }

    // --- 5. Título de abertura -----------------------------------------------------------
    QString clipeTitulo;
    if (!titulo.isEmpty()) {
        QJsonObject a{{QStringLiteral("text"), texto(titulo, "text")}, {QStringLiteral("at"), 0.0}};
        if (!texto(titulo, "preset").isEmpty())
            a.insert(QStringLiteral("preset"), texto(titulo, "preset"));
        const QJsonObject r = rodar("add_text", a);
        if (!sucesso(r))
            return falhar(r);
        clipeTitulo = r.value(QStringLiteral("id")).toString();
        const QJsonObject d = applyOne(QStringLiteral("set_duration"),
                                       {{QStringLiteral("clip"), clipeTitulo},
                                        {QStringLiteral("duration"), std::max(0.1, numero(titulo.value(QStringLiteral("duration")), 3.0))}});
        if (!sucesso(d))
            return falhar(d);
        if (titulo.value(QStringLiteral("style")).isObject()) {
            const QJsonObject s = applyOne(QStringLiteral("set_text"),
                                           {{QStringLiteral("clip"), clipeTitulo},
                                            {QStringLiteral("style"), titulo.value(QStringLiteral("style")).toObject()}});
            if (!sucesso(s))
                return falhar(s);
        }
    }

    // --- 6. Legenda pronta por cima de tudo ----------------------------------------------
    QString clipeLegenda;
    if (!legenda.isEmpty()) {
        const QJsonObject r = rodar("import_subtitle_file", {{QStringLiteral("path"), legenda},
                                                             {QStringLiteral("at"), 0.0}});
        if (!sucesso(r))
            return falhar(r);
        clipeLegenda = r.value(QStringLiteral("id")).toString();
        if (!presetLegenda.isEmpty()) {
            const QJsonObject p = rodar("apply_text_preset", {{QStringLiteral("clip"), clipeLegenda},
                                                              {QStringLiteral("preset"), presetLegenda}});
            if (!sucesso(p))
                return falhar(p);
        }
        if (!estiloLegenda.isEmpty()) {
            const QJsonObject s = rodar("set_text", {{QStringLiteral("clip"), clipeLegenda},
                                                     {QStringLiteral("style"), estiloLegenda}});
            if (!sucesso(s))
                return falhar(s);
        }
    }

    m_controller->mcpEndBatch(rotulo, true);

    auto trilhaDe = [&](const QString &id) {
        return id.isEmpty() ? -1 : m_controller->mcpLocateClip(id).first;
    };
    QString primeiraImagem;
    QString primeiroVideo;
    for (int i = 0; i < n; ++i) {
        if (visuais[i].tipo == QLatin1String("image") && primeiraImagem.isEmpty())
            primeiraImagem = idsVisuais.at(i);
        if (visuais[i].tipo != QLatin1String("image") && primeiroVideo.isEmpty())
            primeiroVideo = idsVisuais.at(i);
    }
    const QJsonObject trilhas{
        {QStringLiteral("images"), trilhaDe(primeiraImagem)},
        {QStringLiteral("videos"), trilhaDe(primeiroVideo)},
        {QStringLiteral("narration"), trilhaDe(clipeNarracao)},
        {QStringLiteral("music"), trilhaDe(clipesMusica.isEmpty() ? QString() : clipesMusica.first().toString())},
        {QStringLiteral("subtitles"), trilhaDe(clipeLegenda)},
        {QStringLiteral("title"), trilhaDe(clipeTitulo)},
    };
    return ok({{QStringLiteral("duration"), m_controller->durationSeconds()},
               {QStringLiteral("target"), alvo},
               {QStringLiteral("mode"), modo},
               {QStringLiteral("tracks"), trilhas},
               {QStringLiteral("clips"), clipes},
               {QStringLiteral("transitions"), transicoes},
               {QStringLiteral("narration_clip"), clipeNarracao},
               {QStringLiteral("music_clips"), clipesMusica},
               {QStringLiteral("subtitle_clip"), clipeLegenda},
               {QStringLiteral("cues"), static_cast<int>(cues.size())},
               {QStringLiteral("title_clip"), clipeTitulo},
               {QStringLiteral("warnings"), avisos},
               {QStringLiteral("n_ops"), static_cast<int>(feito.size())}});
}

} // namespace drift::mcp
