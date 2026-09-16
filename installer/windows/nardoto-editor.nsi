; Instalador do Nardoto Editor (Windows x64).
;
; Mesmo tema do instalador do Nardoto Studio: fundo escuro, laranja do app e a
; tela de progresso desenhada em bitmap. A arte sai de scripts/installer-art.py
; do repositório do Studio (preset "editor") e vive em installer/windows/art.
;
; Compilado por build-installer.ps1, que também monta dist/bin com o windeployqt.

Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "nsDialogs.nsh"
!include "WinMessages.nsh"
!include "FileFunc.nsh"

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef SOURCE_DIR
  !define SOURCE_DIR "..\..\dist\bin"
!endif

!define NOME "Nardoto Editor"
!define EXE "nardoto-editor.exe"
!define CHAVE_DESINSTALAR "Software\Microsoft\Windows\CurrentVersion\Uninstall\NardotoEditor"

Name "${NOME}"
OutFile "output\NardotoEditor-Setup-x64.exe"
InstallDir "$PROGRAMFILES64\${NOME}"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
BrandingText "${NOME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${NOME}"
VIAddVersionKey "FileDescription" "Instalador do ${NOME}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "Nardoto"
VIAddVersionKey "LegalCopyright" "GPL-3.0"

!define MUI_ICON "..\..\resources\windows\nardoto-editor.ico"
!define MUI_UNICON "..\..\resources\windows\nardoto-editor.ico"
!define MUI_BGCOLOR "0A0A0A"
!define MUI_TEXTCOLOR "FFFFFF"
!define MUI_WELCOMEFINISHPAGE_BITMAP "art\editor-sidebar.bmp"
!define MUI_UNWELCOMEFINISHPAGE_BITMAP "art\editor-sidebar.bmp"
!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_RIGHT
!define MUI_HEADERIMAGE_BITMAP "art\editor-header.bmp"
!define MUI_ABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "${NOME}"
!define MUI_WELCOMEPAGE_TEXT "O editor de vídeo do Nardoto.$\r$\n$\r$\nPeça no chat do Nardoto Studio e acompanhe a montagem aqui: cortes, legendas, efeitos e trilha na linha do tempo.$\r$\n$\r$\nVersão ${VERSION}."

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY

; Os callbacks entram só na página de progresso, para não vazar para as outras.
!define MUI_PAGE_CUSTOMFUNCTION_SHOW mostrarProgressoEscuro
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE sairProgressoEscuro
!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Abrir o ${NOME}"
!define MUI_FINISHPAGE_RUN_FUNCTION abrirComoUsuario
!define MUI_PAGE_CUSTOMFUNCTION_SHOW ajustarConclusao
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "PortugueseBR"

; Literais hex de propósito: o parser do NSIS para no "+" de ${WM_USER}+9 e a
; mensagem sai errada (lição paga no tema do Studio, 2026-09-01).
!define PBM_COR_BARRA 0x409
!define PBM_COR_FUNDO 0x2001

Var Pagina
Var Barra
Var Texto
Var Fundo
Var FundoBitmap
Var Fonte
Var JanelaX
Var JanelaY
Var JanelaLargura
Var JanelaAltura

