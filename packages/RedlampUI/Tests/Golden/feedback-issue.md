<!-- redlamp-feedback v1 {"area":"masking.objects","kind":"bug","report":"6F1C2A7E-0B5D-4C3B-9E2A-1D4F5A6B7C8D","version":"0.2.1-prealpha (412, 1a2b3c4d5e6f)"} -->
**Area:** Masking › Objects · **Kind:** Bug · **How often:** Every time · **Other photos:** Yes, those too
**From:** Redlamp 0.2.1-prealpha (412, 1a2b3c4d5e6f) on macOS 26.1.0 (25B78), Mac16,7 (Apple M4 Max)
**Reported by:** @octocat

### What happened

I clicked the dog, then the bench. The dog's selection disappeared.

### What I expected

Both selected, as the panel says a second click adds.

### Steps to reproduce

1. Masking › Objects
2. Click the dog
3. Click the bench

### Screenshots

![Screenshot 1: Redlamp's window](attachment:screenshot-1.jpg)

<details><summary>Photo</summary>

|  |  |
| --- | --- |
| Photo | Photo A |
| Format | RAF (raw, X-Trans) |
| Camera | Fujifilm X-T5 |
| Lens | XF16-55mmF2.8 R LM WR |
| Exposure | ISO 400, 23 mm, ƒ/4.0, 1/250 s |
| Size | 7728 × 5152 (39.8 MP) |
| As-shot white balance | 5200 K, tint 4 |
| Lens correction | Fujifilm |
| Disk | apfs, internal |

</details>

<details><summary>Edit (process version 10)</summary>

- **Treatment:** Color · **Base Look:** Redlamp Color (100) · **White balance:** As Shot
- **Recipe:** Portra 400 (80)
- **Basic:** Exposure +0.50, Shadows +30
- **Masks (1):**
  - “Sky”: Sky; Exposure -0.60; amount 100; vision r1 on 25B78
- **Healing spots:** 2

</details>

<details><summary>This photo's history (3 steps)</summary>

1. Opened
2. Exposure: 0.00 → +0.50
3. Mask 2: Objects

</details>

<details><summary>What happened before (last 15 minutes, 5 events)</summary>

| Before | What |
| --- | --- |
| 4:12 | Opened Photo A: RAF, Fujifilm X-T5, 7728 × 5152, with an edit, in 1.4 s |
| 3:20 | Exposure: 0.00 → +0.50 |
| 2:30 | Tool: Masking |
| 2:00 | Selected mask “Mask 2”: Objects |
| 0:30 | Save failed: Couldn’t write “…/Photo A.redlamp” |

</details>

<details><summary>Editor state</summary>

|  |  |
| --- | --- |
| Tool | Masking |
| Panels open | Basic |
| Zoom | 100% |
| Selected mask | “Mask 2”: Objects |
| Photos in the folder | 240 |
| On screen | The model isn't downloaded |

</details>

<details><summary>System</summary>

|  |  |
| --- | --- |
| Redlamp | 0.2.1-prealpha (412, 1a2b3c4d5e6f), Release |
| macOS | 26.1.0 (25B78) |
| Mac | Mac16,7, Apple M4 Max, 12 performance and 4 efficiency cores |
| Memory | 64 GB |
| GPU | Apple M4 Max, 48 GB working set |
| Display 1 | 3024 × 1964 pt at 2x, Display P3, HDR up to 16x |
| Thermal state | nominal |
| Locale | en_PT |
| Models | Segment Anything 2.1 Tiny (sam2.1-tiny): ready |

</details>

<details><summary>Redlamp's log (1 entry)</summary>

```text
08:02:11 error render: The GPU timed out
```

</details>

---
[diagnostics.json](attachment:diagnostics.json) has these details in full, with the photo's edit in Redlamp's sidecar format.
<sub>Sent from Redlamp's Report a Bug or Send Feedback.</sub>
