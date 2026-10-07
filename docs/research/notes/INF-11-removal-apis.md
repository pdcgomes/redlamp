# Cloud APIs for mask-based object removal (INF-11)

Which cloud APIs can fill a Generative Remove spot the way `GenerativeFiller` asks (a square sRGB crop of at most 1024 × 1024 pixels, a mask where 1 repaints, a seed, and no free-text prompt), what each costs, what its terms allow, and which to integrate first. Researched on 7 October 2026 for INF-11, the study behind DEC-39. Every source was read on that date from the provider's own documentation, OpenAPI schema, pricing page or terms; two OpenAI help pages came through the Internet Archive, and Adobe's API schema from its documentation repository on GitHub. No account was created and no API was called, so nothing here measures quality, latency or determinism on Redlamp's samples. This is an engineering survey, not legal advice.

**What a cloud filler would send.** None of the erasers below takes a reference image or a named prompt, so a cloud `GenerativeFiller` would send the crop and the mask (the spot grown by 8 pixels), plus the seed where the API accepts one. Redlamp's `reference` and `prompt` would go unused.

**Verdicts**

- **Candidate**: removes what the mask covers with no prompt, an individual can get a key alone, and the terms can be explained in a consent sheet.
- **Test**: fits technically, but quality, price or terms need checking before it is offered.
- **Not a fit**: needs a prompt that names the object, takes no mask, is open only to businesses, or is discontinued.

## Comparison

Prices are for one call on a 1024 × 1024 crop (one megapixel). Generative Remove makes three fills from three seeds, so a spot costs three calls.