; A barra que anda é a NATIVA do NSIS: o motor a avança sozinho durante a cópia
; dos arquivos. Barra própria movida por marcos fixos fica "travada" na tela.
Function mostrarProgressoEscuro
  InitPluginsDir
  File /oname=$PLUGINSDIR\editor-installing.bmp "art\editor-installing.bmp"

  ; Barra de título escura quando o Windows oferece suporte.
  System::Call '*(i 1) p.r0'
  System::Call 'dwmapi::DwmSetWindowAttribute(p $HWNDPARENT,i 20,p r0,i 4)'
  System::Free $0

  FindWindow $Pagina "#32770" "" $HWNDPARENT
  GetDlgItem $Barra $Pagina 1004
  GetDlgItem $Texto $Pagina 1006
  SetCtlColors $Pagina "" "0A0A0A"

  ; Esconde a moldura do assistente só durante a cópia.
  GetDlgItem $0 $HWNDPARENT 1037
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 1038
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 1034
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 1046
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 1035
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 1045
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 1028
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 1256
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 1
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 2
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $HWNDPARENT 3
  ShowWindow $0 ${SW_HIDE}

  ; Amplia só esta etapa, para a arte caber na proporção em que foi desenhada.
  System::Call '*(i 0,i 0,i 0,i 0) p.r0'
  System::Call 'user32::GetWindowRect(p $HWNDPARENT,p r0)'
  System::Call '*$0(i .r1,i .r2,i .r3,i .r4)'
  System::Free $0
  StrCpy $JanelaX $1
  StrCpy $JanelaY $2
  IntOp $JanelaLargura $3 - $1
  IntOp $JanelaAltura $4 - $2
  IntOp $R3 $JanelaLargura * 7
  IntOp $R3 $R3 / 5
  IntOp $R4 $JanelaAltura + 24
  IntOp $R5 $R3 - $JanelaLargura
  IntOp $R5 $R5 / 2
  IntOp $R5 $JanelaX - $R5
  IntOp $R6 $R4 - $JanelaAltura
  IntOp $R6 $R6 / 2
  IntOp $R6 $JanelaY - $R6
  System::Call 'user32::SetWindowPos(p $HWNDPARENT,p 0,i $R5,i $R6,i $R3,i $R4,i 0x4)'

  System::Call '*(i 0,i 0,i 0,i 0) p.r0'
  System::Call 'user32::GetClientRect(p $HWNDPARENT,p r0)'
  System::Call '*$0(i .r1,i .r2,i .r3,i .r4)'
  System::Free $0
  IntOp $R3 $3 - $1
  IntOp $R4 $4 - $2
  System::Call 'user32::MoveWindow(p $Pagina,i 0,i 0,i $R3,i $R4,i 1)'

  System::Call 'user32::CreateWindowExW(i 0,w "STATIC",w "",i ${WS_CHILD}|${WS_VISIBLE}|${WS_CLIPSIBLINGS}|${SS_BITMAP},i 0,i 0,i $R3,i $R4,p $Pagina,p 0,p 0,p 0) p.r0'
  StrCpy $Fundo $0
  ${NSD_SetStretchedImage} $Fundo "$PLUGINSDIR\editor-installing.bmp" $FundoBitmap
  System::Call 'user32::SetWindowPos(p $Fundo,p 1,i 0,i 0,i 0,i 0,i 0x13)'

  ; Sem o tema visual do Windows a barra nativa aceita as cores do app.
  IntOp $R5 $R3 - 88
  IntOp $R6 $R4 - 49
  System::Call 'uxtheme::SetWindowTheme(p $Barra, w " ", w " ")'
  System::Call 'user32::MoveWindow(p $Barra,i 24,i $R6,i $R5,i 7,i 1)'
  SendMessage $Barra ${PBM_COR_BARRA} 0 0x002A5AE8 ; #E85A2A em BGR
  SendMessage $Barra ${PBM_COR_FUNDO} 0 0x00222222
  ShowWindow $Barra ${SW_SHOW}
  System::Call 'user32::SetWindowPos(p $Barra,p 0,i 0,i 0,i 0,i 0,i 0x3)'

  IntOp $R6 $R4 - 30
  IntOp $R5 $R3 - 48
  System::Call 'user32::MoveWindow(p $Texto,i 24,i $R6,i $R5,i 18,i 1)'
  SendMessage $Texto ${WM_SETTEXT} 0 "STR:Instalando o editor..."
  SetCtlColors $Texto "A3A3A3" "0A0A0A"

  CreateFont $Fonte "Segoe UI" 9 400
  SendMessage $Texto ${WM_SETFONT} $Fonte 1

  GetDlgItem $0 $Pagina 1027
  ShowWindow $0 ${SW_HIDE}
  GetDlgItem $0 $Pagina 1016
  ShowWindow $0 ${SW_HIDE}
FunctionEnd

