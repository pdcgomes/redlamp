# Cloud processing: App Store rules, privacy and keys (INF-11)

The rules that decide between DEC-39's three routes for sending work too heavy for the Mac to a cloud service: (1) a provider the photographer brings their own API key for ("BYOK"), (2) a third-party provider Redlamp works with, possibly with Redlamp selling a subscription or credits, and (3) a ComfyUI server the photographer runs or hosts. It covers Apple's App Review Guidelines and App Privacy label, the GDPR and UK GDPR, what the providers' published terms say about data and provenance, the EU AI Act's marking rule, and how to keep keys on the Mac. The providers' models, prices and quality are INF-11's other half and aren't covered here.

Every source was read on 7 October 2026; Wayback Machine snapshots carry their own dates. Quotes are verbatim. Claims are labelled **Evidence** (what a source says) or **Assessment** (our reading, which counsel or a test should confirm), and **UNVERIFIED** marks what couldn't be checked. We signed up for nothing, used no API keys, made no authenticated calls and bought nothing. EUR-Lex refused automated requests, so EU legislation was read from the Publications Office's copies of the Official Journal. This is an engineering survey, not legal advice.

## Summary

- **BYOK needs no in-app purchase.** Evidence: the guidelines have no rule about API keys people bring; in-app purchase is required "If you want to unlock features or functionality within your app" (3.1.1), and Redlamp would sell nothing. Mac App Store apps already do it: OpenCat lists "BYOK — use your own API Key", and Drafts' documentation says "you will have to setup your own OpenAI account and generate an API Key" (§3).
- **A service Redlamp sells needs in-app purchase in the Mac App Store,** and credits bought that way "may not expire" (3.1.1). Since 1 May 2025, US storefront apps may also link to purchases on the web. The April 2025 order barred any commission on those purchases; the Ninth Circuit (11 December 2025) allows one that covers Apple's "necessary costs" once the district court permits it. Apple proposed 15%, 10% and 5% on 13 August 2026, no rate had been set by 25 September 2026, and the Supreme Court has granted certiorari. That litigation concerns the iOS and iPadOS App Store, so whether the US link-out applies to the Mac App Store is UNVERIFIED. In EU storefronts, from 1 October 2026, macOS apps (on macOS 26.6 or later) may use their own payment processor (20% commission) or link out (15%), beside or instead of in-app purchase (26%).
- **Apple's privacy rule names third-party AI.** Since 13 November 2025, 5.1.2(i) reads: "You must clearly disclose where personal data will be shared with third parties, including with third-party AI, and obtain explicit permission before doing so." Assessment: this applies to every route, BYOK included, because the app transmits the crop.
- **Every App Store app needs a privacy policy** (5.1.1(i)), and redlamp.app has none: `/privacy`, `/privacy-policy`, `/legal` and `/terms` return 404, and the footer links only an "AI disclosure". Report a Bug already stores screenshots and diagnostics in a public GitHub repository, so the App Privacy label can't say "Data Not Collected" whichever route ships.
- **Keys belong in the data protection keychain.** Assessment: as generic password items (`kSecUseDataProtectionKeychain`), accessible when unlocked, on this device only, in the app's private access group. Apple's TN3137 (revised 24 September 2026) recommends that keychain on macOS, and its access groups need a provisioning profile, which matters for the Developer ID build.
- **GDPR: BYOK keeps Redlamp out of the processing; a relay makes Redlamp the controller.** Assessment: with BYOK, Redlamp processes nothing, and the provider answers to the photographer, or acts as a controller where it uses uploads for its own purposes; BFL's privacy policy says it may use uploads "to train and improve our AI models". A Redlamp relay is a controller even if it keeps nothing, because in the EDPB's words "It is not necessary that the controller actually has access to the data that is being processed to be qualified as a controller". It then needs a privacy policy, processor agreements, a list of recipients, records of processing and transfer mechanisms (Data Privacy Framework or standard contractual clauses).
- **Providers mark their outputs, and compositing loses the metadata.** Evidence: OpenAI's images carry C2PA Content Credentials and SynthID; Google's Gemini API images carry SynthID, and Vertex AI adds Content Credentials; BFL's API signs C2PA; Adobe applies Content Credentials "for certain types of exports"; Stability is "implementing" C2PA; nothing was found for Ideogram or for fal itself. BFL's Developer Terms forbid "Remove, disable, alter, obscure, any Content Credentials". The IPTC term for an inpainted photo is `compositeWithTrainedAlgorithmicMedia` ("such as with inpainting or outpainting operations").
- **EU AI Act Article 50(2) has applied since 2 August 2026.** Assessment: generative fill is beyond the "standard editing" exception, because the Commission's guidelines say standard editing "does not involve generating new content", and open-source systems aren't exempt. Redlamp may therefore be a "provider" that must mark outputs, certainly for a service it runs and possibly for its on-device fill (RM-10). That makes Content Credentials export (RM-03) more urgent; a question for counsel.
- **Lightest first: BYOK for generative fill.** It needs no payments, accounts, servers or processor agreements, but it does need an explicit, provider-named consent before the first request, a privacy policy, an accurate privacy label, keys in the keychain, and Content Credentials that keep the provider's manifest (§7).

---

## 1. App Review Guidelines: payments and keys people bring

### 1.1 In-app purchase and its exceptions

**Evidence.** The [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) read "Last Updated: June 8, 2026".

