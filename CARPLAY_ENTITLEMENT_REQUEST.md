# CarPlay Entitlement Request — Hermes (voice-based conversational app)

Ready to paste into the form at https://developer.apple.com/contact/carplay

---

## Request summary

I am requesting the CarPlay app entitlement for the category **voice-based
conversational apps** (`com.apple.developer.carplay-voice-based-conversation`,
iOS 26.4+) for my app **Hermes**.

- **App name (App Store Connect):** Hermes MAS
- **Bundle ID:** `br.com.marcoant.hermes`
- **Team ID:** `MXZ42GRXC6`
- **Developer Program:** Individual (enrolled 2026-09-25)
- **Platform / SDK:** iOS 26.4+, built with Xcode 26.6, Swift 6.2

## What the app does

Hermes is a personal, voice-first AI assistant that connects to the user's own
private "Hermes" server. It is a conversational assistant, not a media,
navigation, messaging, or audio app. The user talks to it and it answers out
loud and performs tasks on the user's behalf.

On a farm in rural Brazil the user relies on Hermes while driving between
fields. Typical in-car requests, all spoken and answered by voice:

- "How full are the water reservoirs at the farm right now?"
- "What is on my schedule this afternoon?"
- "Were there any new expenses or pending invoices for the farm today?"
- "Summarize the latest notes from the farm log."
- "What is the weather going to be for the next few days?"
- Follow-up questions in the same conversation (context is kept across turns).

The app is designed so the driver never needs to look at or touch a screen. The
CarPlay interface is a single voice control screen that only shows conversation
state (ready / listening / thinking / speaking / consulting Hermes) plus a
start/stop action button. It never shows text or imagery in response to a query,
which matches Apple's guidelines for this category.

## Why the voice-based conversational category

- The primary modality is voice from launch: the user speaks and the assistant
  answers with audio.
- The app does not play media, does not provide navigation, and does not send or
  receive messages through the system Messaging APIs — its core purpose is
  spoken question answering and voice-driven actions.
- The app already uses `CPVoiceControlTemplate` as its only CarPlay UI and keeps
  the audio session open only while a voice turn is active.
- In CarPlay the app is launched only by the user from the CarPlay Home screen.
  It does not act as a system-wide assistant and is not activated by a wake word
  or a steering-wheel button while connected to CarPlay.
- Responses are spoken only; the CarPlay screen never shows text or images for a
  query result.

## Entitlement requested

`com.apple.developer.carplay-voice-based-conversation`

## Notes

- Signing team: `MXZ42GRXC6`. The CarPlay scene is already declared in the app's
  Info.plist and the app compiles cleanly without the entitlement (the
  entitlement is only required to *display/run* on the CarPlay screen).
- I agree to the CarPlay Entitlement Addendum.
