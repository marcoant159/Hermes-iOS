# Relatório: ui-ptbr

Branch: `wip/ui-ptbr`. Objetivo: localização pt-BR via String Catalog + polimento de UI
(chat, voz, ajustes). Worktree `/root/hermes-mobile-wt/ui-ptbr`.

## Progresso

- [x] Exploração inicial: estrutura de `HermesMobile/Features/**`, `project.pbxproj`
  (Resources build phase do app = `8E5F38C741065CFEF6FF717A`; grupo `Resources` =
  `11C92F959C91E3D92A137F61`; `knownRegions` = `Base, en`; não há `Localizable.xcstrings`).
- [x] Criado `HermesMobile/Localizable.xcstrings` (sourceLanguage `en`, 220 chaves, pt-BR).
- [x] pbxproj: `PBXFileReference` `ECAEFCC2F4B5CB41980AE52C` (`lastKnownFileType =
  text.json.xcstrings`), `PBXBuildFile` `51A91235FF870D8A0700DFF1` no Resources build phase
  `8E5F38C741065CFEF6FF717A`, referência no grupo raiz `HermesMobile` (não no grupo
  `Resources`, cujo `path = Resources` apontaria para `HermesMobile/Resources/`), e
  `pt-BR` em `knownRegions`.
- [x] Localizadas as strings que passavam por `String` (não localizariam sozinhas):
  `String(localized:)` em modelos (`VoiceState`, `TalkConnectionState`, `TranscriptSpeaker`,
  `ConnectionStatus`, `SyncStatus`, `InboxItemType/Priority/Status`, `PermissionType`,
  `PermissionStatus`, `Location*`, `RelayMode`, `AppEnvironment`, `RelayConfiguration`) e em
  computed properties de `ChatScreen`, `ConnectHermesHostScreen` e `SettingsScreen`.
- [x] Helpers com título `String` migrados para `LocalizedStringKey` sem mudar call sites:
  `SettingsSectionView`, `settingsRow`, `settingsNavRow`, `settingsToggle`,
  `statusRow` (StatusCardView), `setupStep`/`actionRow` (ConnectHermesHostScreen),
  `attachmentButton` (AttachmentPickerSheet). `TextField`/`accessibilityLabel` com ternário
  viraram `LocalizedStringKey` (ChatInputBar, TalkModeScreen, VoiceOverlayScreen).
- [x] Polimento: alvos de toque do composer 36→44 pt; háptico ao iniciar voz
  (`HapticEngine.voiceSessionStarted`, ligado a Ajustes); timestamp da lista de conversas
  em `.relative`; animação suave de aparecimento de mensagens; prioridade/status da Inbox
  com `displayLabel` traduzível.