Function sairProgressoEscuro
  StrCmp $Fundo 0 +3
  System::Call 'user32::DestroyWindow(p $Fundo)'
  ${NSD_FreeImage} $FundoBitmap
  StrCmp $Fonte 0 +2
  System::Call 'gdi32::DeleteObject(p $Fonte)'

  StrCpy $Pagina 0
  StrCpy $Barra 0
  StrCpy $Texto 0
  StrCpy $Fundo 0
  StrCpy $FundoBitmap 0
  StrCpy $Fonte 0

  System::Call 'user32::SetWindowPos(p $HWNDPARENT,p 0,i $JanelaX,i $JanelaY,i $JanelaLargura,i $JanelaAltura,i 0x4)'

  GetDlgItem $0 $HWNDPARENT 1037
  ShowWindow $0 ${SW_SHOW}
  GetDlgItem $0 $HWNDPARENT 1038
  ShowWindow $0 ${SW_SHOW}
  GetDlgItem $0 $HWNDPARENT 1034
  ShowWindow $0 ${SW_SHOW}
  GetDlgItem $0 $HWNDPARENT 1046
  ShowWindow $0 ${SW_SHOW}
  GetDlgItem $0 $HWNDPARENT 1035
  ShowWindow $0 ${SW_SHOW}
  GetDlgItem $0 $HWNDPARENT 1028
  ShowWindow $0 ${SW_SHOW}
  GetDlgItem $0 $HWNDPARENT 1256
  ShowWindow $0 ${SW_SHOW}
  GetDlgItem $0 $HWNDPARENT 1
  ShowWindow $0 ${SW_SHOW}
  GetDlgItem $0 $HWNDPARENT 2
  ShowWindow $0 ${SW_SHOW}
  GetDlgItem $0 $HWNDPARENT 3
  ShowWindow $0 ${SW_SHOW}
FunctionEnd

; Com visual styles o checkbox ignora a cor de texto do SetCtlColors: tirar o
; tema só dele deixa o texto branco no fundo escuro (mesmo conserto do Studio).
Function ajustarConclusao
  System::Call 'uxtheme::SetWindowTheme(p $mui.FinishPage.Run, w " ", w " ")'
  SetCtlColors $mui.FinishPage.Run "FFFFFF" "0A0A0A"
  ShowWindow $mui.FinishPage.Run 0
  ShowWindow $mui.FinishPage.Run 5
FunctionEnd

; O instalador roda como administrador; abrir o editor por aqui o deixaria
; elevado (arrastar arquivo do Explorer para de funcionar). O explorer.exe
; devolve o processo ao usuário normal.
Function abrirComoUsuario
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\${EXE}"'
FunctionEnd

; O compilador NSIS gera um instalador de 32 bits; sem SetRegView 64 tudo o que
; ele escreve em HKLM\Software vai parar no Wow6432Node, e um app x64 some da
; lista de Aplicativos instalados. Provado aqui em 2026-09-16.
Function .onInit
  SetRegView 64
  ReadRegStr $0 HKLM "Software\Nardoto\Editor" "InstallDir"
  ${If} $0 != ""
    StrCpy $INSTDIR $0
  ${EndIf}
FunctionEnd

Function un.onInit
  SetRegView 64
  ; Sem administrador o DeleteRegKey falha calado: os arquivos somem e o app
  ; continua listado em Aplicativos instalados, apontando para uma pasta que
  ; não existe mais. Melhor recusar de cara.
  ClearErrors
  WriteRegStr HKLM "Software\Nardoto\Editor" "TesteDePermissao" "1"
  ${If} ${Errors}
    ${IfNot} ${Silent}
      MessageBox MB_OK|MB_ICONSTOP "A desinstalação precisa de permissão de administrador. Use Configurações do Windows > Aplicativos instalados, ou clique com o botão direito no desinstalador e escolha Executar como administrador."
    ${EndIf}
    SetErrorLevel 2
    Quit
  ${EndIf}
  DeleteRegValue HKLM "Software\Nardoto\Editor" "TesteDePermissao"
FunctionEnd