- **3.1.1:** "If you want to unlock features or functionality within your app, (by way of example: subscriptions, in-game currencies, game levels, access to premium content, or unlocking a full version), you must use in-app purchase. Apps may not use their own mechanisms to unlock content or functionality, such as license keys, augmented reality markers, QR codes, cryptocurrencies and cryptocurrency wallets, etc."
- **3.1.1:** "Any credits or in-game currencies purchased via in-app purchase may not expire, and you should make sure you have a restore mechanism for any restorable in-app purchases." And: "Apps may use in-app purchase currencies to enable customers to “tip” the developer or digital content providers in the app." (The Settings window's Ko-fi link already carries a code comment that an App Store build needs a tip jar instead.)
- **3.1.1:** "Apps distributed via the Mac App Store may host plug-ins or extensions that are enabled with mechanisms other than the App Store."
- **3.1.2(a):** an auto-renewable subscription "must provide ongoing value to the customer, and the subscription period must last at least seven days and be available across all of the user’s devices"; "software as a service (“SAAS”); and cloud support" are among the examples it lists.
- **3.1.3:** "The following apps may use purchase methods other than in-app purchase. Apps in this section cannot, within the app, encourage users to use a purchasing method other than in-app purchase, except for apps on the United States storefront and as set forth in 3.1.1(a) and 3.1.3(a). Developers can send communications outside of the app to their user base about purchasing methods other than in-app purchase."
- **3.1.3(b) Multiplatform Services:** "Apps that operate across multiple platforms may allow users to access content, subscriptions, or features they have acquired in your app on other platforms or your web site, including consumable items in multi-platform games, provided those items are also available as in-app purchases within the app."
- **3.1.3(f) Free Stand-alone Apps:** "Free apps acting as a stand-alone companion to a paid web based tool (i.e. VoIP, Cloud Storage, Email Services, Web Hosting) do not need to use in-app purchase, provided there is no purchasing inside the app, or calls to action for purchase outside of the app."
- **2.4.5, for the Mac App Store:** "(i) They must be appropriately sandboxed, and follow macOS File System Documentation"; "(iv) They may not download or install standalone apps, kexts, additional code, or resources to add functionality or significantly change the app from what we see during the review process"; "(vi) They may not present a license screen at launch, require license keys, or implement their own copy protection."
- **Review access:** 2.1(a) asks developers to "include demo account info (and turn on your back-end service!) if your app includes a login"; the checklist before it says "Provide App Review with full access to your app … plus any other hardware or resources that might be needed to review your app (e.g. login credentials or a sample QR code)".
- **Accounts:** 5.1.1(v): "If your app doesn’t include significant account-based features, let people use it without a login. If your app supports account creation, you must also offer account deletion within the app." 4.8: "Apps that use a third-party or social login service (such as Facebook Login, Google Sign-In, …) to set up or authenticate the user’s primary account with the app must also offer as an equivalent option another login service" that "limits data collection to the user’s name and email address", lets users keep their email address private, and doesn't collect interactions for advertising without consent.

### 1.2 The United States after Epic v. Apple

**Evidence**, in order:

- **Before the 2025 order.** Apple's StoreKit External Purchase Link Entitlement (US) page ([snapshot of 26 April 2025](https://web.archive.org/web/20250426182828/https://developer.apple.com/support/storekit-external-entitlement-us/); the live URL now redirects to Apple's support index) required apps to "Be available on the iOS or iPadOS App Store in the United States storefront", said "The Entitlement Profile is compatible and may only be used with applications distributed through the United States App Store, on devices running iOS or iPadOS 15.4 or later", and charged "27% on proceeds you earn from sales … after a link out" (12% for Small Business Program members and renewals after the first year).
- **30 April 2025.** The district court "PERMANENTLY RESTRAINS AND ENJOINS Apple Inc. … from: 1. Imposing any commission or any fee on purchases that consumers make outside an app …; 2. Restricting or conditioning developers’ style, language, formatting, quantity, flow or placement of links for purchases outside an app; 3. Prohibiting or limiting the use of buttons or other calls to action …" ([order, Dkt. 1508](https://storage.courtlistener.com/recap/gov.uscourts.cand.364265/gov.uscourts.cand.364265.1508.0_4.pdf), Case 4:20-cv-05640-YGR).
- **1 May 2025.** Apple: "The App Review Guidelines have been updated for compliance with a United States court decision regarding buttons, external links, and other calls to action in apps. These changes affect apps distributed on the United States storefront of the App Store, and are reflected in updates to Guidelines 3.1.1, 3.1.1(a), 3.1.3, and 3.1.3(a)" ([news](https://developer.apple.com/news/?id=9txfddzf)). In the [September 2024 version](https://web.archive.org/web/20250420110308/https://developer.apple.com/app-store/review/guidelines/), 3.1.3's exception read only "except as set forth in 3.1.3(a)". Today 3.1.1(a) adds: "These entitlements are not required for developers to include buttons, external links, or other calls to action in their United States storefront apps."
- **11 December 2025.** The [Ninth Circuit](https://cdn.ca9.uscourts.gov/datastore/opinions/2025/12/11/25-2935.pdf) (No. 25-2935) affirmed the contempt finding, but held that "a commission prohibition did not qualify as a civil contempt sanction in its present form" (court staff's summary) and that "Apple should be able to charge a commission on linked-out purchases based on the costs that are genuinely and reasonably necessary for its coordination of external links for linked-out purchases, but no more." Its disposition: "Apple is not enjoined from imposing a commission or fee on purchases that consumers make in an app utilizing iOS outside the Apple Store (a linked-out purchase) as permitted by the district court on remand."
- **13 August 2026.** Apple's [remand proffer](https://storage.courtlistener.com/recap/gov.uscourts.cand.364265/gov.uscourts.cand.364265.1708.0.pdf) (Dkt. 1708): "On June 30, 2026, the Supreme Court granted certiorari to review the Ninth Circuit’s judgment. On August 11, 2026, this Court denied Apple’s motion to stay these proceedings pending Supreme Court review". It proposes "15% for standard apps", "10% for the Video Partner Program (“VPP”), the News Partner Program (“NPP”), the Mini Apps Partner Program (“MPP”), and subscription renewals", and "5% for Small Business Program apps". Its footnote 11: "References to iOS herein also include iPadOS, and the App Store refers to the App Store for iOS and iPadOS apps." The [docket](https://www.courtlistener.com/api/rest/v4/search/?q=docket_id%3A17442392&type=rd&order_by=entry_date_filed%20desc)'s latest entries, up to Dkt. 1719 (25 September 2026), show the remand still open, and none of them sets a commission.

**Assessment.** In the US storefront an app may today show buttons and links to a purchase on its own website. Apple may charge a commission on those purchases only once the district court permits one, which hadn't happened by 25 September 2026, and the Supreme Court's review could change all of this. Two points remain open. Whether this reaches the Mac App Store is UNVERIFIED: the guideline names only the "United States storefront", but the entitlement it replaced was for iOS and iPadOS, and the case concerns the iOS and iPadOS App Store. The guidelines also don't say whether a US app that links out must still offer in-app purchase, and 3.1.1's requirement was not removed.

### 1.3 The EU and the Digital Markets Act, now including macOS

**Evidence.**

- On 26 June 2025, "The European Commission has required Apple to make a series of additional changes under the Digital Markets Act", letting "developers with apps in the European Union storefronts of the App Store communicate and promote offers for purchase of digital goods or services available at a destination of their choice" ([news](https://developer.apple.com/news/?id=awedznci)).
- On 18 August 2026 Apple announced it was "moving every developer that distributes apps in the EU to a single set of business terms", effective 1 October 2026 and set out in Attachment 14 of the Developer Program License Agreement ([news](https://developer.apple.com/news/?id=gmws0jgp), [news](https://developer.apple.com/news/?id=0cgo95n6)).
- Apple's [EU page](https://developer.apple.com/support/apps-in-the-eu/): "In the EU, there are additional options, which include specific business terms for iOS, iPadOS, macOS, tvOS, visionOS, and watchOS apps distributed in EU storefronts." Besides in-app purchase, apps can "Offer digital goods and services for purchase within your app using an alternative payment processor" and "Provide out-of-app offers that direct users to purchase digital goods and services at a destination of your choice".
- The commissions on that page: in-app purchase 26% (15% for Small Business Program members and subscriptions after their first year); an alternative payment processor in the app 20% (10%); a "store services commission" of 15% (10%) on out-of-app offers with an actionable link, on "sales made within 7 days of the link tap".
- [Payment options on the App Store in the EU](https://developer.apple.com/support/payment-options-on-the-app-store-in-the-eu/):
  - "The Entitlement Profile is compatible with and may only be used in apps on EU storefronts on devices running a minimum of iOS 26.2, iPadOS 26.2, macOS 26.6, tvOS 26.6, visionOS 26.6, and watchOS 26.6."
  - "Apple In-App Purchase must be presented as an option at the same time you offer any alternative payments using an alternative payment processor within the app, or when you direct users out of your app with actionable links", and "must be displayed at least as prominently as any other payment option shown".
  - "If you choose to only offer alternative payment options in your app, … you must ensure that users have a genuine opportunity to choose alternative payment processing within the app."
  - "Apps in the EU subject to Guideline 3.1.3(b) Multiplatform Services must offer Apple In-App Purchase and/or alternative payment processing within the app as an option for the purchase of digital goods and services."
  - "once you select a payment option or combination … you must maintain that choice across all EU storefronts for 12 months."
  - "Your app’s App Store product page may not include information about purchasing with an alternative payment option."
  - Alternative payments also require the StoreKit External Purchases or Offers Entitlement, Apple's in-app disclosure sheet, monthly transaction reports, and parental gates for users under 18 (out-of-app offers aren't permitted for users under 13).
- Apple's other regional terms are for iOS only: "Specified terms for iOS apps in Japan" ([17 December 2025](https://developer.apple.com/news/?id=76371du6)) and "terms for iOS apps in Brazil" ([18 June 2026](https://developer.apple.com/news/?id=umq9wxmm)).

### 1.4 Keys people bring

**Evidence.** The guidelines contain no rule on API keys that users enter for third-party services. A search of the full text for "API key", "key" and "credential" finds license keys as an unlock mechanism (3.1.1, 2.4.5(vi)), demo credentials for App Review (2.1), unrelated uses (Wallet passes, keyboard keys), and social-network credentials: "An app may not store credentials or tokens to social networks off of the device and may only use such credentials or tokens to directly connect to the social network from the app itself while the app is in use" (5.1.1(v)).

**Assessment.** A BYOK feature doesn't need in-app purchase. The photographer pays the provider for the provider's service, under their own account; Redlamp sells nothing and unlocks nothing of its own, and every on-device feature works without a key, so the key isn't a "license key" either. 3.1.3(f) states the same principle for companion apps, and the Mac App Store apps in §3 show it in practice. Three cautions follow:

- Outside the US storefront, Settings should link to the provider's documentation for creating a key without prices or "buy credits" wording, to stay clear of 3.1.3's calls to action.
- App Review must be able to try the feature (2.1), so the review notes need a temporary key with a spending limit, revoked after review.
- The key stays on the Mac and the app connects straight to the provider, which matches the spirit of 5.1.1(v).

### 1.5 Assessment: a Mac App Store Redlamp in October 2026

- **BYOK and ComfyUI:** no payment rules apply. 2.4.5(i) requires the sandbox, so the app needs the outgoing-connections entitlement (§4.2). ComfyUI workflow templates should ship inside the bundle rather than be downloaded, to keep clear of 2.4.5(iv) (an assessment: templates are data, not code).
- **A service Redlamp sells:** in-app purchase (3.1.1); credits that never expire, with a restore mechanism; if it's also sold on redlamp.app, the same items must be offered through in-app purchase (3.1.3(b)). Accounts bring in-app deletion (5.1.1(v)), the login-services rule if third-party sign-in is offered (4.8), and a demo account for review (2.1). EU storefronts may add a processor or a link on macOS 26.6 or later; whether US storefront Mac apps may link out is UNVERIFIED.

---

## 2. Privacy guidelines and the App Privacy label

### 2.1 Guidelines 5.1.1 and 5.1.2

**Evidence** ([guidelines](https://developer.apple.com/app-store/review/guidelines/)):

- **5.1.2(i):** "Unless otherwise permitted by law, you may not use, transmit, or share someone’s personal data without first obtaining their permission. You must provide access to information about how and where the data will be used. You must clearly disclose where personal data will be shared with third parties, including with third-party AI, and obtain explicit permission before doing so. Data collected from apps may only be shared with third parties to improve the app or serve advertising (in compliance with the Apple Developer Program License Agreement). …"
- **When the AI wording arrived:** Apple's [13 November 2025 news](https://developer.apple.com/news/?id=ey6d8onl): "5.1.2(i): Clarifies that you must clearly disclose where personal data will be shared with third parties, including with third-party AI, and obtain explicit permission before doing so." The [snapshot of 20 October 2025](https://web.archive.org/web/20251020091829/https://developer.apple.com/app-store/review/guidelines/) (guidelines "Last Updated: June 9, 2025") has 5.1.2(i) without that sentence. Apple's later revisions (6 February and 8 June 2026) didn't touch 5.1.
- **5.1.2(ii):** "Data collected for one purpose may not be repurposed without further consent unless otherwise explicitly permitted by law."
- **5.1.1(i):** "All apps must include a link to their privacy policy in the App Store Connect metadata field and within the app in an easily accessible manner." The policy must "Identify what data, if any, the app/service collects, how it collects that data, and all uses of that data"; "Confirm that any third party with whom an app shares user data … will provide the same or equal protection of user data as stated in the app’s privacy policy and required by these Guidelines"; and "Explain its data retention/deletion policies and describe how a user can revoke consent and/or request deletion of the user’s data."
- **5.1.1(ii):** "Apps that collect user or usage data must secure user consent for the collection … Apps must also provide the customer with an easily accessible and understandable way to withdraw consent."
- **5.1.1(iii):** "Apps should only request access to data relevant to the core functionality of the app and should only collect and use data that is required to accomplish the relevant task."
- **Section 5:** "Apps must comply with all legal requirements in any location where you make them available".

### 2.2 What Redlamp must disclose or ask before sending a crop

**Assessment.** 5.1.2(i) is about what the app does ("use, transmit, or share"), so it applies whether the crop goes to the photographer's own provider or through a Redlamp service. A crop can show people, so it can hold personal data (§5.1). In both cases Redlamp needs:

- explicit permission before the first request to each provider, naming the provider and what is sent, with a way to withdraw it (5.1.1(ii));
- a privacy policy reached from the app and App Store Connect (5.1.1(i)), saying what goes where, for how long, and how to revoke and delete;
- no reuse of what is sent for another purpose (5.1.2(ii)).

For BYOK, Redlamp can't "confirm" that every provider protects data as its own policy does (5.1.1(i)): the provider's terms, accepted by the photographer, govern. The policy should say so, and Redlamp should only offer providers whose published terms it has checked and describes; for example, BFL's privacy policy says it may train on uploads unless the user writes to opt out (§5.2). For a Redlamp service, the policy has to name the providers, their roles and countries, and Redlamp's own retention, and the GDPR adds its own content (§5.3).

### 2.3 What the App Privacy label would declare

**Evidence** ([App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)):

- "“Collect” refers to transmitting data off the device in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time."
- "“Third-party partners” refers to analytics tools, advertising networks, third-party SDKs, or other external vendors whose code you’ve added to your app."
- "Data that is processed only on device is not “collected” and does not need to be disclosed in your answers."
- "if you have a feature that enables users to upload a particular media type, such as photos or videos, then you’ll need to disclose the specific type of data."
- "if an authentication token or IP address is sent on a server call and not retained, or if data is sent to your servers then immediately discarded after servicing the request, you do not need to disclose this".
- Data is optional to disclose only if all four criteria hold, the last being: "The data is provided by the user in your app’s interface, it is clear to the user what data is collected, the user’s name or account name is prominently displayed in the submission form alongside the other data elements being submitted, and the user affirmatively chooses to provide the data for collection each time."
- "“Personal Information” and “Personal Data”, as defined under relevant privacy laws, are considered linked to the user." And: "You are not responsible for disclosing data collected by Apple."
- "Photos or Videos" ("The user’s photos or videos") is a User Content data type; "App Functionality" covers uses "to authenticate the user, enable features, prevent fraud, …".

**Assessment.**

| Route | Declare | Why |
| --- | --- | --- |
| BYOK | Photos or Videos, for App Functionality, not linked, not used for tracking | Redlamp can't access the crop, and the provider's code isn't in the app. But the photo-upload sentence above, and providers that keep requests (OpenAI's abuse-monitoring logs, 30 days), make declaring it the cautious answer. Precedents differ (§3) |
| Redlamp service | Photos or Videos (App Functionality); with accounts, Email Address and User ID (App Functionality), all linked; Purchase History if Redlamp's server keeps credit balances; Product Interaction if it counts requests | The relay's "immediately discarded" exemption doesn't cover the providers behind it, which keep or may train on requests (§5) |
| ComfyUI | Nothing for the fill when the server is the photographer's own; as BYOK when a third party hosts it | The photographer's server isn't Redlamp's partner |

### 2.4 What the App Store needs whichever route ships

- **A privacy policy** (5.1.1(i)); redlamp.app has none (§5.4).
- **Report a Bug is already data collection.** `web/lib/feedback.ts` files each report "with its screenshots and diagnostics.json in a public attachments repo" (up to three JPEG screenshots of 1.5 MB each and a 2 MB diagnostics file). That is collected data (likely Photos or Videos or Other User Content, Other Diagnostic Data and Customer Support). Assessment: it can't use optional disclosure, because a reporter has no account name to show in the form.
- **A privacy manifest:** "The types of data collected by your app or third-party SDK. You need to provide this information for your app or third-party SDK on all platforms" ([privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)). The repository has no `PrivacyInfo.xcprivacy`; declaring required-reason APIs applies only to "iOS, iPadOS, tvOS, visionOS, and watchOS".

---

## 3. Precedents in the Mac App Store

**Evidence**, from each app's App Store page (US storefront) and Apple's [lookup API](https://itunes.apple.com/lookup?id=6445999201,6739738501,6444050820,1435957248,497799835&country=us&entity=macSoftware), plus the developers' documentation where cited:

| App | What it offers | Mac | Paid parts (in-app purchase) | App Privacy label |
| --- | --- | --- | --- | --- |
| [OpenCat](https://apps.apple.com/us/app/opencat-ai-chat-agent-mcp/id6445999201) (Early Moon, LLC; 26.9.5, 30 September 2026) | "BYOK — use your own API Key, including Coding Plan"; "[Use Your Own API Key] · 25+ providers supported — OpenAI, Claude, Gemini, DeepSeek, Kimi, Qwen, Doubao, ERNIE, and more"; and "OpenCat Cloud — fast access to leading models" | "Requires macOS 14.0 or later" | "Cloud AI $3.99", "OpenCat Pro $9.99", "Cloud AI $24.99", "Tokens Package $5.99" | Data Not Linked to You: Usage Data, Product Interaction (Analytics); Crash Data (Diagnostics) |
| [Drafts](https://apps.apple.com/us/app/drafts/id1435957248) (Agile Tortoise; 54.0.5; Apple lists it as `mac-software`, macOS 12.4 or later) | Its [scripting reference](https://scripting.getdrafts.com/classes/OpenAI): "Drafts does not provide an API Key for use with OpenAI. To use OpenAI features, you will have to setup your own OpenAI account and generate an API Key for use with Drafts in the developer portal", "Integrating with Drafts Credentials system to store your API key"; the same for [Anthropic](https://scripting.getdrafts.com/classes/AnthropicAI) and [Google AI](https://scripting.getdrafts.com/classes/GoogleAI) | Native Mac app | Drafts Pro subscription (actions, themes, workspaces) | Not read (the page answered HTTP 429) |
| [Reins](https://apps.apple.com/us/app/reins-for-ollama-lm-studio/id6739738501) (Ibrahim Cetin; 2.3.2) | "Reins connects to your Ollama, LM Studio or any OpenAI-compatible server"; "Connect multiple servers, configure API keys and custom headers" | "Requires macOS 14.0 or later" | "Yearly $39.99", "Monthly $6.99", "Lifetime $99.99" | "Data Not Collected" |
| [Draw Things](https://apps.apple.com/us/app/draw-things-offline-ai-art/id6444050820) (Draw Things, Inc.) | Image generation on the device, "(Optional Cloud Compute available)" | "Requires macOS 12" | "Draw Things+ $8.99", "Boost Bundle S $0.99", "M $4.99", "L $19.99" | Data Not Linked to You, for App Functionality: Purchase History, Other User Content, User ID |
| [Xcode](https://apps.apple.com/us/app/xcode/id497799835) (Apple; 27.0, macOS 26.6 or later) | [Coding intelligence](https://developer.apple.com/documentation/xcode/setting-up-coding-intelligence): "To use another chat provider, click the Add a Chat Provider button under Chat. To add a provider that’s hosted on the internet, select Internet Hosted, enter the URL and other details"; "the agent or model that you set up in the Intelligence settings may access your project files"; "click “About Intelligence in Xcode & Privacy…”" | Mac App Store | None | Not read |

**Assessment.** OpenCat and Drafts confirm BYOK with keys typed into a Mac App Store app, with no purchase involved; Reins and Xcode confirm the "your own server" pattern behind ComfyUI. OpenCat and Draw Things show a developer-run cloud sold through in-app purchase beside a free local or BYOK path, which is route 2's shape. Their labels differ: OpenCat declares no user content even though its cloud relays it, while Draw Things declares Other User Content. Precedent doesn't settle the label, so §2.3's cautious answer stands. Apple's lookup API lists OpenCat, Reins and Draw Things as iOS records (`software`) that also run on the Mac; their pages don't say whether that is a Mac Catalyst build or the iPad app on Apple silicon.

---

## 4. Keeping keys on the Mac

### 4.1 Apple's guidance

**Evidence.**

- **Which keychain** ([TN3137: On Mac keychain APIs and implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains), revised 2026-09-24): "Choosing a keychain API is easy: Use the SecItem API." macOS has a file-based keychain and a data protection keychain; the SecItem API "defaults to targeting the file-based keychain. To target the data protection keychain, set the kSecUseDataProtectionKeychain attribute or the kSecAttrSynchronizable attribute to true." "Default to targeting the data protection keychain", and "The file-based keychain is on the road to deprecation." "The data protection keychain is only available in a user login context."
- **Access groups need a profile** (TN3137): "macOS builds the list of data protection keychain access groups available to your program from its code signing entitlements. … These entitlements must be authorized by a provisioning profile." And: "If you’re building library code, its data protection keychain access is determined by the entitlements of the host process’s main executable." Keychain Access shows the data protection keychain "as either iCloud Keychain or Local Items", but "only password items" from it.
- **[`kSecUseDataProtectionKeychain`](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain):** "It’s highly recommended that you set the value of this key to `true` for all keychain operations." "Use kSecUseDataProtectionKeychain to get the iOS behavior without synchronization."
- **[`kSecClassGenericPassword`](https://developer.apple.com/documentation/security/ksecclassgenericpassword):** its primary key is the access group, account, service and synchronizable attributes; the access group and accessibility apply on macOS "only if you set kSecUseDataProtectionKeychain or kSecAttrSynchronizable to true".
- **Accessibility** ([Restricting keychain item accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility)): "Always use the most restrictive option that makes sense for your app." [`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly): "The data in the keychain item can be accessed only while the device is unlocked by the user. … Items with this attribute do not migrate to a new device." [`kSecAttrAccessibleWhenUnlocked`](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlocked) "is the default value". [`kSecAttrAccessible`](https://developer.apple.com/documentation/security/ksecattraccessible): "For any item marked as synchronizable, the value for the kSecAttrAccessible key may only be one whose name does not end with `ThisDeviceOnly`".
- **iCloud Keychain** ([`kSecAttrSynchronizable`](https://developer.apple.com/documentation/security/ksecattrsynchronizable)): "Updating or deleting items using the kSecAttrSynchronizable key affects all copies of the item, not just the one on your local device. Be sure that it makes sense to use the same password on all devices before making a password synchronizable." Apple's [iCloud data security overview](https://support.apple.com/en-us/102651) lists "Passwords and Keychain" as end-to-end encrypted under standard data protection.
- **Sharing between processes** ([Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps), [`kSecAttrAccessGroup`](https://developer.apple.com/documentation/security/ksecattraccessgroup)): an app's groups are the Keychain Access Groups entitlement, then its app ID, then its App Groups; with no explicit group, "the item is only accessible to the app creating the item". Items created in a shared group need the same team-prefixed group in each program's [Keychain Access Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups).
- **Network** ([`com.apple.security.network.client`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)): "A Boolean value indicating whether your app may open outgoing network connections." On macOS 15 and later, the first connection to the local network shows an alert, and "If your app accesses the local network, add the NSLocalNetworkUsageDescription property to its `Info.plist`" ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)). App Transport Security blocks IP addresses by default from macOS 14, and [`NSAllowsLocalNetworking`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) re-enables "unqualified domains, `.local` domains, and IP addresses".

### 4.2 Assessment: how Redlamp should keep a key

- **One generic password item per provider:** service `app.redlamp.cloud`, account the provider's ID (`fal`, `bfl`, `openai`), a label such as "Redlamp: fal API key" (what Keychain Access shows), `kSecUseDataProtectionKeychain` true, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable, and no explicit access group, so only the app can read it.
- **Sync stays off at first.** Offer "Use on my other devices (iCloud Keychain)" when the iPad and iPhone apps arrive (Phase 5). The item then has to be re-created synchronizable with `kSecAttrAccessibleWhenUnlocked`, and deleting it removes it everywhere.
- **The Developer ID build needs a provisioning profile.** By TN3137, the data protection keychain's groups come from entitlements a provisioning profile authorises. The App Store build has one; the direct-download build would need a Developer ID provisioning profile, or would fall back to the file-based keychain. Test this before the feature ships (UNVERIFIED in practice).
- **One process holds the key.** The request should leave from the app, or from one network-only XPC service; the decoder service stays offline, as it is today (`RedlampDecoder.entitlements` holds only the sandbox). A helper that needs the key should receive it per request over XPC, rather than share an access group.
- **The key goes nowhere else.** Not into `UserDefaults`, sidecars, logs, crash reports, Report a Bug's `diagnostics.json` or the activity log. Redact the `Authorization` header in any request log, and show only the last four characters in Settings.
- **Sandbox entitlements** for the App Store build (the app isn't sandboxed yet, README "Known limitations"): `com.apple.security.network.client`. For ComfyUI on the local network: `NSLocalNetworkUsageDescription` and `NSAllowsLocalNetworking`. A ComfyUI server reached over the internet should require HTTPS.

---

## 5. Privacy law: GDPR and UK GDPR

### 5.1 The terms

**Evidence** (GDPR, [OJ L 119, 4.5.2016](https://publications.europa.eu/resource/cellar/3e485e15-11bd-11e6-ba9a-01aa75ed71a1.0006.01/DOC_1)):

- Art. 4(1): "‘personal data’ means any information relating to an identified or identifiable natural person". Recital 51: "The processing of photographs should not systematically be considered to be processing of special categories of personal data as they are covered by the definition of biometric data only when processed through a specific technical means allowing the unique identification or authentication of a natural person."
- Art. 4(7): "‘controller’ means the natural or legal person, public authority, agency or other body which, alone or jointly with others, determines the purposes and means of the processing of personal data". Art. 4(8): "‘processor’ means a natural or legal person, public authority, agency or other body which processes personal data on behalf of the controller". The [UK GDPR](https://www.legislation.gov.uk/eur/2016/679/article/4) has the same definitions, adding "(but see section 6 of the 2018 Act)" to the controller's.
- Art. 2(2)(c): the Regulation doesn't apply to processing "by a natural person in the course of a purely personal or household activity". Recital 18: "However, this Regulation applies to controllers or processors which provide the means for processing personal data for such personal or household activities."
- Recital 78: "producers of the products, services and applications should be encouraged to take into account the right to data protection when developing and designing such products, services and applications".
- EDPB [Guidelines 07/2020](https://www.edpb.europa.eu/system/files/2023-10/EDPB_guidelines_202007_controllerprocessor_final_en.pdf) (version 2.1):
  - "It is not necessary that the controller actually has access to the data that is being processed to be qualified as a controller" (executive summary).
  - In its "standardised cloud storage service" example: "Company X will still be considered a controller, given its decision to make use of this particular cloud service provider in order to process personal data for its purposes. Insofar as the cloud service provider does not process the personal data for its own purposes and stores the data solely on behalf of its customers and in accordance with instructions, the service provider will be considered as a processor."
  - Para. 81: "the processor may not carry out processing for its own purpose(s). As provided in Article 28(10), a processor infringes the GDPR by going beyond the controller’s instructions … The processor will be considered a controller in respect of that processing".
  - Para. 40: the essential means include "the type of personal data which are processed", "the duration of the processing" and "the categories of recipients".
  - Para. 56: "The fact that one of the parties does not have access to personal data processed is not sufficient to exclude joint controllership."

### 5.2 (a) The photographer sends the crop with their own key, from an app with no servers

**Evidence on the providers' side:**

- [BFL's privacy policy](https://bfl.ai/legal/privacy-policy) (revised 1 August 2026): "We may collect, store and use information you provide via the Services, including text prompts, uploaded content (like images) … and the corresponding generated outputs to train and improve our AI models after implementing appropriate technical safeguards like data minimisation and deidentification techniques"; objection is by email with the subject "Training Opt Out". "If you live in the European Economic Area (EEA), Switzerland, or the United Kingdom, BFL GmbH is the data controller".
- [fal](https://fal.ai/privacy) (22 July 2026): "If you are an enterprise user of the Services, and your use is governed by an enterprise contract, we handle your personal information as a service provider (sometimes called a "processor") on behalf of the enterprise customer."
- [Google's Gemini API terms](https://ai.google.dev/gemini-api/terms) (effective 23 March 2026): "Use of Google AI Studio and Gemini API is for developers building with Google AI models for professional or business purposes, not for consumer use." On unpaid use, "Google uses the content you submit to the Services and any generated responses to provide, improve, and develop Google products", but "If you're in the European Economic Area, Switzerland, or the United Kingdom, the terms under "How Google uses Your Data" in "Paid Services" apply to all Services". Paid use runs under the "Data Processing Addendum for Products Where Google is a Data Processor".
- [OpenAI](https://platform.openai.com/docs/guides/your-data): "data sent to the OpenAI API is not used to train or improve OpenAI models (unless you explicitly opt in to share data with us)"; abuse-monitoring logs are "retained for up to 30 days", and `/v1/images/edits` is listed with 30 days of abuse-monitoring retention.

**Assessment.**

- **Redlamp** neither receives nor stores the crop or the key, and has no purpose of its own in the request, so it is neither controller nor processor of that processing. Para. 56's warning about access concerns parties who take part in a processing operation, which Redlamp doesn't. As the maker of the software it still decides what the request contains (Recital 78); DEC-39's crop-only, no-metadata design is that minimisation.
- **A photographer editing their own photos as a hobby** is within the household exemption (Art. 2(2)(c)). The provider isn't: Recital 18 keeps the GDPR on those "which provide the means".
- **A professional photographer** is the controller for the people in the photos. The provider is their processor where it acts only on instructions (the EDPB's cloud example, typically under a business or enterprise agreement), and a controller for anything it does for its own purposes: training on uploads (BFL by default, Google's unpaid tier outside the EEA, Switzerland and the UK), or fal outside an enterprise contract.
- **Redlamp should only offer providers whose terms it can describe accurately,** and say plainly in the consent sheet when a provider trains on uploads (§7.3). Whether Google's "not for consumer use" admits hobbyists bringing their own Gemini key, and whether Redlamp counts as "making API Clients available to users" in the EEA under those terms, are questions for counsel.

### 5.3 (b) Redlamp runs a service that relays the crop to a provider

**Evidence.**

- BFL's privacy policy: "if you are an end user of a service that incorporates or integrates our Services, the service provider is the controller of your personal data".
- BFL's [Developer Terms](https://bfl.ai/legal/developer-terms-of-service) (revised 4 August 2026; the [EU version](https://bfl.ai/legal/eu-developer-terms-of-service) of 26 August 2026 has the same clauses) bind a developer not to "allow or facilitate any third party (including any Permitted User or End User) to": "(j) Upload images of individuals to the FLUX Services or FLUX AI Models without their consent", or "(k) Upload images, videos or personal data to the FLUX Services or FLUX AI Models relating to individuals under the age of 18".
- RapidRAW's policy describes the chain such a service creates: its backend on Hetzner in the EU, fal in the USA, Ideogram in Toronto ([RR §3.4](../rapidraw-findings.md#34-rapidraw-cloud)).

**Assessment.** Redlamp becomes the controller for its accounts, billing, usage counters, and the fill service itself, since it decides why the crop is processed, by whom and for how long. That holds even if the relay only keeps the crop in memory, because a controller needn't have access to the data. For professional users processing their clients' photos, Redlamp would also act as their processor. The obligations:

- **Information:** a privacy policy giving what Art. 13(1) and (2) require: "the identity and the contact details of the controller", "the purposes of the processing … as well as the legal basis", "the recipients or categories of recipients", the "intends to transfer personal data to a third country" statement with "the existence or absence of an adequacy decision" or the safeguards, "the period for which the personal data will be stored", and the data subject's rights. The likely legal basis is the contract (Art. 6(1)(b)).
- **Processors:** under Art. 28(1), the controller "shall use only processors providing sufficient guarantees"; Art. 28(3) requires "a contract or other legal act" that sets out the processing and that the processor acts "only on documented instructions from the controller". In practice that means processor or enterprise terms with each provider and with the host. Self-serve terms often make the provider a controller for its own purposes (BFL's training, fal outside an enterprise contract), and that would have to be switched off or disclosed.
- **Sub-processors:** under Art. 28(2), "The processor shall not engage another processor without prior specific or general written authorisation of the controller", with notice of changes; Art. 28(4) passes the same obligations down the chain. For professional users that means a published list of sub-processors and notice of changes.
- **Records, security and breaches:** records of processing (Art. 30); the exemption for organisations under 250 people doesn't apply where "the processing is not occasional", and a fill service is regular processing. Security of processing (Art. 32), and breach notification (Arts. 33 and 34).
- **Transfers:** a transfer outside the EU "shall take place only if … the conditions laid down in this Chapter are complied with" (Art. 44). For the US, that is the EU-US Data Privacy Framework adequacy decision of 10 July 2023 ([Commission](https://commission.europa.eu/law/law-topic/data-protection/international-dimension-data-protection/eu-us-data-transfers_en)) for certified companies, which the General Court upheld on 3 September 2025 ([press release 106/25](https://curia.europa.eu/jcms/upload/docs/application/pdf/2025-09/cp250106en.pdf), T-553/23 Latombe), or otherwise "standard data protection clauses adopted by the Commission" (Art. 46(2)(c)). From the UK, the UK-US data bridge, in force "from the 12 October" 2023 ([explainer](https://www.gov.uk/government/publications/uk-us-data-bridge-supporting-documents/uk-us-data-bridge-explainer)), or the ICO's addendum to the EU clauses (named in BFL's policy).
- **A representative:** if Redlamp's operator isn't established in the EU, Art. 27(1) requires one: "Where Article 3(2) applies, the controller or the processor shall designate in writing a representative in the Union", with the exception in Art. 27(2)(a) for processing that "is occasional". The UK GDPR has its own equivalent. Where the operator is established wasn't checked.
- **Provider terms passed down:** BFL's 6(j) and 6(k) would require Redlamp to stop end users uploading people without consent and anyone under 18. Assessment: in practice that means a person check (Vision already finds people and faces) and a block or confirmation.

### 5.4 redlamp.app has no privacy policy today

**Evidence.** `https://redlamp.app/privacy`, `/privacy-policy`, `/legal`, `/terms`, `/about` and `/.well-known/security.txt` return HTTP 404, and the [sitemap](https://redlamp.app/sitemap.xml) lists the home page, Compare, Cameras, Test your camera, Performance and the blog. The footer's links are Blog, Compare with Lightroom, Supported cameras, Test your camera, Performance, "AI disclosure" (`/#ai`), Source on GitHub, README and status, Contributing, Discord, Support Redlamp (Ko-fi), RSS and the licence; it says "Free, with no subscription and no cloud". The AI disclosure says: "Photos are never uploaded." The repository has no privacy policy or `PrivacyInfo.xcprivacy` either.

**Assessment.** Report a Bug and the relay that files its reports as GitHub issues already make Redlamp a controller for what they receive (screenshots that may show people, and diagnostics), so a privacy policy is due now, and the App Store requires one regardless. DEC-39 already notes that the site's AI disclosure must change when the first cloud feature ships.

---

## 6. Provenance of generated pixels

### 6.1 What the providers add

**Evidence.**

| Provider | C2PA Content Credentials | Invisible watermark |
| --- | --- | --- |
| OpenAI | The [Content provenance guide](https://platform.openai.com/docs/guides/content-provenance) lists the "supported OpenAI provenance signals" it checks; for images, C2PA Content Credentials: "Signed metadata with issuer and AI-use details" | SynthID, for images and audio: "A watermark embedded directly in supported media". It adds: "Editing, converting, or sharing a file can remove its metadata. A SynthID watermark is part of the image or audio itself and may survive some transformations." It doesn't say which models add each; OpenAI's help article on C2PA refused the request (HTTP 403) |
| Google, Gemini API | Not stated on the [image generation page](https://ai.google.dev/gemini-api/docs/image-generation) | "All generated images include a SynthID watermark." |
| Google, Vertex AI | "If you generate a media file, such as an image, using a supported Google model, Content Credentials are automatically added and signed by Google LLC", for models including `gemini-2.5-flash-image`, `gemini-3-pro-image`, `gemini-3.1-flash-image` and `gemini-nano-banana-2.1` ([Content Credentials](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/content-credentials)). Google's [20 November 2025 post](https://blog.google/innovation-and-ai/products/ai-image-verification-gemini-app/): Nano Banana Pro images "in the Gemini app, Vertex AI and Google Ads will have C2PA metadata embedded" | SynthID is "designed to stand up to modifications like cropping, adding filters, changing frame rates, or lossy compression" ([DeepMind](https://deepmind.google/models/synthid/)) |
| Adobe Firefly | "Adobe automatically applies Content Credentials for certain types of exports using Firefly outputs, indicating that an AI tool was used" ([Firefly FAQ, snapshot of 11 August 2026](https://web.archive.org/web/20260811160938/https://helpx.adobe.com/firefly/web/get-started/learn-the-basics/adobe-firefly-faq.html); live helpx pages answered 403). The 34 pages of the [Firefly API docs](https://github.com/AdobeDocs/ffs-firefly-api) don't mention it | Not stated |
| Black Forest Labs | "The API for FLUX.2 [klein] applies cryptographically-signed C2PA metadata to downloaded output content to indicate that images were produced with our model" ([FLUX.2 [klein] 4B card](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B)); its API docs ([llms-full.txt](https://docs.bfl.ai/llms-full.txt)) don't mention C2PA | "The inference code for FLUX.2 [klein] implements an example of pixel-layer watermarking" (open weights; same card) |
| Stability AI | "We are implementing content authenticity standards so that users and platforms can identify AI-assisted content generated through our hosted services", referring to C2PA with the Content Authenticity Initiative ([Safety](https://stability.ai/safety)) | Not stated |
| Ideogram | No statement found in the [API terms](https://ideogram.ai/legal/api-tos) or the [API docs index](https://developer.ideogram.ai/v2/llms.txt) | No statement found |
| fal (hosting) | No general statement in its [docs](https://docs.fal.ai/llms-full.txt) | Its pages for Google's Nano Banana models list "SynthID digital watermarking on all outputs" |

### 6.2 Terms about provenance

**Evidence.**

- BFL's Developer Terms define "Content Credentials" as "machine-readable content provenance metadata or digital watermarks embedded in or attached to Outputs pursuant to the C2PA or similar technical standard(s)". Restriction 6(i) bars the developer and its end users from: "Remove, disable, alter, obscure, any Content Credentials or represent to End Users or third parties that (i) Outputs are free of content provenance metadata or (ii) any Task or Output was human-generated".
- BFL's [Usage Policy](https://bfl.ai/legal/usage-policy) (revised 4 August 2026): no one may "circumvent, remove, alter, suppress, or otherwise interfere with any C2PA Credentials, digital watermarks, or other content provenance signals attached to, embedded in, or otherwise associated with Outputs".
- Vertex AI: "Any modification to a C2PA-compliant media file using a non-C2PA tool is considered tampering, resulting in a validation failure."

### 6.3 The EU AI Act's marking rule

**Evidence.**

- Regulation (EU) 2024/1689 ([OJ](https://publications.europa.eu/resource/cellar/dc8116a1-3fe6-11ef-865a-01aa75ed71a1.0006.01/DOC_1)), Art. 50(2): "Providers of AI systems, including general-purpose AI systems, generating synthetic audio, image, video or text content, shall ensure that the outputs of the AI system are marked in a machine-readable format and detectable as artificially generated or manipulated. … This obligation shall not apply to the extent the AI systems perform an assistive function for standard editing or do not substantially alter the input data provided by the deployer or the semantics thereof".
- Art. 50(4): deployers of a system that makes "a deep fake, shall disclose that the content has been artificially generated or manipulated".
- Art. 2(12) leaves free and open-source AI systems out of the Regulation "unless they are placed on the market or put into service as high-risk AI systems or as an AI system that falls under Article 5 or 50". Art. 113: "It shall apply from 2 August 2026."
- The Commission's page says the AI Omnibus "entered into force on 27 July 2026" and the transparency rules came "into effect in August 2026" ([AI Act](https://digital-strategy.ec.europa.eu/en/policies/regulatory-framework-ai)).
- The Commission's [Article 50 guidelines](https://ec.europa.eu/newsroom/dae/redirection/document/131215) (C(2026) 5054, 20 July 2026):
  - "Standard editing should be understood as the process of preparing existing content for publication or distribution (e.g., small edits to improve readability and grammar, quality and format) and does not involve generating new content" (para. 90).
  - "Article 50(2) AI Act does not require that the content is solely AI-generated or manipulated. Content that is mixed with human-created material also qualifies as synthetic content" (section 4.1.1).
  - A company offering "a generative or interactive AI application (e.g. a chatbot, image generator, AI agent) on the Union market under its own name or trademark … is a provider responsible for compliance with the transparency obligations in Article 50(1) and/or (2) AI Act, regardless of whether the AI system is provided for free or for payment".
  - "providers and deployers of open-source AI systems within the scope of Article 50 AI Act still need to ensure compliance" (para. 23).
  - Providers "may rely on the marking solution implemented by an upstream model provider or a third party … to the extent that the marking solution is compliant with Article 50(2) AI Act" (para. 74).
  - The AI Omnibus "envisages a targeted grandfathering rule only with regard to the marking and detection obligations under Article 50(2) AI Act for generative AI systems placed on the market or put into service before 2 August 2026", giving them until 2 December 2026.

### 6.4 C2PA: the digital source type for a composite with AI parts

**Evidence.**

- IPTC's [Digital Source Type](https://cv.iptc.org/newscodes/digitalsourcetype/) vocabulary:
  - `compositeWithTrainedAlgorithmicMedia`, "Edited using Generative AI": "Augmentation, correction or enhancement using a Generative AI model, such as with inpainting or outpainting operations".
  - `compositeSynthetic`, "Composite including generative AI elements": "Mix or composite of several elements, at least one of which is Generative AI".
  - `trainedAlgorithmicMedia`, "Created using Generative AI".
- [C2PA 2.4](https://spec.c2pa.org/specifications/specifications/2.4/specs/C2PA_Specification.html) (April 2026) takes these terms: "An action may include a digitalSourceType key, whose value shall be one of the terms defined by the IPTC". An edited photo starts with `c2pa.opened` and a `parentOf` ingredient. Placing an ingredient is `c2pa.placed`, whose ingredients must have "relationship field is componentOf". An ingredient without its own manifest "may include a digitalSourceType key" (Example 14 is a `componentOf` JPEG marked `trainedAlgorithmicMedia`), but "An ingredient assertion shall not contain both an activeManifest and a digitalSourceType key". Its AI disclosure section pairs `compositeWithTrainedAlgorithmicMedia` with `human_validated`: "AI edits applied and reviewed/approved by a human editor prior to release".

### 6.5 Assessment: a fill composited into a raw edit, then exported

- **The provider's manifest doesn't survive on its own.** A cloud fill returns a PNG, JPEG or WebP carrying the provider's manifest (OpenAI, Vertex, BFL). Redlamp keeps a fill as 16-bit camera RGB in a PNG in the sidecar package ([RR §3.6](../rapidraw-findings.md#36-how-generated-pixels-are-kept)), so the manifest is lost unless Redlamp keeps the provider's original response next to the fill.
- **The export should record the whole chain.** RM-03's export should write:
  - `c2pa.opened`, with the raw (and any camera manifest) as `parentOf`;
  - `c2pa.placed`, with the provider's original file as a `componentOf` ingredient that keeps its `activeManifest`, or, when there is none, an ingredient marked `trainedAlgorithmicMedia`;
  - an edit action with `digitalSourceType` `compositeWithTrainedAlgorithmicMedia` and the fill's region in `changes`;
  - the AI disclosure assertion naming the provider and model.

  This matches D-removal §5 and adds the provider's ingredient.
- **The watermark partly survives.** An invisible watermark (SynthID) stays in the filled pixels after compositing, so detectors may still flag the photo; Redlamp's rendering (develop, re-added grain) may weaken it, which wasn't tested. Redlamp shouldn't try to remove it (BFL's usage policy; OpenAI and Google say nothing similar in the pages read).
- **Exporting without credentials needs a warning.** For BFL fills, an export without Content Credentials arguably "obscure[s]" them (6(i)), and the photographer is BFL's customer under BYOK. Unticking "Include Content Credentials" for a photo with such a fill should warn that the provider's terms require keeping them.
- **The AI Act may make RM-03 a duty.** A service Redlamp runs under its name would make it the provider of a generative AI system, with the marking and detection duty. RM-10's on-device fill (FLUX.2 [klein], on `main` since 6 October 2026, so after the 2 August cut-off) may already do so, since open source doesn't exempt Article 50 systems and generating new content is beyond "standard editing". For BYOK the provider of the generating system is the API provider, and whether Redlamp's feature is a new "AI system" of its own is unclear. Whichever way counsel reads it, RM-03 should land no later than the first cloud fill. Questions for counsel.

---

## 7. Assessment

### 7.1 What each route requires

| | Mac App Store | Direct download (Developer ID, Homebrew) |
| --- | --- | --- |
| **1. BYOK** | No in-app purchase; explicit consent per provider (5.1.2(i)); privacy policy in the app and App Store Connect (5.1.1(i)); App Privacy label (§2.3); sandbox with outgoing connections; keys in the data protection keychain; a temporary key for App Review (2.1) | No Apple payment rules; the same consent, policy and keychain design; a Developer ID provisioning profile for the data protection keychain (§4.2) |
| **2. A provider through Redlamp** (Redlamp sells) | In-app purchase for the subscription or credits, non-expiring credits, restore (3.1.1); the same items in-app if also sold on the web (3.1.3(b)); in the EU, an optional own processor or link on macOS 26.6+; US link-outs UNVERIFIED for the Mac; account deletion (5.1.1(v)), login rule (4.8), demo account (2.1); a larger label (§2.3) | Any billing, for example a merchant of record as RapidRAW does with Lemon Squeezy; tax and consumer law weren't researched |
| **3. ComfyUI** | As BYOK; local-network permission and `NSAllowsLocalNetworking` for a server at home; workflow templates in the bundle (2.4.5(iv)) | As BYOK |

In both channels, route 2 also brings the GDPR's controller duties (§5.3): a privacy policy, processor agreements with each provider and the host, a sub-processor list, records of processing, security and a breach procedure, transfer mechanisms, and possibly an EU representative. It brings BFL's terms passed down to users (no people without consent, no one under 18, Content Credentials kept), probably the AI Act's provider duties (§6.5), and servers, accounts and support to run.

### 7.2 Which route to ship first

**Assessment: BYOK, for generative fill.** It is the only route that adds no payment rules, no accounts, no servers and no controller duties for the crop, and it matches DEC-39's direction. What it needs (consent, a privacy policy, the label, the keychain, Content Credentials) is needed by every route, and the policy and label are needed for the App Store anyway. ComfyUI is as light under these rules and lighter on privacy, since nothing goes to a third party when the server is the photographer's own, but its setup is the friction RapidRAW's issues record ([RR §3.3](../rapidraw-findings.md#33-self-hosted-the-ai-connector-and-comfyui)), so it suits a second step. A Redlamp-sold service is the heaviest: Apple's cut and non-expiring credits in the Mac App Store, the GDPR's controller duties, providers' terms passed down to users, and probably the AI Act's provider duties. It should wait for a separate decision, as DEC-39 says.

Among BYOK providers, the rules favour those whose terms don't train on uploads by default and keep requests briefly: OpenAI's API (no training; 30-day abuse logs), and Google's Gemini API on paid use or in the EEA, Switzerland and the UK. BFL trains unless the user opts out, and its terms on people, minors and Content Credentials need surfacing in the app. INF-11's provider table should record this for each provider.

### 7.3 Consent and disclosure before the first cloud request

**Assessment, as proposed copy.** Shown once per provider, before the first request, with Send and Cancel, and nothing sent until Send:

> **Send this area to Black Forest Labs?**
> Generative Remove will send a crop of this photo, up to 1024 × 1024 pixels around the area you're removing, and its mask to Black Forest Labs, using your API key. The file's name, its metadata and its location aren't sent, and Redlamp doesn't receive or keep anything.
> Black Forest Labs's terms and privacy policy apply to what you send. Its policy says it may use uploaded images to train its models unless you ask it not to. Requests are charged to your Black Forest Labs account.
> The fill will be labelled Generated, with the provider and model, in the edit and in Content Credentials when you export.
> [Black Forest Labs privacy policy] [Redlamp privacy policy]   ☐ Don't ask again for Black Forest Labs   [Cancel] [Send]

- **When Vision finds a person or face in the crop,** add: "This area appears to include a person. Black Forest Labs's terms don't allow images of people without their consent, or of anyone under 18." With a provider whose terms don't say this, the line can be dropped or reworded.
- **Settings › Cloud** lists each provider with its key status ("Stored in the keychain on this Mac"), Remove Key, and the consent ("Allowed since 7 October 2026 · Revoke"). It links Redlamp's privacy policy. AI-Free mode (INF-10) hides it all.
- **Each fill states where it ran.** The Remove tool shows that a fill will go to the provider, and the fill records the provider, model and request time (DEC-39: "the provider named on the fill").
- **Export:** "Include Content Credentials" is preselected for any photo with a generated fill (D-removal §5), and warns when a provider's terms require keeping its credentials.

### 7.4 For the owner or counsel

1. Whether Redlamp is a "provider" under AI Act Art. 50(2) for its on-device fill (RM-10, now) and for BYOK fills, and so whether RM-03 is a legal requirement in the EU rather than a choice.
2. Where Redlamp's operator is established, which decides whether a Redlamp service needs an EU or UK representative (Art. 27).
3. Whether a Mac App Store app on the US storefront may link out to a web purchase. Ask App Review before any route 2 design relies on it.
4. A privacy policy for redlamp.app now, covering Report a Bug, the camera bench and (later) cloud requests, and the App Store label that goes with it.
5. Whether Google's Gemini API terms ("not for consumer use"; "only Paid Services when making API Clients available to users" in the EEA, Switzerland and the UK) allow a BYOK integration for hobbyists.

### 7.5 Not verified

- The Mac App Store's treatment of US link-outs, and whether US apps that link out must also offer in-app purchase (§1.2).
- The remand and the Supreme Court case, both pending. Whether the Latombe judgment has been appealed: the CJEU's InfoCuria didn't render.
- OpenAI's DPA and its help article on C2PA (HTTP 403); Adobe's live help pages (403, so a snapshot of 11 August 2026 was used). EUR-Lex (blocked): the GDPR and the AI Act were read from the Publications Office's copies. The AI Omnibus's final text wasn't read; its Article 50 transition is as the Commission's guidelines describe it.
- That BFL's, OpenAI's and Google's API outputs actually carry the stated credentials and watermarks: checking would need an API key. For Ideogram and fal, no statement was found, which isn't proof that nothing is added. Stability says only that it is "implementing" C2PA.
- The data protection keychain in a Developer ID build without a provisioning profile (TN3137 implies it fails), and how much of a SynthID watermark survives Redlamp's rendering.
- How App Review treats BYOK traffic on the privacy label: Apple's definitions don't address it, and the precedents differ.

---

## 8. Sources (all read 7 October 2026)

**Apple: guidelines, news and terms**
- App Review Guidelines (Last Updated: June 8, 2026): https://developer.apple.com/app-store/review/guidelines/
- Snapshots of the guidelines: https://web.archive.org/web/20251020091829/https://developer.apple.com/app-store/review/guidelines/ (captured 20 October 2025; Last Updated: June 9, 2025) ; https://web.archive.org/web/20250420110308/https://developer.apple.com/app-store/review/guidelines/ (captured 20 April 2025; Last Updated: September 13, 2024)
- Apple Developer news (RSS: https://developer.apple.com/news/rss/news.rss): https://developer.apple.com/news/?id=9txfddzf (1 May 2025) ; https://developer.apple.com/news/?id=r9dcmrvs (9 June 2025) ; https://developer.apple.com/news/?id=awedznci (26 June 2025) ; https://developer.apple.com/news/?id=ey6d8onl (13 November 2025) ; https://developer.apple.com/news/?id=76371du6 (17 December 2025) ; https://developer.apple.com/news/?id=d75yllv4 (6 February 2026) ; https://developer.apple.com/news/?id=a233fmpw (8 June 2026) ; https://developer.apple.com/news/?id=umq9wxmm (18 June 2026) ; https://developer.apple.com/news/?id=gmws0jgp and https://developer.apple.com/news/?id=0cgo95n6 (18 August 2026) ; https://developer.apple.com/news/?id=idsft9ai (16 September 2026)
- StoreKit External Purchase Link Entitlement (US), snapshot of 26 April 2025: https://web.archive.org/web/20250426182828/https://developer.apple.com/support/storekit-external-entitlement-us/ (the live URL redirects to https://developer.apple.com/support/)
- Changes for apps in the EU: https://developer.apple.com/support/apps-in-the-eu/ ; Payment options on the App Store in the EU: https://developer.apple.com/support/payment-options-on-the-app-store-in-the-eu/
- App Privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Privacy manifests: https://developer.apple.com/documentation/bundleresources/privacy-manifest-files ; https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api

**Apple: keychain, sandbox and network** (read as DocC JSON from `https://developer.apple.com/tutorials/data/documentation/…`)
- https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain ; https://developer.apple.com/documentation/security/ksecclassgenericpassword ; https://developer.apple.com/documentation/security/ksecattraccessible ; https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly ; https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlocked ; https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly ; https://developer.apple.com/documentation/security/ksecattrsynchronizable ; https://developer.apple.com/documentation/security/ksecattraccessgroup
- https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility ; https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps ; https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client ; https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox ; https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy ; https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking
- iCloud data security overview: https://support.apple.com/en-us/102651

**Precedents**
- Apple lookup API: https://itunes.apple.com/lookup?id=6445999201,6739738501,6444050820,1435957248,497799835,6474268307&country=us&entity=macSoftware ; Search API queries: `https://itunes.apple.com/search?term=<name>&entity=macSoftware&country=us`
- https://apps.apple.com/us/app/opencat-ai-chat-agent-mcp/id6445999201 ; https://apps.apple.com/us/app/reins-for-ollama-lm-studio/id6739738501 ; https://apps.apple.com/us/app/draw-things-offline-ai-art/id6444050820 ; https://apps.apple.com/us/app/drafts/id1435957248 (HTTP 429; details from the lookup API) ; https://apps.apple.com/us/app/xcode/id497799835 (lookup API)
- Drafts scripting reference: https://scripting.getdrafts.com/classes/OpenAI ; https://scripting.getdrafts.com/classes/AnthropicAI ; https://scripting.getdrafts.com/classes/GoogleAI
- Xcode coding intelligence: https://developer.apple.com/documentation/xcode/setting-up-coding-intelligence

**Epic v. Apple**
- Order of 30 April 2025, Dkt. 1508: https://storage.courtlistener.com/recap/gov.uscourts.cand.364265/gov.uscourts.cand.364265.1508.0_4.pdf
- Ninth Circuit opinion, No. 25-2935, 11 December 2025: https://cdn.ca9.uscourts.gov/datastore/opinions/2025/12/11/25-2935.pdf
- Apple's remand proffer, Dkt. 1708, 13 August 2026: https://storage.courtlistener.com/recap/gov.uscourts.cand.364265/gov.uscourts.cand.364265.1708.0.pdf
- Docket entries (CourtListener search API, docket 17442392): https://www.courtlistener.com/api/rest/v4/search/?q=docket_id%3A17442392&type=rd&order_by=entry_date_filed%20desc

**Privacy law**
- GDPR, Regulation (EU) 2016/679, OJ L 119, 4.5.2016 (Publications Office): https://publications.europa.eu/resource/cellar/3e485e15-11bd-11e6-ba9a-01aa75ed71a1.0006.01/DOC_1 (EUR-Lex returned an empty bot-check response)
- EDPB Guidelines 07/2020 on the concepts of controller and processor, version 2.1: https://www.edpb.europa.eu/system/files/2023-10/EDPB_guidelines_202007_controllerprocessor_final_en.pdf
- UK GDPR, Article 4: https://www.legislation.gov.uk/eur/2016/679/article/4
- EU-US data transfers (Commission): https://commission.europa.eu/law/law-topic/data-protection/international-dimension-data-protection/eu-us-data-transfers_en ; General Court press release 106/25 (T-553/23 Latombe): https://curia.europa.eu/jcms/upload/docs/application/pdf/2025-09/cp250106en.pdf ; InfoCuria listing (not rendered): https://curia.europa.eu/juris/liste.jsf?num=T-553/23&language=en
- UK-US data bridge: https://www.gov.uk/government/publications/uk-us-data-bridge-supporting-documents ; https://www.gov.uk/government/publications/uk-us-data-bridge-supporting-documents/uk-us-data-bridge-explainer

**AI Act**
- Regulation (EU) 2024/1689, OJ (Publications Office): https://publications.europa.eu/resource/cellar/dc8116a1-3fe6-11ef-865a-01aa75ed71a1.0006.01/DOC_1
- Commission: https://digital-strategy.ec.europa.eu/en/policies/regulatory-framework-ai ; https://digital-strategy.ec.europa.eu/en/policies/code-practice-ai-generated-content ; https://digital-strategy.ec.europa.eu/en/policies/guidelines-transparency-ai-generated-content ; https://digital-strategy.ec.europa.eu/en/library/guidelines-transparency-obligations-providers-and-deployers-ai-systems ; guidelines, C(2026) 5054: https://ec.europa.eu/newsroom/dae/redirection/document/131215

**Providers: terms and provenance**
- OpenAI: https://platform.openai.com/docs/guides/content-provenance ; https://platform.openai.com/docs/guides/your-data ; https://platform.openai.com/docs/guides/image-generation ; https://help.openai.com/en/articles/8912793-c2pa-in-chatgpt-images (HTTP 403) ; https://openai.com/policies/data-processing-addendum/ (HTTP 403)
- Google: https://ai.google.dev/gemini-api/docs/image-generation ; https://ai.google.dev/gemini-api/terms ; https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/content-credentials ; https://blog.google/innovation-and-ai/products/ai-image-verification-gemini-app/ (published 20 November 2025) ; https://deepmind.google/models/synthid/
- Adobe: https://web.archive.org/web/20260811160938/https://helpx.adobe.com/firefly/web/get-started/learn-the-basics/adobe-firefly-faq.html (captured 11 August 2026) ; https://github.com/AdobeDocs/ffs-firefly-api (34 Markdown pages) ; live https://helpx.adobe.com/firefly/… pages (HTTP 403)
- Black Forest Labs: https://huggingface.co/black-forest-labs/FLUX.2-klein-4B (README) ; https://bfl.ai/legal/developer-terms-of-service ; https://bfl.ai/legal/eu-developer-terms-of-service ; https://bfl.ai/legal/usage-policy ; https://bfl.ai/legal/privacy-policy ; https://docs.bfl.ai/llms-full.txt
- Stability AI: https://stability.ai/safety
- Ideogram: https://ideogram.ai/legal/api-tos ; https://developer.ideogram.ai/v2/llms.txt (and the API reference pages it lists)
- fal: https://docs.fal.ai/llms-full.txt ; https://fal.ai/terms ; https://fal.ai/privacy
- C2PA Technical Specification 2.4: https://spec.c2pa.org/specifications/specifications/2.4/specs/C2PA_Specification.html ; IPTC Digital Source Type: https://cv.iptc.org/newscodes/digitalsourcetype/

**Redlamp**
- https://redlamp.app/ (home page and footer) ; https://redlamp.app/sitemap.xml ; https://redlamp.app/privacy, /privacy-policy, /legal, /terms, /about, /.well-known/security.txt (all HTTP 404)
- Repository: `README.md` (Known limitations: the app isn't sandboxed yet; "photos are never uploaded"), `packages/RedlampUI/Sources/Settings/SettingsView.swift` (the support link's comment), `web/lib/feedback.ts` (Report a Bug's attachments), `apps/RedlampMac/DecoderService/RedlampDecoder.entitlements`, `docs/research/research-tracker.md` (DEC-39, INF-11, RM-03, RM-10, RM-17), `docs/research/rapidraw-findings.md`, `docs/research/notes/D-removal.md`
