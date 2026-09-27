# REPORT — carplay (branch `wip/carplay`)

Objetivo: ligar o CarPlay (categoria "voice-based conversational apps", iOS 26.4+) sem
quebrar a assinatura do TestFlight enquanto a entitlement não é aprovada pela Apple;
deixar o entitlement pronto, o pedido à Apple escrito e o fluxo de voz revisado.

Ambiente: worktree Linux (sem xcodebuild/swift local). Validação só via CI do fork
`marcoant159/Hermes-iOS`. Alvo: iOS 26, Swift 6.2, Xcode 26.6.

## Log de progresso

- (início) Leitura do contexto e do código existente:
  `HermesMobile/CarPlay/CarPlaySceneDelegate.swift` (37 linhas),
  `HermesMobile/CarPlay/CarPlayVoiceManager.swift` (165 linhas).
  Estado: **não ligado** — `Info.plist` sem `UIApplicationSceneManifest`/cena CarPlay e
  `HermesMobile.entitlements` sem chave de CarPlay.
- Descoberta importante: `project.yml` **já** declara a cena CarPlay (linhas 91–97), mas o
  CI compila o `.xcodeproj`/`Info.plist` commitados (não roda xcodegen), então o
  `HermesMobile/Resources/Info.plist` está fora de sincronia e é ele que precisa da cena.

### Pesquisa de API (iOS 26)

Fontes: CarPlay Developer Guide (08/06/2026), WWDC26 sessão 212, páginas `developer.apple.com/documentation/carplay/*`
(inclui o `.md` com a disponibilidade de cada símbolo) e PR do home-assistant/iOS.

- **Entitlement exata**: `com.apple.developer.carplay-voice-based-conversation`
  (booleana). Disponibilidade iOS 26.4+. Categoria “voice-based conversational app”.
  O guia lista a tabela oficial: `...-audio`, `...-communication`, `...-driving-task`,
  `...-charging`, `...-maps`, `...-parking`, `...-public-safety`, `...-quick-ordering`,
  `...-video` (iOS 27) e `...-voice-based-conversation` (iOS 26.4).
- **Templates permitidos**: a UI primária é o `CPVoiceControlTemplate` (reservado a apps de
  navegação e de voz). A categoria também pode usar templates básicos (list, grid, alert,
  action sheet, information, POI) mas **não** Now Playing, Contact nem Map. Profundidade
  máxima = **3 templates** (incluindo a raiz); usar template não permitido lança exceção
  em runtime.
- **`CPVoiceControlTemplate` (iOS 26.4+)**: `CPVoiceControlState.actionButtons: [CPButton]`
  (máximo `maximumActionButtonCount`; na prática 2), `CPButton(image:handler:)` com
  `title`, e `leadingNavigationBarButtons`/`trailingNavigationBarButtons` (máx. 2 por lado).
  `CPVoiceControlState.init(identifier:titleVariants:image:repeats:)` é iOS 12+.
- **Áudio**: categoria `.playAndRecord`, modo `.default`, **sem mixing**; só manter a
  `AVAudioSession` ativa enquanto houver voz; features de gravação só junto do voice control
  template. O `LiveVoiceSessionService` já usa `.playAndRecord` e não mistura, mas com modo
  `.voiceChat` (processamento de voz/eco — adequado a conversa full-duplex) e já **não**
  força o alto-falante quando a rota é `carAudio` (respeita o áudio do carro). A Siri
  continua disponível por cima (não é substituída).
- **Cena no Info.plist**: `UIApplicationSceneManifest` → `UISceneConfigurations` →
  `CPTemplateApplicationSceneSessionRoleApplication` com `UISceneClassName`
  (`CPTemplateApplicationScene`), `UISceneConfigurationName` e
  `UISceneDelegateClassName` = `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`. Declarar a
  cena **não** exige a entitlement (só a exibe/roda após a Apple conceder).
- **Simulator**: a tela de CarPlay é aberta por `I/O → External Displays → CarPlay` (GUI);
  não há subcomando do `xcrun simctl` que a abra. O Simulator exige perfil/entitlement que
  suporte CarPlay; ad-hoc aceita entitlements locais.
