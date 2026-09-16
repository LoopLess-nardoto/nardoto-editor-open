// Entradas de catálogo da caixa "build" (macros de montagem). Incluído dentro de ops() em
// McpCatalog.cpp, logo depois de McpCatalogExtendedOps.inl, que termina sem vírgula: por
// isso este arquivo começa com uma. Implementação em McpDispatcherAssemble.cpp.
        ,
        { "assemble_video", "build", "Build a whole narrated video in one call",
          "Assemble a complete timeline from media + narration + ready-made subtitles in ONE undo "
          "step. Use this first whenever the user hands you an audio file, an .srt and a folder of "
          "images/videos, instead of placing clips one by one.\n"
          "What it does, in order: imports everything; creates an image lane (shape track) above "
          "a video lane above a narration track above a music track (the editor keeps stills and "
          "videos on different track types; the sequence never overlaps in time, so it plays as "
          "one cut); places the narration at 0 (its length is the target); "
          "splits the target equally between the media in the given order (videos shorter than "
          "their slice keep their natural length and hand the rest to the others; the last image "
          "stretches to the end); adds a Ken Burns move to every image (six patterns in rotation: "
          "zoomIn, zoomOut, panRight, panLeft, zoomInTopLeft, zoomOutBottomRight); applies the "
          "optional effects/template to every visual clip; adds the optional transition between "
          "neighbours of the same kind (image-image, video-video; an image/video boundary is a "
          "hard cut, reported in warnings); loops the music to the end at music_volume with a "
          "fade-out, ducked under "
          "the narration; adds the optional opening title; imports the subtitle file on top and "
          "applies subtitle_preset / subtitle_style.\n"
          "media_mode \"cues\" moves each cut to the nearest subtitle cue start so image changes "
          "land on sentence boundaries. Without narration, pass duration or let images last "
          "image_duration each and videos their natural length.\n"
          "Nothing is touched when a file is missing: {ok:false, error:not_found, missing:[…]}. "
          "Paths must be absolute (no directory listing here; find files with your own tools, "
          "in the order the user wants — natural sort of the folder is the usual answer). "
          "Returns {duration, target, mode, tracks:{images,videos,narration,music,subtitles,title}, "
          "clips:[{id,name,kind,start,duration,motion,effects}], transitions, narration_clip, "
          "music_clips, subtitle_clip, cues, title_clip, warnings, n_ops}. Then capture() to "
          "check and export_video to render. Warnings are informational, read them.",
          objectSchema(
              {{QStringLiteral("media"),
                arrayProp({{QStringLiteral("type"), QStringLiteral("string")}},
                          QStringLiteral("Absolute image/video paths, in timeline order"))},
               {QStringLiteral("narration"), stringProp(QStringLiteral("Absolute audio path; its length becomes the target duration"))},
               {QStringLiteral("subtitles"), stringProp(QStringLiteral("Absolute .srt/.vtt path, already timed to the narration"))},
               {QStringLiteral("subtitle_preset"), stringProp(QStringLiteral("Text style pack id from list_text_presets (e.g. caption, hormozi, karaoke-pop, word-background)"))},
               {QStringLiteral("subtitle_style"), textStyleSchema()},
               {QStringLiteral("music"), stringProp(QStringLiteral("Absolute music path; looped to the end"))},
               {QStringLiteral("music_volume"), propWithDefault(numberProp(QStringLiteral("Music level 0..2")), 0.15)},
               {QStringLiteral("duck"), boolProp(QStringLiteral("Lower the music under the narration (default: true when narration is given)"))},
               {QStringLiteral("duck_amount"), propWithDefault(numberProp(QStringLiteral("Multiplier during speech, 0..1")), 0.3)},
               {QStringLiteral("music_fade_out"), propWithDefault(numberProp(QStringLiteral("Seconds of fade at the very end")), 1.5)},
               {QStringLiteral("media_mode"),
                propWithDefault(enumProp(QStringLiteral("sequence = equal slices; cues = cuts snap to subtitle cue starts"),
                                         {QStringLiteral("sequence"), QStringLiteral("cues")}),
                                QStringLiteral("sequence"))},
               {QStringLiteral("duration"), numberProp(QStringLiteral("Target seconds when there is no narration"))},
               {QStringLiteral("image_duration"), propWithDefault(numberProp(QStringLiteral("Seconds per image when there is neither narration nor duration")), 5.0)},
               {QStringLiteral("motion"),
                propWithDefault(enumProp(QStringLiteral("Ken Burns on images"),
                                         {QStringLiteral("kenburns"), QStringLiteral("none")}),
                                QStringLiteral("kenburns"))},
               {QStringLiteral("motion_amount"), propWithDefault(numberProp(QStringLiteral("Zoom/pan strength 0.01..0.5")), 0.10)},
               {QStringLiteral("transition"),
                objectSchema({{QStringLiteral("kind"), propWithDefault(stringProp(QStringLiteral("Transition id from list_transitions")), QStringLiteral("crossfade"))},
                              {QStringLiteral("duration"), propWithDefault(numberProp(QStringLiteral("Seconds")), 0.5)}})},
               {QStringLiteral("effects"),
                arrayProp({{QStringLiteral("type"), QStringLiteral("string")}},
                          QStringLiteral("Effect ids from list_effects, appended to every visual clip"))},
               {QStringLiteral("effect_template"), stringProp(QStringLiteral("Template id from list_effect_templates, applied to every visual clip"))},
               {QStringLiteral("title"),
                objectSchema({{QStringLiteral("text"), stringProp(QStringLiteral("Opening title"))},
                              {QStringLiteral("preset"), stringProp(QStringLiteral("Text preset id (e.g. title, impact)"))},
                              {QStringLiteral("duration"), propWithDefault(numberProp(QStringLiteral("Seconds on screen")), 3.0)},
                              {QStringLiteral("style"), textStyleSchema()}})},
               {QStringLiteral("canvas"),
                objectSchema({{QStringLiteral("width"), integerProp(QStringLiteral("Pixels; omitted keeps the project's"))},
                              {QStringLiteral("height"), integerProp(QStringLiteral("Pixels"))},
                              {QStringLiteral("fps"), integerProp(QStringLiteral("Frames per second"))}})}},
              {QStringLiteral("media")}) }
