# Bombocut open beta (TestFlight)

Everything in the app is ready for an open beta: TestFlight builds are free (no trial, no paywall, a BETA card on Home with how to send feedback), the privacy manifest is in, encryption is declared as "none", and every archive gets a new build number automatically.

What is left needs your Apple account. About 30 minutes, then Apple's beta review (usually under a day).

## 1. Apple Developer Program (once)

TestFlight needs the paid membership (99 USD / year): https://developer.apple.com/programs/enroll/
If you enroll as an individual, the App Store shows your name as the seller.

### After enrolling: switch Xcode to the paid team (once)

Your earlier runs used the free "Personal Team", and `update.sh` remembered it in `Config/Local.xcconfig`.

1. In Terminal: `rm ~/strih/Config/Local.xcconfig`
2. Open the project in Xcode → target **Bombocut** → **Signing & Capabilities** → Team: pick your name **without** "(Personal Team)".
3. Run `~/strih/update.sh` (it saves the new team), then ▶ once on your iPhone to check it still installs.

## 2. Create the app in App Store Connect (once)

https://appstoreconnect.apple.com → Apps → **+** → New App

| Field | Value |
|---|---|
| Platform | iOS |
| Name | BOMBOCUT (all caps is the brand, same as in the app; must be unique on the App Store; if taken, e.g. "BOMBOCUT: Video Editor") |
| Primary language | English (U.S.) (Czech gets added as a localization later) |
| Bundle ID | cz.krechler.bombocut (it appears in the list after the first Xcode run with your paid team; if not, register it under Certificates, Identifiers & Profiles → Identifiers) |
| SKU | bombocut |
| User access | Full access |

Then in the app: **App Privacy** → Get Started → "No, we do not collect data from this app" → Publish.

## 3. Upload a build from Xcode

1. Run `~/strih/update.sh`.
2. In Xcode, pick **Any iOS Device (arm64)** at the top (not your iPhone).
3. **Product → Archive**. When it finishes, the Organizer opens.
4. **Distribute App → App Store Connect → Distribute** (automatic signing and defaults are fine).
5. After 5 to 20 minutes the build shows in App Store Connect → TestFlight. It should not ask about export compliance: the app already declares that it uses no non-exempt encryption.

Every run of `update.sh` sets a new build number (date and time), so run it before each archive and you can upload again any time without touching settings.

## 4. TestFlight: test information (once)

App Store Connect → TestFlight → **Test Information**. Paste:

**Beta App Description (English)**

> BOMBOCUT is a video editor for iPhone made by a tiny team in Prague. Auto subtitles in 25 languages are made on your iPhone, offline: no cloud, no account, no data collection. Fast speed curves with smooth slow motion and motion blur, keyframes, text and overlays with blend modes, subject masks, stabilization and subject tracking, and full export control (resolution, fps, bitrate, HEVC). Everything is free while in beta.

**Beta App Description (Czech, add Czech under localizations)**

> BOMBOCUT je střihač videa pro iPhone od malinkého týmu z Prahy. Automatické titulky ve 25 jazycích vznikají přímo v iPhonu, offline: žádný cloud, žádný účet, žádné sbírání dat. Rychlostní křivky s plynulým zpomalením a motion blurem, keyframy, texty a překrytí s režimy prolnutí, maska objektu, stabilizace a tracking a plná kontrola exportu (rozlišení, fps, bitrate, HEVC). Během bety je všechno zdarma.

**Feedback Email**: your email (required by Apple, testers can write to it).

**Marketing URL**: optional, leave empty.

**Privacy Policy URL**: the public link of the "Bombocut Privacy" page (see the end of this file).

**Beta App Review information**: your name, phone, email. Sign-in required: **No**. Notes:

> No account needed. On first launch pick the app language and subtitle languages; the speech model (about 650 MB) downloads from Hugging Face once, then subtitles run offline. To try subtitles, add any video with speech, then tap Captions → Generate captions. TestFlight builds are free: there is no trial or purchase in the beta.

## 5. Open beta: public link

TestFlight → **External Testing** → **+** → group name "Open beta" → add the build → fill **What to Test** → Submit for Review. After Apple approves it (usually within a day), open the group → **Public Link** → Enable. Set a tester limit if you want (max 10,000).

**What to Test (English)**

> Thanks for testing! Most useful right now:
> 1. Auto subtitles in your language: are the words and the timing right?
> 2. Transitions between clips (crossfade, zoom, slides, smooth cut): do they look smooth?
> 3. Speech (select a clip → Speech): remove noise and voice enhancer on a noisy talking clip.
> 4. Stabilize on shaky handheld footage, Smooth and Locked.
> 5. Long exports with motion blur, and anything that crashes, freezes or feels slow.
> Take a screenshot in the app and tap Share Beta Feedback. Every message gets read.

**What to Test (Czech)**

> Díky, že testuješ! Teď nejvíc pomůže:
> 1. Automatické titulky v tvém jazyce: sedí slova a časování?
> 2. Přechody mezi klipy (prolínačka, přiblížení, posuny, plynulý střih): vypadají plynule?
> 3. Řeč (vyber klip → Řeč): odstranění šumu a vylepšení hlasu na hlučném klipu s mluvením.
> 4. Stabilizace na roztřeseném záběru z ruky, Plynule i Zamčeno.
> 5. Dlouhé exporty s motion blurem a cokoli, co spadne, zamrzne nebo je pomalé.
> Udělej v aplikaci screenshot a klepni na Sdílet zpětnou vazbu k betě. Čteme každou zprávu.

Where to share the link: your Instagram (PVP), BMX and filmmaker friends, Czech and Slovak creator groups, and communities for the languages the big apps skip (Baltic, Balkan, Hungarian, Greek, Maltese editors).

## 6. Later, for the App Store release (not needed for the beta)

- In-app purchases: `cz.krechler.bombocut.trial` (non-consumable, price 0, "7-day Free Trial") and `cz.krechler.bombocut.full` (non-consumable, 149 Kč, Family Sharing on).
- Screenshots (6.9" and 6.5"), description, keywords, age rating, EU trader status (DSA).
- Support URL and the in-app Send feedback address.

## Privacy policy page

A ready privacy policy (English and Czech) is published as a Claude artifact titled "Bombocut Privacy" (https://claude.ai/artifact/QACyEYJCM5LmJACkh4kxdD). Open it, Share → make the link public, and use that link as the Privacy Policy URL. It says what the app really does: nothing collected, nothing tracked, the only network use is the one-time speech model download and the App Store purchase check.