- **SwiftUI lifecycle**: vários relatos (StackOverflow, `jiaanf.tech`) mostram que a cena
  funciona em app SwiftUI puro desde que `Application Scene Manifest (Generation)`
  (`INFOPLIST_KEY_UIApplicationSceneManifest_Generation`) esteja `NO` — senão o Xcode
  sobrescreve o Info.plist. Neste projeto essa chave **não** existe no `.pbxproj` (default
  `NO`) e a config do app usa `INFOPLIST_FILE`, então o manifesto escrito à mão é o que vale.

### O que foi implementado

1. `HermesMobile/Resources/Info.plist`: adicionado `UIApplicationSceneManifest` com
   `UIApplicationSupportsMultipleScenes` + `CPTemplateApplicationSceneSessionRoleApplication`
   (`UISceneClassName=CPTemplateApplicationScene`, config `CarPlay`, delegate
   `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`), espelhando o que o `project.yml` já previa.
   Declarar a cena **não** exige entitlement, então não mexe na assinatura.
2. `HermesMobile/CarPlay/CarPlayVoiceManager.swift` reescrito: template construído uma só vez
   com os estados **pt-BR** pronto / conectando / ouvindo / pensando / consultando o Hermes /
   falando / indisponível; ação **Iniciar conversa** / **Encerrar** via
   `CPVoiceControlState.actionButtons` (iOS 26.4+, guardado com `#available`); em vez de
   recriar o template a cada fala, só troca o estado. Não mostra o texto da resposta na tela
   (a guideline da categoria proíbe texto/imagem em resposta a perguntas).
   A sessão é aberta/encerrada pelo `TalkStore` (`startSessionDirectly()` / `endSession()`),
   sem duplicar lógica. A desconexão do carro encerra a sessão **somente se** foi o CarPlay
   que a abriu (`didStartSession`); uma sessão iniciada no iPhone continua.
3. `HermesMobile/CarPlay/CarPlaySceneDelegate.swift`: `configure()`/`tearDown()` agora
   assíncronos; ao desconectar, solta as referências e encerra com segurança.
4. `HermesMobile/Stores/TalkStore.swift`: novo `var isDelegationInProgress: Bool`
   (espelho read-only de `voiceService.snapshot.isDelegationInProgress`) para o estado
   “consultando o Hermes” sem duplicar bookkeeping.
5. `HermesMobile/HermesMobile-CarPlay.entitlements` criado (cópia do atual + 
   `com.apple.developer.carplay-voice-based-conversation`), **sem** ligar ao target.
6. `.github/workflows/ios-carplay-simulator.yml` (novo, `workflow_dispatch`): compila para o
   Simulator com `CODE_SIGN_ENTITLEMENTS=HermesMobile/HermesMobile-CarPlay.entitlements`
   (override só no build do Simulator, assinatura ad-hoc), confere a entitlement embutida com
   `codesign`, instala/lança em mock e tenta abrir a janela de CarPlay (best-effort).
   **Precisa existir no master para o dispatch** — não foi pushado para master.
7. `CARPLAY_ENTITLEMENT_REQUEST.md`: texto em inglês pronto para o formulário da Apple.

## Como ligar a entitlement quando a Apple aprovar (troca exata)

Enquanto a entitlement não estiver no perfil, o arquivo `HermesMobile-CarPlay.entitlements`
**não pode** ser ligado ao target (o perfil não a contém e a assinatura do TestFlight falha).

1. **Portal/ASC**: developer.apple.com → Certificates, IDs & Profiles → Identifiers → App ID
   `br.com.marcoant.hermes` → habilitar a capability de CarPlay (voice-based) → Save. Em
   Profiles, gerar/baixar o perfil novo (ou deixar o Xcode regenerar com
   `-allowProvisioningUpdates`, que é o que o workflow TestFlight já usa). Nada a mudar no ASC
   além disso — o App ID ganha a capability.
2. **Projeto** (troca do arquivo): nas duas configs do app no
   `HermesMobile.xcodeproj/project.pbxproj` (Debug `B66B3E358307E760AB86E9DC` e Release
   `F2A197B631122A07E5B48F5B`), trocar
   `CODE_SIGN_ENTITLEMENTS = HermesMobile/HermesMobile.entitlements;`
   por `CODE_SIGN_ENTITLEMENTS = HermesMobile/HermesMobile-CarPlay.entitlements;`.
   No `project.yml`, atualizar `targets.HermesMobile.entitlements.path` para o mesmo arquivo
   (para não divergir se algum dia regenerarem com xcodegen).