| Provider and model | Without a prompt | Inputs and mask | Seed | Call style and output | Price per crop | Getting a key | Training and retention | Marks on output | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| [BFL FLUX Erase](https://docs.bfl.ml/flux_tools/flux_erase.md), direct (FLUX.2 [klein] 9B) | Yes: "the server applies a fixed erase instruction" | Base64 or URL; mask the same size, white removes; dilation 0–25 px; trained at about 1 MP; no maximum stated | Yes | Queued: poll or webhook; PNG (default), JPEG, WebP; result URL lives 10 minutes; EU-only and US-only hosts | $0.03 | Self-serve, card through Stripe | Licence to train on inputs and outputs; opt-out by email; zero retention for enterprise | Terms forbid removing Content Credentials; whether outputs carry them isn't documented | **Candidate**, with terms caveats |
| [BFL FLUX.1 Fill [pro]](https://docs.bfl.ml/flux_1_fill.md), direct | Prompt optional (empty by default), documented as text-driven | Base64; mask or alpha, white repaints | Yes | Queued; JPEG (default), PNG, WebP | $0.05 | As above | As above | As above | Not a first choice |
| BFL FLUX.2, FLUX 3 Image, FLUX.1 Kontext, direct | No: prompt required, no mask | Reference images (FLUX 3 can target an edit with bounding boxes) | FLUX.2 and Kontext only | Queued | From $0.014 | As above | As above | As above | Not a fit |
| [fal: FLUX Erase](https://fal.ai/models/fal-ai/flux-pro/v1/erase/llms.txt) | Yes | URL or data URI; white removes; dilation 0–100 px | Not an input | Synchronous or queued; JPEG (default), PNG | $0.03, plus a stated $0.004 per "reference megapixel" (3 MP minimum) | Self-serve, prepaid credits | fal: no training for partner APIs it marks ready; JSON kept 30 days unless opted out; crop passes to BFL | fal signs outputs with C2PA and an invisible watermark | **Candidate** (aggregator) |
| [fal: Bria Eraser](https://fal.ai/models/fal-ai/bria/eraser/llms.txt) | Yes | URL or data URI; manual or automatic mask | No | Synchronous or queued | $0.04 | As above | As above; crop passes to Bria | As above | **Candidate** (aggregator) |
| [fal: Ideogram Object Removal](https://fal.ai/models/fal-ai/ideogram/object-removal/llms.txt) | Yes ("Prompt-free") | Image and mask up to 10 MB each; white removes | No | Synchronous or queued | $0.03 | As above | As above; crop passes to Ideogram | As above | Test |
| [fal: Finegrain Eraser](https://fal.ai/models/fal-ai/finegrain-eraser/mask/llms.txt) | Yes | White erases; three quality modes | Yes (0–999) | Synchronous or queued | $0.04, $0.13 or $0.22 by mode | As above | Marked "pending": fal's no-training clause and DPA don't apply | As above | Not a fit for now |
| [fal: Object Removal](https://fal.ai/models/fal-ai/object-removal/mask/llms.txt) (run by fal) | Yes | White removes; expansion 0–50 px | No | Synchronous or queued | $0.006–$0.024 by quality | As above | fal's terms; model and training data not disclosed | As above | Test |
| fal: FLUX.1 [pro] Fill, Qwen-Image-Edit inpaint | No: `prompt` required | Image and mask | Yes | Synchronous or queued | $0.05 or $0.03 per MP | As above | As above | As above | Not a fit |
| [Replicate: Bria Eraser](https://replicate.com/bria/eraser/llms.txt) | Yes | File or URL | No | Queued, or held open up to 60 s | $0.04 | GitHub sign-in only | API data deleted after an hour; licence limited to running the service and compiling usage data | Not stated | Test |
| Replicate: FLUX.1 Fill [pro], Ideogram v3, Qwen-Image-Edit | No: prompt required (Ideogram's mask is inverted) | | Yes | As above | $0.05 (Fill), $0.03–$0.09 (Ideogram) | As above | As above | Not stated | Not a fit |
| [Bria Eraser](https://docs.bria.ai/image-editing/editing/erase.md), direct | Yes | Base64 or URL; JPEG, PNG, WebP; white erases; no maximum stated | No | Queued, or `sync: true`; at the input's resolution, pixels outside the mask unchanged | $0.02 | Self-serve; 100 free calls, no card | Warranty of no training on customer content; inputs not kept after processing; results hosted 3 days | C2PA and an invisible watermark; terms forbid stripping them | **Candidate** |
| [Ideogram Remove an object](https://developer.ideogram.ai/api-reference/images/remove-object/ideogram-1.md), direct | Yes | Multipart; up to 50 MB; white (128 or more) removes | Yes | Queued: poll or webhook; URL expires | Not readable (UNVERIFIED) | Self-serve, prepaid | Ideogram may "use in any manner all User data" sent through the API | Not stated | Not a fit directly |
| [Stability AI Erase](https://api.stability.ai/v2alpha/openapi) | Yes | Multipart; up to 9,437,184 px; grey mask sets strength; growth 0–20 px | Yes | Synchronous; image in the response; PNG (default), JPEG, WebP | $0.05 (5 credits) | Self-serve; 25 free credits | May train on inputs and outputs unless the account turns it off | C2PA on all API output; terms forbid removing marks | Test |
| Stability AI Inpaint | No: prompt required | | Yes | Synchronous | $0.05 | As above | As above | As above | Not a fit |
| [Clipdrop Cleanup](https://clipdrop.co/apis/docs/cleanup) (Jasper) | Yes | JPEG or PNG up to 16 MP; mask 0 or 255 | No | Synchronous; PNG, same size | 1 credit; credits through Jasper | 100 free credits; the Jasper API needs a Business plan | Not reviewed | Not stated | Not a fit |
| [OpenAI GPT Image 2.5](https://developers.openai.com/api/docs/guides/image-generation.md) edits | No: prompt required; the mask is "entirely prompt-based" | Mask as PNG alpha; 655,360–8,294,400 px | None documented | Synchronous, "up to 2 minutes"; PNG, JPEG, WebP | Token-priced; per-image cost not verified | Self-serve; may need ID verification | Not used for training; abuse logs 30 days | C2PA and SynthID | Not a fit |
| [Google Gemini image models](https://ai.google.dev/gemini-api/docs/image-generation) | No: no mask parameter; edits described in words | Images and text | None documented | Synchronous; 0.5K to 4K tiers | $0.0336–$0.134 | Self-serve with Cloud Billing; no free tier for image models | Paid use not used for training; logged for abuse | SynthID on every image | Not a fit |
| [Vertex AI Imagen inpainting removal](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/image/edit-remove-objects) | Removal mode existed | | | | | | | | Not a fit: discontinued |
| [Adobe Firefly Fill](https://raw.githubusercontent.com/AdobeDocs/ffs-firefly-api/main/static/firefly-api.json) | Prompt optional | Upload or pre-signed URL on listed domains; white edits | Seed images | Queued; fixed sizes including 1024 × 1024 | Not public | Enterprise organisations only | Not reviewed | Not reviewed | Not a fit |
| [Photoroom Edit With AI](https://docs.photoroom.com/image-editing-api-plus-plan/edit-with-ai.md) | No: prompt, no mask | | | 1K by default | $0.10 | Plus plan | Not reviewed | Not reviewed | Not a fit |
| [Picsart Remove Object](https://docs.picsart.io/reference/genai-remove-object.md) | Yes | File or URL | No | Synchronous or queued; JPEG (default), PNG, WebP | Not verified | Self-serve; 5 free credits | Not verified; result URLs live 24 h | Not stated | Test |
| [Recraft Erase region](https://www.recraft.ai/docs/api-reference/tools/erase-region.md) | Yes | Up to 16 MP and 20 MB; sides 256–4096 px; pure black-and-white mask | No | Synchronous; lossless WebP (default) or PNG | $0.002 | Self-serve, prepaid units | "API inputs and outputs are never used for model training"; files kept about 24 h | Not stated | Test |
| [Amazon Bedrock: Stability Erase](https://docs.aws.amazon.com/bedrock/latest/userguide/stable-image-services.html) | Yes | Base64; up to 9,437,184 px | Not verified | Synchronous | Not verified | AWS account with IAM or a Bedrock API key | Model providers can't see prompts or outputs | Not verified | Not a fit yet |
| [Hugging Face Inference Providers](https://huggingface.co/docs/inference-providers/tasks/image-to-image.md) | n/a | The image-to-image task has no mask field | | | Provider's price, no markup | Free users buy credits | No request or response bodies stored | | Not a route for masks |

## The providers

### Black Forest Labs (direct API)

**Evidence:**

- **FLUX Erase** launched on 21 May 2026 as "clean, prompt-free object removal" ([release notes](https://docs.bfl.ml/release-notes.md)), "powered by FLUX.2 Klein 9B" ([docs](https://docs.bfl.ml/flux_tools/flux_erase.md)). `POST https://api.bfl.ai/v1/flux-tools/erase-v1` takes a base64 or URL `image` and a `mask` of the same size, "White (255) = remove, black (0) = keep", and "No prompt is sent by the caller — the server applies a fixed erase instruction internally". The schema adds `dilate_pixels` (0–25, default 10), `seed` ("Optional seed for reproducibility"), `safety_tolerance` (0–5, default 2), `output_format` (`jpeg`, `png`, `webp`; `png` by default) and `webhook_url` ([OpenAPI](https://api.bfl.ai/openapi.json), [reference](https://docs.bfl.ml/api-reference/models/erase-an-object-from-an-image.md)).
- **Size.** "The model was trained on images at ~1 megapixel across 9 aspect ratios from 1:2 to 2:1"; no maximum is stated. The file names of the three examples in the docs read 1200 × 1600 in and 1206 × 1600 out, 1199 × 1600 in and 1211 × 1600 out, and 1600 × 1397 in and 1600 × 1389 out, which suggests the output can differ from the input by a few pixels (inferred from file names; UNVERIFIED as API behaviour).
- **Call style.** The POST returns an `id` and a `polling_url`; the poll ends in `Ready`, `Error`, `Request Moderated` or `Content Moderated`, or a webhook delivers the result. "Signed delivery URLs are only valid for 10 minutes." `api.bfl.ai` routes "across all available clusters globally", `api.eu.bfl.ai` keeps "Multi-cluster routing limited to EU regions" and `api.us.bfl.ai` keeps it to the US ([integration guide](https://docs.bfl.ml/api_integration/integration_guidelines.md)). Plain HTTPS with an `x-key` header. No latency figure is published; the announcement says it matches other models "at a fraction of the price and latency" ([blog](https://bfl.ai/blog/flux-erase-remove-anything-leave-no-trace)).
- **Price.** $0.03 for the first megapixel and $0.004 for each further megapixel ([pricing page, structured data](https://bfl.ai/pricing)). One credit is $0.01, and "All credit purchases are non-refundable" ([pricing docs](https://docs.bfl.ml/quick_start/pricing.md), [API Service Terms §3](https://bfl.ai/legal/flux-api-service-terms)).
- **Quality evidence is the vendor's own.** On "198 mask-based object-removal test images", FLUX Erase "wins decisively against GPT Image-2 (68.5%) and Finegrain Eraser Standard (63.2%), ties Nano Banana 2 (49.5%), and lands closely behind Nano Banana Pro (47.3%)" ([blog](https://bfl.ai/blog/flux-erase-remove-anything-leave-no-trace)).
- **Key.** Register at dashboard.bfl.ai, confirm the email, add credits by card ("We accept all major credit cards through Stripe") and create a key in a project ([quick start](https://docs.bfl.ml/quick_start/get_started.md), [billing](https://docs.bfl.ml/account_management/credits_billing.md)).
- **Training.** "Developer grants the Company a fully paid, royalty-free, perpetual, irrevocable, worldwide, non-exclusive, and fully sublicensable right and license to use ... Developer's Input and Output for the purpose of operating the FLUX Services, improving the Company's products and services, and developing new products and services. Developer acknowledges that the foregoing means the Company may use Inputs and Outputs to train and improve its artificial intelligence models" ([API Service Terms §2b](https://bfl.ai/legal/flux-api-service-terms), revised 4 August 2026; the same in the [EU API Service Terms](https://bfl.ai/legal/eu-api-service-terms), revised 26 August 2026). The privacy policy offers an opt-out: email privacy@blackforestlabs.ai with the subject "Training Opt Out" ([privacy policy](https://bfl.ai/legal/privacy-policy)). Enterprise customers get "Zero data retention" ([enterprise](https://bfl.ai/enterprise)).
- **Restrictions.** Under §6 of the [Developer Terms](https://bfl.ai/legal/developer-terms-of-service) and the [EU Developer Terms](https://bfl.ai/legal/eu-developer-terms-of-service), you will not "(i) Remove, disable, alter, obscure, any Content Credentials or represent ... that (i) Outputs are free of content provenance metadata", "(j) Upload images of individuals to the FLUX Services or FLUX AI Models without their consent", or "(k) Upload images, videos or personal data ... relating to individuals under the age of 18". §3a adds that if you upload "a photograph ... or likeness of any person", you warrant you have "any and all required permissions or consents".
- **Output.** "As between you and us, you own all right, title, and interest in and to Output", usable "for your or their own personal or commercial purposes" (Developer Terms §3b, §4b). The terms define Content Credentials as C2PA metadata or watermarks, but neither the docs nor the terms say whether API outputs carry them (UNVERIFIED).
- **Other models.** FLUX.1 Fill [pro] (`/v1/flux-pro-1.0-fill`) has `prompt` defaulting to `""`, so it runs without one, but BFL describes it as "text-driven inpainting"; it defaults to 50 steps, guidance 60 and JPEG output, at $0.05 an image ([OpenAPI](https://api.bfl.ai/openapi.json), [Fill](https://docs.bfl.ml/flux_1_fill.md)). FLUX.2 [pro], [flex], [max] and [klein], FLUX 3 Image and FLUX.1 Kontext all require a prompt and take no mask; BFL's removal guide prompts by naming the object, as in "Remove the Women on the Bike" ([guide](https://docs.bfl.ml/guides/usecases_editing_object_removal.md)).

**Assessment:** FLUX Erase fits `GenerativeFiller` closely: no prompt, a seed, a dilation like Redlamp's own 8-pixel growth, an EU host and one megapixel for $0.03. Its terms are the obstacle: by default BFL may train on every crop, and the consent and under-18 clauses sit badly with removing strangers, or children, from photographs.

### fal

**Evidence:**

- **Catalogue.** fal's model search ([API](https://fal.ai/api/models?keywords=eraser)) lists these prompt-free, mask-based erasers: `fal-ai/flux-pro/v1/erase` (BFL's FLUX Erase, from 21 May 2026), `fal-ai/bria/eraser`, `fal-ai/ideogram/object-removal` (from 29 July 2026), `fal-ai/finegrain-eraser/mask` and fal's own `fal-ai/object-removal/mask`. It also lists prompted inpainters, of which I read two: `fal-ai/flux-pro/v1/fill`, where `prompt` is required ($0.05 per megapixel, "billed by rounding up to the nearest megapixel"), and `fal-ai/qwen-image-edit/inpaint`, where it is too ($0.03 per megapixel) ([Fill](https://fal.ai/models/fal-ai/flux-pro/v1/fill/llms.txt), [Qwen](https://fal.ai/models/fal-ai/qwen-image-edit/inpaint/llms.txt)). Inpainting endpoints for FLUX.1 Kontext [dev], Z-Image Turbo, FLUX.1 [dev] and SDXL, and prompt-only editors such as Nano Banana and GPT Image, were not read.
- **Schemas and prices** (each model's `llms.txt`): FLUX Erase takes `image_url`, `mask_url` ("white (255) marks pixels to erase"), `dilate_pixels` (0–100, default 10), `sync_mode` and `output_format` (`jpeg` by default, or `png`), with no seed input; it costs "$0.03 for the first megapixel generated, then $0.004 for each subsequent megapixel. Each reference megapixel also costs $0.004 set at 3 MP minimum" ([FLUX Erase](https://fal.ai/models/fal-ai/flux-pro/v1/erase/llms.txt)). Bria Eraser takes `mask_type` (`manual` or `automatic`) and `preserve_alpha`, $0.04 a call ([Bria](https://fal.ai/models/fal-ai/bria/eraser/llms.txt)). Ideogram Object Removal is "Prompt-free object removal from an image and mask", up to 10 MB a file, $0.03 ([Ideogram](https://fal.ai/models/fal-ai/ideogram/object-removal/llms.txt)). Finegrain's mask eraser takes `seed` (0–999) and costs "$0.04 with Express, $0.13 with Standard, and $0.22 with Premium" ([Finegrain](https://fal.ai/models/fal-ai/finegrain-eraser/mask/llms.txt)). fal's Object Removal takes `mask_expansion` (0–50, default 15) and four quality levels from $0.006 to $0.024; its model is not named ([Object Removal](https://fal.ai/models/fal-ai/object-removal/mask/llms.txt)).
- **Who runs them.** Each model page's data labels FLUX Erase, Bria Eraser and Ideogram Object Removal `"is_partner_api":true` with `"enterprise_status":"ready"`, Finegrain's eraser `"enterprise_status":"pending"`, and Object Removal `"provider_type":"fal"` ([FLUX Erase](https://fal.ai/models/fal-ai/flux-pro/v1/erase), [Bria](https://fal.ai/models/fal-ai/bria/eraser), [Ideogram](https://fal.ai/models/fal-ai/ideogram/object-removal), [Finegrain](https://fal.ai/models/fal-ai/finegrain-eraser/mask), [Object Removal](https://fal.ai/models/fal-ai/object-removal/mask)).
- **Training.** The [API Services Terms](https://fal.ai/legal/api-services): "If Client uses any third-party AI model via the Company Platform through a third party's API, Client acknowledges that Client Content will be transferred to such a third party" (§2.3); "Company will not use Client Content to create, train, develop (directly or indirectly) Company's products or services. This restriction applies to all third-party APIs, except for APIs marked as 'Pending Enterprise Ready' ... In addition, Company's information security and other obligations (such as the DPA) will not apply to Excluded Models" (§2.4). The [Terms of Service](https://fal.ai/legal/terms-of-service) (8 September 2026) license Customer Input only "to provide the Services", but let fal use "Usage Data", defined as "anonymized or aggregated data ... which may include data based on or derived from Customer Input", to "design, develop, and offer Company products, services, and AI models". I found no clause assigning ownership of outputs; the customer owns its inputs.
- **Retention.** Request JSON is stored "for **30 days** by default"; the `X-Fal-Store-IO: 0` header prevents it; generated media on fal's CDN keep a configurable lifetime set by `X-Fal-Object-Lifecycle-Preference`, and payloads can be deleted through the Platform API ([data retention](https://fal.ai/docs/documentation/model-apis/media-expiration.md)). CDN files are "Public by default -- anyone with the URL can download" unless an ACL is set; models accept data URIs as inputs ([CDN](https://fal.ai/docs/documentation/model-apis/fal-cdn.md)). With `sync_mode`, "the media will be returned as a data URI and the output data won't be available in the request history".
- **Provenance.** "Every piece of media generated through fal's hosted applications is signed with Content Credentials (C2PA) — an open, industry-standard cryptographic signature — and embedded with an invisible watermark" ([verify](https://fal.ai/verify)). I found no clause against removing them in fal's [acceptable use policy](https://fal.ai/legal/acceptable-use-policy) or terms.
- **Location.** "fal is based in the United States and we and our service providers process and store personal information on servers located in the United States and other countries" ([privacy policy](https://fal.ai/legal/privacy-policy)).
- **Call style.** `fal.run` answers in the same HTTP connection; `queue.fal.run` queues, with polling or webhooks; both plain HTTPS with `Authorization: Key …` ([inference](https://fal.ai/docs/documentation/model-apis/inference/synchronous.md), [overview](https://fal.ai/docs/documentation/model-apis/overview.md)). No latency figures are published on the erasers' pages.
- **Key.** Create an API-scope key in the dashboard ([authentication](https://fal.ai/docs/documentation/model-apis/authentication.md)); "Model API billing is per output, priced per model, drawn from prepaid credits" ([llms.txt](https://fal.ai/llms.txt)). I found no free credits (UNVERIFIED).
- **If Redlamp held the key.** "Client will not expose any of the Services APIs directly to any End Users" (API Services Terms §2.1), and §2.5 requires end-user agreements.

**Assessment:** fal is the aggregator to use. It offers the three prompt-free erasers worth testing behind one key, and for FLUX Erase its terms are better than BFL's own: no training, a DPA, and per-request controls on storage. Offer only models fal marks enterprise-ready, and send `X-Fal-Store-IO: 0` with `sync_mode`. Because a Redlamp-held key couldn't sit in the app, the route that fits DEC-39 (no Redlamp servers) is still the photographer's own fal key.

### Replicate

**Evidence:**

- **Models.** Bria Eraser takes `image` and `mask` (file or URL), `sync`, `content_moderation` and `preserve_alpha`, with no seed, at $0.04 per output image ([llms.txt](https://replicate.com/bria/eraser/llms.txt), [page data](https://replicate.com/bria/eraser)). FLUX.1 Fill [pro] requires `prompt`, $0.05 per output image ([Fill](https://replicate.com/black-forest-labs/flux-fill-pro/llms.txt)). Ideogram v3 inpaints with a required prompt and a mask in which "Black pixels are inpainted, white pixels are preserved", at $0.03 (Turbo), $0.06 or $0.09 an image ([Ideogram](https://replicate.com/ideogram-ai/ideogram-v3-turbo/llms.txt)). Qwen-Image-Edit is prompt-based ([Qwen](https://replicate.com/qwen/qwen-image-edit)). Black Forest Labs' model list on Replicate has no FLUX Erase ([BFL](https://replicate.com/black-forest-labs), [image editing collection](https://replicate.com/collections/image-editing)).
- **Call style.** Asynchronous by default; `Prefer: wait` holds the request "for a specified duration, which defaults to 60 seconds" ([predictions](https://replicate.com/docs/topics/predictions/create-a-prediction.md)). Files go as URLs, uploads or data URIs, the last "only recommended if the file is less than 1MB" ([input files](https://replicate.com/docs/topics/predictions/input-files.md)).
- **Retention.** "For predictions created through the API, all input parameters, output values, output files, and logs are automatically removed after an hour, by default" ([data retention](https://replicate.com/docs/topics/predictions/data-retention.md)).
- **Terms** (1 April 2026). The customer owns Customer Data, inputs and outputs, and may use Output "for commercial purposes ... subject to any Third Party Terms"; Replicate's licence covers use "to the extent necessary to provide the Output, train and generate Customer Derivative Models, provide the Services ... and create and compile Resultant Data" (§5.1, §5.2). The Additional Terms flow down BFL's Flux API agreement and terms of service, and Ideogram's restrictions, including no "uploading images of individuals via the Ideogram AI Model without their consent" ([terms](https://replicate.com/terms)).
- **Key.** The sign-in page offers only "Sign in with GitHub" ([sign in](https://replicate.com/signin)); billing is prepaid credit or invoiced usage ([billing](https://replicate.com/docs/topics/billing.md)). Replicate announced on 17 November 2025 that it is joining Cloudflare ([blog](https://replicate.com/blog)).

**Assessment:** weaker than fal here. Of the prompt-free erasers it has only Bria's, at twice Bria's own price, and a photographer needs a GitHub account. Its one-hour deletion by default is a strength.

### Bria AI

**Evidence:**

- **Eraser.** `POST https://engine.prod.bria-api.com/v2/image/edit/erase` takes `image` and `mask` as base64 (without a `data:` prefix) or a public URL, in JPEG, PNG or WebP; the area to erase "must have a pixel value of **255 (white)**" and the mask "the **same aspect ratio** as the input". Options: `mask_type` (`manual` or `automatic`), `preserve_alpha`, `sync`, `webhook_url`, and opt-in input and output moderation. "The modified image is returned at the original resolution", and "All areas outside the provided mask remain completely unchanged" ([Eraser](https://docs.bria.ai/image-editing/editing/erase.md), [images](https://docs.bria.ai/getting-started/working-with-images.md)). No seed, no prompt and no maximum size are documented.
- **Call style.** Asynchronous by default with a `status_url` or webhook; `sync: true` holds the connection until the image URL is ready ([docs index](https://docs.bria.ai/llms.txt)). Plain HTTPS with an `api_token` header.
- **Price and key.** Eraser costs $0.02 an image. The free plan gives "100 free generations" with "No credit card needed" at 10 requests a minute; pay-as-you-go allows 60 ([pricing](https://bria.ai/pricing), [rate limits](https://docs.bria.ai/getting-started/rate-limits-and-errors.md), [quick start](https://docs.bria.ai/getting-started/quickstart.md)).
- **Retention.** Results are hosted at temporary URLs ("Images expire after 3 days"); "Inputs you send ... are not retained beyond what's needed to process the request" ([asset retention](https://docs.bria.ai/getting-started/asset-retention.md)).
- **Training and rights.** Bria's models are "trained on **100% licensed data**" ([safety](https://docs.bria.ai/safety.md)). The [Online General Terms](https://drive.google.com/file/d/1WaqnqpRdfPqtJIwUnWS6kAl0UnrLUFLz/view) (V1.4, September 2026), which cover the free and self-serve plans ([legal lobby](https://bria.ai/legal-lobby)), say: "Bria hereby warrants that Customer Content shall not be used to train generative models, unless Customer expressly consents to such training in writing" (§2.2); Bria assigns the customer "all its right, title and interest, if any, in and to any Output" (§2.1); "Bria warrants and represents the Output do not ... infringe a patent, copyright, trademark, or other proprietary right of a third party, or any right of privacy or publicity" (§4.1); liability is capped at the greater of the year's fees or US$100 (§5.3). The pricing page lists "Capped standard indemnification" for pay-as-you-go and "Unlimited IP indemnification" for Enterprise; the docs say full copyright indemnity is "for enterprise customers only" ([safety](https://docs.bria.ai/safety.md)).
- **Provenance.** Outputs carry "a C2PA manifest and an invisible watermark" ([trust and provenance](https://docs.bria.ai/trust-and-provenance-overview.md)). The Online terms §2.8: "Customer will ensure that any Output ... is marked as 'AI Generated' using such standards and/or watermarking techniques ... and shall not strip any Output of any Product from any marking applied by Bria."
- **Location.** Not stated in the privacy policy or on the security page (UNVERIFIED) ([privacy](https://bria.ai/privacy-policy), [security](https://bria.ai/security-and-compliance)).

**Assessment:** Bria's self-serve terms are the only ones here that combine a no-training warranty, licensed training data and an IP warranty, and an individual can try it without a card. Its unknowns are quality on holes as large as a parked car, and whether three calls on the same spot give three different fills, since it takes no seed. Its marking clause means Redlamp must carry the fill's provenance forward rather than drop it.

### Ideogram (direct API)

**Evidence:**

- `POST https://api.ideogram.ai/v2/image/remove-object/ideogram-1` takes a multipart `image` and `mask` (JPEG, PNG or WebP, up to 50 MB each; "white (>= 128) marks the region to remove") and an optional `seed`, and returns a `generation_id` to poll at `GET /v2/generations/{generation_id}` or deliver by webhook; `dry_run=true` returns a price quote ([Remove an object](https://developer.ideogram.ai/api-reference/images/remove-object/ideogram-1.md), [poll](https://developer.ideogram.ai/api-reference/generations/get-generation.md)). A result whose `is_image_safe` is false comes back with no URL, and `failure_reason` can be `content_policy_violation`.
- **Key.** A free Ideogram account, a card through Stripe and prepaid credits from $1 to $300; "every key has full access to your API account" ([setup](https://developer.ideogram.ai/ideogram-api/api-setup.md)). The API price list loads behind a Cloudflare challenge, so the direct price is UNVERIFIED; fal charges $0.03.
- **Terms.** The [Developer API Agreement](https://ideogram.ai/legal/api-tos) (revised 14 August 2024): "Ideogram has the right to use in any manner all User data received by the Company via the Ideogram API" (§4.3); a Developer must "identify ... that any User Output ... was created by the Ideogram AI Model (e.g., via a 'Powered by Ideogram' tagline), and ... display the Company's Marks ... on each page" where the model is offered (§2.3.1); prohibited content includes "uploading images of individuals via the Ideogram AI Model without their consent" (§2.3.6(B)). I found no clause on who owns outputs (UNVERIFIED).

**Assessment:** the endpoint fits, but used directly it lets Ideogram use whatever the API receives "in any manner", and its branding duty falls on whoever holds the key. Through fal, fal's no-training commitment applies; test it there.

### Stability AI

**Evidence:**

- **Erase.** `POST https://api.stability.ai/v2beta/stable-image/edit/erase` takes a multipart `image` (JPEG, PNG or WebP; every side at least 64 px; 4,096 to 9,437,184 pixels), an optional `mask` (or the image's alpha) whose grey levels set "the strength of inpainting", `grow_mask` (0–20, default 5), `seed` and `output_format` (`png` by default). The description says the body "must include: `image`" only; the schema's `required` list also names `prompt`, which the schema doesn't define, and looks copied from Inpaint. It answers synchronously with the image, or base64 JSON. It also says "The resolution of the generated image will be 4 megapixels", which is unclear for an erase (UNVERIFIED). "Flat rate of 5 credits per successful generation" ([OpenAPI](https://api.stability.ai/v2alpha/openapi)); Erase and Inpaint have cost 5 credits since 1 August 2025 ([pricing update](https://stability.ai/api-pricing-update-25)).
- **Inpaint** requires `prompt` ([OpenAPI](https://api.stability.ai/v2alpha/openapi)).
- **Price and key.** "API usage is based on credits. 1 credit = $0.01." "Get started with 25 free credits" (the platform's pricing text, read from the script behind [platform.stability.ai/pricing](https://platform.stability.ai/pricing)).
- **Terms** (effective 30 September 2026): "we may use Content to improve and develop our Services (but you can opt-out to prevent us from using your Inputs and Outputs to train our models" (§4c); "we assign to you all of our right, title, and interest (if any) in the Outputs" (§4a); you may not "knowingly remove, obscure, disable, or circumvent any watermark, content credential, provenance information, or other marking applied by Stability ... except as expressly permitted by Stability, the applicable documentation, or applicable law" (§3) ([terms](https://stability.ai/terms-of-service)). The opt-out is a toggle, "Training: Improve the Model for Everyone", in the platform's account settings ([privacy center](https://stability.ai/privacy-center)). The platform's API changelog says "all of our APIs come with standard safety features for input filtering, NSFW filtering of input images and generated content, known CSAM content filtering through Thorn, and C2PA signing" (read from the same [script](https://platform.stability.ai/assets/index-DtvkdpVO.js)).

**Assessment:** a simple synchronous call with a seed and free credits to try it, but it trains unless the photographer finds the toggle, and the service is older than the others here: the changelog announces "Erase Object" on 20 May 2024. Worth including in a bake-off, not first.

### Clipdrop (Jasper)

**Evidence:** `POST https://clipdrop-api.co/cleanup/v1` takes a multipart `image_file` (JPEG or PNG, up to 16 megapixels and 30 MB) and `mask_file` (PNG, 0 or 255, the same size), with `mode` `fast` or `quality`, and returns a PNG of the same size synchronously; one call is one credit, with 100 free development credits. The page now says "Clipdrop is part of Jasper now" and points to sales for credits ([Cleanup](https://clipdrop.co/apis/docs/cleanup)). Jasper's API says "Image API access is available for customers on the Jasper Business plan with an API subscription" ([Jasper cleanup](https://developers.jasper.ai/reference/cleanup)).

**Assessment:** the right shape, but not open to an individual photographer.

### OpenAI

**Evidence** ([image generation guide](https://developers.openai.com/api/docs/guides/image-generation.md)):

- Edits use `gpt-image-2.5-sunburst` or `gpt-image-2.5-flare` (and older GPT Image models) with a required prompt. "Masking with GPT Image is entirely prompt-based. The model uses the mask as guidance, but may not follow its exact shape with complete precision." The mask needs an alpha channel and the same format and size as the image, under 50 MB.
- Sizes: multiples of 16, ratio up to 3:1, edges up to 3840 px, and "The total pixel count must be between 655,360 and 8,294,400", so a 512 × 512 crop (262,144 pixels) is below the minimum. Output is base64 PNG, JPEG or WebP. No seed parameter is documented. "Latency: Complex prompts may take up to 2 minutes to process." Moderation is `auto` or `low`.
- Price: $8 per million image input tokens and $30 per million image output tokens for GPT Image 2.5 ([pricing](https://developers.openai.com/api/docs/pricing.md)); the cost of one image is shown only by the guide's calculator (UNVERIFIED).
- Key: "you may need to complete the API Organization Verification" before using GPT Image models; identity verification needs "an original, physical government-issued ID ... and, if requested, a selfie" ([help, archived 7 October 2026](https://web.archive.org/web/20261007021029/https://help.openai.com/en/articles/10910291-api-organization-verification)).
- Data: "data sent to the OpenAI API is not used to train or improve OpenAI models (unless you explicitly opt in"; abuse monitoring logs are kept "for up to 30 days"; Zero Data Retention needs "prior approval by OpenAI" ([your data](https://developers.openai.com/api/docs/guides/your-data.md)).
- Provenance: images from the API "include both" C2PA metadata and SynthID watermarks ([help, archived 20 September 2026](https://web.archive.org/web/20260920141125/https://help.openai.com/en/articles/8912793-c2pa-in-chatgpt-images)).

**Assessment:** not a fit: it needs words, it may change pixels outside the mask, it takes no seed, and the key can need a government ID.

### Google

**Evidence:**

- **Gemini API.** The image models are `gemini-nano-banana-2.1`, `gemini-3.1-flash-image`, `gemini-3.1-flash-lite-image` and `gemini-3-pro-image`. Editing is by prompt; "Inpainting (semantic masking)" means to "Conversationally define a 'mask'", and there is no mask parameter. "All generated images include a SynthID watermark" ([image generation](https://ai.google.dev/gemini-api/docs/image-generation)). Prices: $0.0336 per 1K image for Nano Banana 2.1 and Lite, $0.067 for 3.1 Flash Image, $0.134 for 3 Pro Image; the free tier is "Not available" for image models; Gemini 2.5 Flash Image "will be shut down on October 2, 2026" ([pricing](https://ai.google.dev/gemini-api/docs/pricing)).
- **Gemini terms.** For Paid Services, "Google doesn't use your prompts (including ... files such as images ...) or responses to improve our products", logs them "for a limited period of time, solely for detecting and preventing violations", and the data "may be stored transiently or cached in any country"; you "must be 18 years of age or older", and "You may use only Paid Services when making API Clients available to users in the European Economic Area, Switzerland, or the United Kingdom" ([terms](https://ai.google.dev/gemini-api/terms)).
- **Vertex AI.** Removal with a mask (`EDIT_MODE_INPAINT_REMOVAL`) was supported only by `imagen-3.0-capability-001`, which the page lists among "Discontinued endpoints", recommending migration "before June 30, 2026" to `gemini-2.5-flash-image` ([remove objects](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/image/edit-remove-objects)).

**Assessment:** not a fit. Gemini takes no mask, and Vertex's removal mode is gone. BFL's benchmark rates Nano Banana Pro slightly above FLUX Erase, but at more than four times the price and through words, not a mask.

### Adobe Firefly Services

**Evidence:** `POST https://firefly-api.adobe.io/v3/images/fill-async` requires `image` and `mask` (an upload ID, or a pre-signed URL on `amazonaws.com`, `windows.net`, `dropboxusercontent.com` or `storage.googleapis.com`), and takes "An optional text prompt", seed images and an output size from a fixed list that includes 1024 × 1024 and 2048 × 2048 (the default) ([OpenAPI, from Adobe's docs repository](https://raw.githubusercontent.com/AdobeDocs/ffs-firefly-api/main/static/firefly-api.json)). White mask areas "are exposed" to edits ([masking](https://developer.adobe.com/firefly-services/docs/firefly-api/guides/concepts/masking/)). Credentials are OAuth server-to-server ([getting started](https://developer.adobe.com/firefly-services/docs/firefly-api/getting-started/)); the credentials page is titled "[Admins only] Get Credentials" and says to "Reach out to your Adobe liaison" ([create credentials](https://raw.githubusercontent.com/AdobeDocs/ffs-firefly-api/main/src/pages/getting-started/create-credentials/index.md)); "Enterprise customers must be assigned the System Administrator or Developer role in the Adobe Admin Console to access the Adobe Developer Console" ([Firefly Services](https://raw.githubusercontent.com/AdobeDocs/ff-services-docs/main/src/pages/guides/get-started.md)). Rate limits are set "per organization" ([usage notes](https://developer.adobe.com/firefly-services/docs/firefly-api/getting-started/usage-notes/)).

**Assessment:** technically close (a prompt-free fill), but only enterprise organisations can get credentials.

### Photoroom and Picsart

**Evidence:**

- **Photoroom** has no mask-based removal in its API. "Edit With AI" edits "by providing a textual description of the changes", for example `editWithAI.prompt="Remove all the people"`, at 1K output by default ([Edit With AI](https://docs.photoroom.com/image-editing-api-plus-plan/edit-with-ai.md)); "each API call is priced at $0.10" on the Plus plan ([pricing](https://docs.photoroom.com/image-editing-api-plus-plan/pricing.md)).
- **Picsart** has `POST https://genai-api.picsart.io/v1/painting/remove-object`, which "allows to remove objects from the original image by providing a mask" with "a specially trained model", taking an image and a mask as files or URLs, returning JPG (default), PNG or WebP, synchronously or asynchronously through the `Prefer` header ([Remove Object](https://docs.picsart.io/reference/genai-remove-object.md)). "New Picsart accounts receive 5 free credits"; more come with the Pro or Ultra plans ([API key](https://docs.picsart.io/docs/creative-apis-get-api-key.md), [limits](https://docs.picsart.io/docs/creative-apis-quotas-and-limits.md)). Result URLs "have a limited lifespan of 24 hours" and data is stored "on encrypted Google Buckets" ([security](https://docs.picsart.io/docs/picsart-create-editor-security.md)). The credit cost of one call and the data-use terms are UNVERIFIED: the developer guidelines need JavaScript.

**Assessment:** Photoroom doesn't fit. Picsart's endpoint fits, but its price and terms need reading before a test.

### Recraft

**Evidence:** `POST https://external.api.recraft.ai/v1/images/eraseRegion` "removes the part of an image that a mask marks" for "$0.002 per request". Image and mask must be under 20 MB and 16 MP, with sides from 256 to 4096 px; the mask is the image's size, every pixel pure black or white, "White pixels (`255`) mark the area to erase". The response is synchronous, as a URL, base64 or multipart bytes, in lossless WebP (default) or PNG; result files "are kept for about 24 hours" ([Erase region](https://www.recraft.ai/docs/api-reference/tools/erase-region.md)). "API inputs and outputs are never used for model training. Data sent through the Recraft API is processed only to generate requested results and is not stored or used to improve models" ([data use](https://www.recraft.ai/docs/trust-and-security/data-use-and-model-training.md)). The model behind it is not named.

**Assessment:** cheap, synchronous and with good data terms, but there is no evidence on photographic quality, and its price suggests a small model (opinion). Include it in a bake-off.

### Amazon Bedrock

**Evidence:** Bedrock offers Stability's Erase as `us.stability.stable-image-erase-object-v1:0`, with a base64 image of up to 9,437,184 pixels and an aspect ratio between 1:2.5 and 2.5:1 ([Stability on Bedrock](https://docs.aws.amazon.com/bedrock/latest/userguide/stable-image-services.html)). Model providers "don't have access to Amazon Bedrock logs or to customer prompts and completions" ([data protection](https://docs.aws.amazon.com/bedrock/latest/userguide/data-protection.html)). Requests authenticate with AWS credentials or a Bedrock API key, short-term (up to 12 hours) or long-term ([API keys](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html)). Price and regions outside the US were not checked.

**Assessment:** a privacy-friendly host for Stability's Erase, but an AWS account and IAM are more than most photographers will set up.

### Hugging Face Inference Providers

**Evidence:** the `image-to-image` task takes `inputs` (a base64 image) and `parameters` (`prompt`, `guidance_scale`, `negative_prompt`, `num_inference_steps`, `target_size`), with no mask ([task](https://huggingface.co/docs/inference-providers/tasks/image-to-image.md)); the fal provider supports the same task ([fal provider](https://huggingface.co/docs/inference-providers/providers/fal-ai.md)). Billing passes the provider's price through "with no markup"; free users have no monthly credits and must buy them, and PRO users get $2.00 a month ([pricing](https://huggingface.co/docs/inference-providers/pricing.md)). "We do not store the request body or response when routing requests through Hugging Face. Logs are kept for debugging purposes for up to 30 days" ([security](https://huggingface.co/docs/inference-providers/security.md)).

**Assessment:** not a route for mask-based removal; I found no documented way to reach a provider's own mask endpoint through it.

### Runware and Finegrain (not fully reviewed)

Runware is another aggregator: its tasks take a `maskImage` ("White is edited and black is preserved"), outputs are kept "for **7 days** by default", and "Zero Data Retention (ZDR) is an **organization-level option for enterprise accounts**" ([docs](https://runware.ai/docs/llms.txt)). Whether it hosts a prompt-free eraser was not checked. Finegrain's own API was not found at the addresses tried (finegrain.ai/docs and /pricing returned 404); its eraser was reviewed only on fal.

## Assessment

### What the evidence shows

- **Prompt-free, mask-based removal by API** is offered by BFL (FLUX Erase), Bria (Eraser), Ideogram (Remove an object), Stability (Erase, also on Bedrock), Recraft (Erase region), Picsart (Remove Object), fal (its own Object Removal, and Finegrain's), and Clipdrop, which only businesses can use. OpenAI, Google and Photoroom need words; OpenAI treats the mask as guidance, and Google and Photoroom take none. Vertex AI's removal mode is discontinued, and Adobe's Fill is open only to enterprise organisations.
- **Inputs and outputs.** None takes a reference image for an erase, and none documents 16-bit input or output: every one lists JPEG, PNG or WebP. Several default to JPEG output (fal's FLUX Erase, BFL's Fill, Picsart), so a filler should ask for PNG. Seeds are documented by BFL, Ideogram, Stability and Finegrain, and not by Bria, Recraft, Clipdrop, Picsart, fal's Object Removal or fal's wrapper of FLUX Erase.
- **Training.** Not used for training by default: Bria (a warranty), Recraft's API, OpenAI, Google's paid tier, fal (for partner models it marks ready) and Replicate (a licence limited to running the service and compiling usage data). Used unless the photographer opts out: BFL (by email) and Stability (a toggle). Ideogram's direct agreement allows use "in any manner".
- **Marks and duties.** fal, Bria, Stability, OpenAI and Google add C2PA metadata, an invisible watermark or both. BFL, Bria and Stability forbid removing their marks, and Bria also requires the output to be marked "AI Generated". BFL and Ideogram forbid uploading people without their consent, and BFL forbids images of anyone under 18.
- **Price per crop** runs from $0.002 (Recraft) through $0.02 (Bria), $0.03 (FLUX Erase, Ideogram on fal) and $0.05 (Stability) to $0.13 or more (Gemini 3 Pro Image, Finegrain Standard).

### Opinion: the first BYOK integration

1. **Bria Eraser, direct.** It removes what the mask covers with no words, keeps every pixel outside the mask, answers synchronously if asked, costs $0.02, and a photographer can try it with 100 free calls before giving a card. Its self-serve terms promise no training, keep no inputs, rest on licensed training data and carry an IP warranty, so a consent sheet can state them in a sentence. Before offering it, measure it on Redlamp's removal samples (the D7500's parked car, the duck on water) and check what three calls on one spot return, since it takes no seed.
2. **FLUX Erase**, from BFL directly or through fal. Technically it matches what Redlamp already does: the same FLUX.2 [klein] family as Redlamp's on-device fill, no words, dilation, and on BFL's own API a seed for three different fills and an EU-only host; the vendor's benchmark puts it level with Nano Banana 2. Directly, Redlamp's consent sheet would have to say that BFL may train on the crop and how to opt out, and that BFL's terms forbid images of people without their consent and of anyone under 18. Through fal the same model comes with no-training terms, which makes fal the better way to reach it for a privacy-conscious photographer.
3. **Only after a bake-off:** Stability Erase (synchronous, seeded, 25 free credits) or Recraft's Erase region ($0.002, no training on API data), if either matches the first two on the samples.

**For a "third-party provider Redlamp works with", fal.** One key reaches FLUX Erase, Bria Eraser and Ideogram Object Removal; fal's terms promise no training on those partner models and add a DPA; per-request headers turn off payload storage and set media lifetimes; and calls can be synchronous. Replicate offers only Bria's eraser among these, at $0.04, and requires GitHub sign-in. Hugging Face's router can't carry a mask. Under fal's terms a key Redlamp held could not be exposed in the app, so without Redlamp-run servers the aggregator route is still the photographer's own fal key.

### What an integration would need

- Send the crop as an 8-bit sRGB PNG and the mask as an 8-bit PNG, white for 1. Ideogram on Replicate inverts the mask and OpenAI uses alpha; neither is recommended. Ask for PNG output, and resample if the output size differs from the crop's, as BFL's examples suggest it can.
- Poll for BFL, Ideogram and Bria's default mode, and download BFL's result within 10 minutes. Progress can show only coarse states (sent, waiting, received).
- Record in the `GeneratedFill` the provider, endpoint or model, request ID and date, beside the existing Generated label, and write that into the export's Content Credentials once RM-03 lands. Redlamp's pipeline can't keep a provider's C2PA manifest on the pixels it stores, so this is how it meets Bria's and Stability's marking clauses (a question for counsel).
- Test whether blanking the masked pixels before upload keeps quality. If it does, the object being removed, often a person, never leaves the Mac. BFL says it "converts the binary mask to a green fill internally", but FLUX Erase also removes "traces like shadows", which may need it to see the object.
- On fal, send `X-Fal-Store-IO: 0` and `sync_mode: true` and pass data URIs, so nothing lands on its public CDN. On BFL, use `api.eu.bfl.ai` for photographers in Europe.

### Risks

- **Training on photographers' crops** by default (BFL, Stability), and Ideogram's broad data clause.
- **Consent and under-18 clauses** (BFL, Ideogram) conflict with common removals: a stranger in a street photo, a child in a family photo. The photographer, as the account holder, carries them.
- **Provenance duties** (BFL, Bria, Stability) against a pipeline that maps the fill to camera RGB and stores it as a 16-bit PNG. Invisible watermarks may partly survive in the generated pixels; C2PA metadata won't.
- **Models change under the same endpoint, or go away.** BFL may modify its models "at any time"; Google discontinued Imagen's editing model and scheduled Gemini 2.5 Flash Image, the replacement it recommended, to shut down on 2 October 2026. A seed won't reproduce a fill after a change. Storing fills as pixels, as Redlamp already does, covers this.
- **Moderation refusals** on photos with people (BFL's `safety_tolerance`, Ideogram's `is_image_safe`, Bria's opt-in moderation).
- **8-bit output** in smooth skies, where the photo's noise that Redlamp adds may hide banding (opinion).

## Not verified

- Quality, latency, cost per call and determinism of every API on Redlamp's samples: no calls were made. The only comparative quality figures are BFL's own.
- BFL: the maximum input size; whether output size equals input size (the examples' file names suggest not); whether API outputs carry Content Credentials; whether the training opt-out covers API keys as well as the account.
- fal: whether §2.4 binds partner APIs such as BFL, or only fal itself; whether the "reference megapixel" charge applies to FLUX Erase; free credits.
- Ideogram: the direct price (behind a Cloudflare challenge) and who owns outputs.
- Bria: the maximum input size, the output format and where data is processed.
- Stability: whether training is on for new accounts, whether Erase resizes its output to 4 megapixels, and where data is processed.
- Picsart: the credit cost of Remove Object and its data terms. Recraft: the model behind Erase region, and how "not stored" squares with result files kept about 24 hours.
- OpenAI: the cost of one GPT Image 2.5 edit at 1024 × 1024, and whether every new account must verify identity.
- Bedrock: price, seed support and availability in EU regions. Runware and Finegrain's own API: not reviewed. Adobe: price and Content Credentials on API output. Clipdrop: terms.

## Sources (all read 7 October 2026)

**Redlamp**
- `packages/RedlampEngineAPI/Sources/GenerativeFill.swift`; `docs/plans/2026-10-05-generative-fill-design.md`; `docs/research/research-tracker.md` (DEC-39, INF-11)

**Black Forest Labs**
- https://docs.bfl.ai/llms.txt ; https://docs.bfl.ai/llms-full.txt
- https://docs.bfl.ml/flux_tools/flux_erase.md ; https://docs.bfl.ml/api-reference/models/erase-an-object-from-an-image.md ; https://api.bfl.ai/openapi.json
- https://docs.bfl.ml/release-notes.md ; https://bfl.ai/blog/flux-erase-remove-anything-leave-no-trace
- https://docs.bfl.ml/quick_start/pricing.md ; https://bfl.ai/pricing
- https://docs.bfl.ml/api_integration/integration_guidelines.md ; https://docs.bfl.ml/quick_start/get_started.md ; https://docs.bfl.ml/account_management/credits_billing.md
- https://docs.bfl.ml/flux_1_fill.md ; https://docs.bfl.ml/guides/usecases_editing_object_removal.md
- https://bfl.ai/legal/flux-api-service-terms ; https://bfl.ai/legal/eu-api-service-terms ; https://bfl.ai/legal/developer-terms-of-service ; https://bfl.ai/legal/eu-developer-terms-of-service ; https://bfl.ai/legal/privacy-policy ; https://bfl.ai/legal/responsible-ai-development-policy ; https://bfl.ai/enterprise

**fal**
- https://fal.ai/llms.txt ; https://fal.ai/api/models?keywords=eraser (and the keywords erase, object removal, remove, inpaint, inpainting, fill, lama, cleanup, image edit)
- https://fal.ai/models/fal-ai/flux-pro/v1/erase/llms.txt ; https://fal.ai/models/fal-ai/flux-pro/v1/erase
- https://fal.ai/models/fal-ai/bria/eraser/llms.txt ; https://fal.ai/models/fal-ai/bria/eraser
- https://fal.ai/models/fal-ai/ideogram/object-removal/llms.txt ; https://fal.ai/models/fal-ai/ideogram/object-removal
- https://fal.ai/models/fal-ai/finegrain-eraser/mask/llms.txt ; https://fal.ai/models/fal-ai/finegrain-eraser/mask
- https://fal.ai/models/fal-ai/object-removal/mask/llms.txt ; https://fal.ai/models/fal-ai/object-removal/mask
- https://fal.ai/models/fal-ai/flux-pro/v1/fill/llms.txt ; https://fal.ai/models/fal-ai/qwen-image-edit/inpaint/llms.txt
- https://fal.ai/docs/llms.txt ; https://fal.ai/docs/documentation/quickstart.md ; https://fal.ai/docs/documentation/model-apis/overview.md ; https://fal.ai/docs/documentation/model-apis/inference/synchronous.md ; https://fal.ai/docs/documentation/model-apis/authentication.md ; https://fal.ai/docs/documentation/model-apis/fal-cdn.md ; https://fal.ai/docs/documentation/model-apis/media-expiration.md
- https://fal.ai/pricing ; https://fal.ai/verify
- https://fal.ai/legal/terms-of-service ; https://fal.ai/legal/api-services ; https://fal.ai/legal/acceptable-use-policy ; https://fal.ai/legal/privacy-policy ; https://fal.ai/legal/data-processing-addendum

**Replicate**
- https://replicate.com/llms.txt ; https://replicate.com/bria/eraser/llms.txt ; https://replicate.com/bria/eraser
- https://replicate.com/black-forest-labs/flux-fill-pro/llms.txt ; https://replicate.com/black-forest-labs/flux-fill-pro ; https://replicate.com/ideogram-ai/ideogram-v3-turbo/llms.txt ; https://replicate.com/ideogram-ai/ideogram-v3-turbo ; https://replicate.com/qwen/qwen-image-edit
- https://replicate.com/black-forest-labs ; https://replicate.com/collections/image-editing
- https://replicate.com/docs/topics/predictions/data-retention.md ; https://replicate.com/docs/topics/predictions/create-a-prediction.md ; https://replicate.com/docs/topics/predictions/input-files.md ; https://replicate.com/docs/topics/billing.md ; https://replicate.com/pricing ; https://replicate.com/signin
- https://replicate.com/terms ; https://replicate.com/privacy ; https://replicate.com/blog ; https://blog.cloudflare.com/replicate-joins-cloudflare/ (title only)

**Bria AI**
- https://docs.bria.ai/llms.txt ; https://docs.bria.ai/image-editing.md ; https://docs.bria.ai/image-editing/editing/erase.md
- https://docs.bria.ai/getting-started/quickstart.md ; https://docs.bria.ai/getting-started/working-with-images.md ; https://docs.bria.ai/getting-started/asset-retention.md ; https://docs.bria.ai/getting-started/rate-limits-and-errors.md ; https://docs.bria.ai/image-editing-best-practices.md
- https://docs.bria.ai/safety.md ; https://docs.bria.ai/trust-and-provenance-overview.md
- https://bria.ai/pricing ; https://bria.ai/legal-lobby ; https://bria.ai/privacy-policy ; https://bria.ai/security-and-compliance
- Bria Online AI General Terms and Conditions, September 2026 V1.4: https://drive.google.com/file/d/1WaqnqpRdfPqtJIwUnWS6kAl0UnrLUFLz/view

**Ideogram**
- https://developer.ideogram.ai/llms.txt ; https://developer.ideogram.ai/v2/llms.txt
- https://developer.ideogram.ai/api-reference/images/remove-object/ideogram-1.md ; https://developer.ideogram.ai/api-reference/generations/get-generation.md
- https://developer.ideogram.ai/ideogram-api/api-setup.md ; https://developer.ideogram.ai/ideogram-api/api-overview.md
- https://ideogram.ai/pricing/?pricing_tab=api (price table not readable) ; https://ideogram.ai/legal/api-tos

**Stability AI**
- https://api.stability.ai/v2alpha/openapi (titled "StabilityAI REST API v2beta")
- https://platform.stability.ai/docs/api-reference and https://platform.stability.ai/pricing, read through the page's script https://platform.stability.ai/assets/index-DtvkdpVO.js (pricing text and API changelog)
- https://stability.ai/api-pricing-update-25 ; https://stability.ai/terms-of-service ; https://stability.ai/privacy-center

**Clipdrop and Jasper**
- https://clipdrop.co/apis/docs/cleanup ; https://developers.jasper.ai/reference/cleanup

**OpenAI**
- https://developers.openai.com/llms.txt ; https://developers.openai.com/api/docs/guides/image-generation.md ; https://developers.openai.com/api/docs/pricing.md ; https://developers.openai.com/api/docs/guides/your-data.md
- https://web.archive.org/web/20261007021029/https://help.openai.com/en/articles/10910291-api-organization-verification
- https://web.archive.org/web/20260920141125/https://help.openai.com/en/articles/8912793-c2pa-in-chatgpt-images

**Google**
- https://ai.google.dev/gemini-api/docs/image-generation ; https://ai.google.dev/gemini-api/docs/pricing ; https://ai.google.dev/gemini-api/terms
- https://docs.cloud.google.com/vertex-ai/generative-ai/docs/image/edit-remove-objects

**Adobe**
- https://developer.adobe.com/firefly-services/docs/firefly-api/ ; https://developer.adobe.com/firefly-services/docs/firefly-api/getting-started/ ; https://developer.adobe.com/firefly-services/docs/firefly-api/getting-started/dev-console/ ; https://developer.adobe.com/firefly-services/docs/firefly-api/getting-started/usage-notes/ ; https://developer.adobe.com/firefly-services/docs/firefly-api/guides/concepts/masking/ ; https://developer.adobe.com/firefly-services/docs/firefly-api/guides/how-tos/firefly-fill-image-api-tutorial ; https://developer.adobe.com/sitemap.xml
- https://raw.githubusercontent.com/AdobeDocs/ffs-firefly-api/main/static/firefly-api.json ; https://raw.githubusercontent.com/AdobeDocs/ffs-firefly-api/main/src/pages/getting-started/create-credentials/index.md ; https://raw.githubusercontent.com/AdobeDocs/ff-services-docs/main/src/pages/guides/get-started.md

**Photoroom and Picsart**
- https://docs.photoroom.com/llms.txt ; https://docs.photoroom.com/image-editing-api-plus-plan/edit-with-ai.md ; https://docs.photoroom.com/image-editing-api-plus-plan/pricing.md
- https://docs.picsart.io/llms.txt ; https://docs.picsart.io/reference/genai-remove-object.md ; https://docs.picsart.io/docs/creative-apis-get-api-key.md ; https://docs.picsart.io/docs/creative-apis-quotas-and-limits.md ; https://docs.picsart.io/docs/picsart-create-editor-security.md ; https://picsart.io/terms (redirects to https://picsart.com/developer-guidelines/, which needs JavaScript)

**Recraft, Amazon, Hugging Face, Runware, Finegrain**
- https://www.recraft.ai/docs/llms.txt ; https://www.recraft.ai/docs/api-reference/tools/erase-region.md ; https://www.recraft.ai/docs/trust-and-security/data-use-and-model-training.md
- https://docs.aws.amazon.com/bedrock/latest/userguide/stable-image-services.html ; https://docs.aws.amazon.com/bedrock/latest/userguide/data-protection.html ; https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html ; https://aws.amazon.com/bedrock/faqs/
- https://huggingface.co/docs/inference-providers/tasks/image-to-image.md ; https://huggingface.co/docs/inference-providers/providers/fal-ai.md ; https://huggingface.co/docs/inference-providers/pricing.md ; https://huggingface.co/docs/inference-providers/security.md
- https://runware.ai/docs/llms.txt
- https://finegrain.ai/docs and https://finegrain.ai/pricing (both 404)