Section "Nardoto Editor" SecEditor
  SectionIn RO
  SetRegView 64

  ; Instalação para todos os usuários: atalho no menu Iniciar de todo mundo, e
  ; não só no de quem rodou o instalador.
  SetShellVarContext all

  ; Sem permissão de administrador o WriteRegStr no HKLM falha CALADO: o app
  ; instala, mas não aparece em Aplicativos instalados e o .drift não abre com
  ; duplo clique. Conferido aqui antes de copiar qualquer arquivo.
  ClearErrors
  WriteRegStr HKLM "Software\Nardoto\Editor" "InstallDir" "$INSTDIR"
  ${If} ${Errors}
    ; Em instalação silenciosa a caixa de mensagem travaria o processo esperando
    ; um clique que ninguém vai dar: ali só o código de saída conta.
    ${IfNot} ${Silent}
      MessageBox MB_OK|MB_ICONSTOP "Este instalador precisa de permissão de administrador. Feche esta janela, clique com o botão direito no instalador e escolha Executar como administrador."
    ${EndIf}
    SetErrorLevel 2
    Abort
  ${EndIf}

  ; Arquivo em uso trava a cópia no meio e deixa a instalação pela metade.
  ${If} ${FileExists} "$INSTDIR\${EXE}"
    ClearErrors
    Rename "$INSTDIR\${EXE}" "$INSTDIR\${EXE}.emuso"
    ${If} ${Errors}
      MessageBox MB_OK|MB_ICONSTOP "O Nardoto Editor está aberto. Feche o editor e rode este instalador de novo."
      Abort
    ${Else}
      Rename "$INSTDIR\${EXE}.emuso" "$INSTDIR\${EXE}"
    ${EndIf}
  ${EndIf}

  SetOutPath "$INSTDIR"
  File /r "${SOURCE_DIR}\*.*"
  File "..\..\LICENSE"

  CreateShortcut "$SMPROGRAMS\${NOME}.lnk" "$INSTDIR\${EXE}"
  CreateShortcut "$DESKTOP\${NOME}.lnk" "$INSTDIR\${EXE}"

  WriteRegStr HKLM "Software\Nardoto\Editor" "Version" "${VERSION}"

  ; Projeto do editor abre com duplo clique.
  WriteRegStr HKLM "Software\Classes\.drift" "" "Nardoto.Editor.Project"
  WriteRegStr HKLM "Software\Classes\Nardoto.Editor.Project" "" "Projeto do Nardoto Editor"
  WriteRegStr HKLM "Software\Classes\Nardoto.Editor.Project\DefaultIcon" "" "$INSTDIR\${EXE},0"
  WriteRegStr HKLM "Software\Classes\Nardoto.Editor.Project\shell\open\command" "" '"$INSTDIR\${EXE}" "%1"'

  WriteUninstaller "$INSTDIR\Desinstalar ${NOME}.exe"

  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  WriteRegStr HKLM "${CHAVE_DESINSTALAR}" "DisplayName" "${NOME}"
  WriteRegStr HKLM "${CHAVE_DESINSTALAR}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${CHAVE_DESINSTALAR}" "Publisher" "Nardoto"
  WriteRegStr HKLM "${CHAVE_DESINSTALAR}" "DisplayIcon" "$INSTDIR\${EXE}"
  WriteRegStr HKLM "${CHAVE_DESINSTALAR}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${CHAVE_DESINSTALAR}" "UninstallString" '"$INSTDIR\Desinstalar ${NOME}.exe"'
  WriteRegStr HKLM "${CHAVE_DESINSTALAR}" "QuietUninstallString" '"$INSTDIR\Desinstalar ${NOME}.exe" /S'
  WriteRegDWORD HKLM "${CHAVE_DESINSTALAR}" "EstimatedSize" "$0"
  WriteRegDWORD HKLM "${CHAVE_DESINSTALAR}" "NoModify" 1
  WriteRegDWORD HKLM "${CHAVE_DESINSTALAR}" "NoRepair" 1

  System::Call 'shell32::SHChangeNotify(i 0x8000000, i 0, p 0, p 0)'
SectionEnd

Section "Uninstall"
  SetRegView 64
  SetShellVarContext all
  Delete "$SMPROGRAMS\${NOME}.lnk"
  Delete "$DESKTOP\${NOME}.lnk"

  RMDir /r "$INSTDIR"

  DeleteRegKey HKLM "${CHAVE_DESINSTALAR}"
  DeleteRegKey HKLM "Software\Nardoto\Editor"
  DeleteRegKey HKLM "Software\Classes\Nardoto.Editor.Project"
  DeleteRegKey HKLM "Software\Classes\.drift"

  System::Call 'shell32::SHChangeNotify(i 0x8000000, i 0, p 0, p 0)'
SectionEnd