3. Rodar o workflow **TestFlight** normalmente; o perfil novo já inclui a capability.

## Validação (CI)

- `Build unsigned IPA` — run **36333388647**, verde (1m51s): os arquivos Swift novos compilam.
- `Simulator screenshots` — run **36333518550**, verde (9m13s): 13 PNGs + `tour.mp4`,
  `Test Suite 'ScreenshotTourUITests' passed`, `test.log` sem erros. Confirma que o
  `UIApplicationSceneManifest` novo **não** quebrou o app no iPhone sem carro.
- Plists validados localmente com `plistlib` (Info.plist e os dois entitlements).
- `ios-carplay-simulator.yml` **não pôde ser disparado**: `workflow_dispatch` só existe para
  workflows no branch default, e `gh workflow list` não o lista (não está no master). É o
  único teste de Simulator pendente; o Marco precisa registrá-lo no master e rodar 1x.

## Pendências

- Registrar `ios-carplay-simulator.yml` no master e rodar uma vez (compila p/ Simulator com a
  entitlement, confere com `codesign` e tenta abrir a tela de CarPlay). O passo de abrir a
  janela é best-effort (a GUI do Simulator não é scriptável de forma confiável).
- Após a Apple conceder a entitlement: trocar o `CODE_SIGN_ENTITLEMENTS` (acima) e testar no
  carro de verdade — sem a entitlement o app **não** aparece na tela do carro/Simulator.
- Textos do CarPlay estão em pt-BR literal; se um dia quiser multilíngue, mover para
  `Localizable.xcstrings`.

## Roteiro de teste no iPhone (Marco)

**Agora (sem entitlement), só para garantir que nada regrediu:**
1. Instalar o próximo build do TestFlight (N≥9) e conferir o app no iPhone: chat, voz e o
   tour de telas continuam normais (o CI já cobriu isso).
2. Abrir o app, parear se necessário e fazer uma conversa de voz de teste — inalterada.

**Depois que a Apple aprovar a entitlement de CarPlay:**
1. Ligar a capability no App ID e gerar o perfil novo (passo 1 acima).
2. Trocar `CODE_SIGN_ENTITLEMENTS` para `HermesMobile/HermesMobile-CarPlay.entitlements`
   (passo 2 acima) e gerar um build pelo workflow TestFlight.
3. No carro, conectar o iPhone por CarPlay (USB ou sem fio). O ícone do **Hermes** deve
   aparecer na tela do carro.
4. Abrir o Hermes no carro: deve mostrar **“Pronto. Toque para conversar com o Hermes”** com
   o botão **Iniciar conversa**.
5. Tocar **Iniciar conversa** → aparece **“Ouvindo…”**. Falar, por exemplo, “Como estão os
   reservatórios da fazenda?” → **“Pensando…”** → **“Consultando o Hermes…”** → **“Falando…”**,
   e a resposta sai em áudio pelo carro.
6. Tocar **Encerrar** → volta para **“Pronto”**.
7. Com a conversa em andamento, **bloquear a tela do iPhone**: o áudio deve continuar pelo
   carro (modo background `audio`).
8. **Desconectar** o carro com a sessão aberta: a sessão encerra com segurança; ao reconectar,
   abrir de novo e repetir.
9. Iniciar uma sessão de voz **no iPhone** e só então conectar o carro: ao desconectar, a
   sessão do iPhone deve continuar (o CarPlay só encerra o que ele mesmo abriu).

**Roteiro manual no Simulator (Mac, para dev):**
1. Build p/ Simulator com o override:
   `xcodebuild build -project HermesMobile.xcodeproj -scheme HermesMobile -configuration Debug -sdk iphonesimulator -destination 'id=<UDID>' CODE_SIGN_ENTITLEMENTS=HermesMobile/HermesMobile-CarPlay.entitlements CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- PROVISIONING_PROFILE_SPECIFIER=`
2. `xcrun simctl install <UDID> <HermesMobile.app>` e `xcrun simctl launch <UDID> br.com.marcoant.hermes`.
3. No Simulator: `I/O → External Displays → CarPlay` (habilitar antes com
   `defaults write com.apple.iphonesimulator CarPlay -bool YES`). O ícone do Hermes deve
   aparecer e a tela de voz deve abrir.

