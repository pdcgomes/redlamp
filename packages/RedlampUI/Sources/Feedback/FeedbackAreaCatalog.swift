/// Every area a report can be about, in the order the picker lists them: the editor's tools
/// first, then the rest of the window, then what sits under it all. Titles are the UI's own
/// labels; each area but Something Else ends with "Something else in …".
///
/// `docs/feedback/areas.json` is generated from this (`FeedbackAreaTests`), and
/// `scripts/feedback-labels.py` makes a GitHub label for each area from it.
public extension FeedbackArea {
    static let catalog: [FeedbackArea] = [
        FeedbackArea(
            "develop", "Develop", symbol: "slider.horizontal.3",
            summary: "The Develop panels: white balance, tone, colour, detail, lens, transform and effects.",
            tracker: ["TON", "AUT", "DN", "SHP", "LNS"],
            features: [
                FeedbackFeature(
                    "white-balance",
                    "White Balance",
                    ["temperature", "temp", "tint", "eyedropper", "as shot", "wb"],
                ),
                FeedbackFeature(
                    "treatment", "Treatment and Base Looks",
                    ["black and white", "b&w", "monochrome", "profile", "base look", "camera profile", "dcp"],
                ),
                FeedbackFeature(
                    "reproduction", "Redlamp Reproduction and Calibrate from Target",
                    [
                        "reproduction", "scene-referred", "linear", "calibrate", "calibration", "target", "grey card",
                        "colorchecker", "anchor", "stops", "copy stand", "artwork",
                    ],
                ),
                FeedbackFeature(
                    "tone",
                    "Tone",
                    ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "brightness"],
                ),
                FeedbackFeature(
                    "presence",
                    "Presence",
                    ["texture", "clarity", "dehaze", "haze", "vibrance", "saturation"],
                ),
                FeedbackFeature("auto", "Auto Settings", ["auto tone", "auto white balance", "automatic"]),
                FeedbackFeature("tone-curve", "Tone Curve", ["curve", "parametric", "point curve", "rgb curve"]),
                FeedbackFeature(
                    "color-mixer",
                    "Color Mixer",
                    ["hsl", "hue", "saturation", "luminance", "color", "b&w mix"],
                ),
                FeedbackFeature(
                    "point-color",
                    "Point Color",
                    ["swatch", "uniformity", "variance", "skin tone", "even skin", "visualize range"],
                ),
                FeedbackFeature(
                    "color-grading",
                    "Color Grading",
                    ["split toning", "wheels", "midtones", "blending", "balance"],
                ),
                FeedbackFeature(
                    "sharpening",
                    "Sharpening",
                    ["sharpen", "radius", "detail", "masking", "halos", "crisp"],
                ),
                FeedbackFeature(
                    "noise-reduction",
                    "Noise Reduction",
                    ["noise", "denoise", "luminance noise", "color noise", "nr"],
                ),
                FeedbackFeature(
                    "lens-corrections", "Lens Corrections",
                    [
                        "lens profile",
                        "distortion",
                        "vignetting",
                        "chromatic aberration",
                        "ca",
                        "defringe",
                        "purple fringe",
                        "lcp",
                    ],
                ),
                FeedbackFeature(
                    "transform",
                    "Transform and Upright",
                    ["perspective", "upright", "keystone", "vertical", "guided"],
                ),
                FeedbackFeature(
                    "effects", "Effects",
                    ["vignette", "grain", "halation", "bloom", "light leak", "dust", "scratches", "frame", "film"],
                ),
                FeedbackFeature(
                    "camera-recipe", "Camera Recipe",
                    [
                        "fujifilm",
                        "dynamic range",
                        "color chrome",
                        "chrome fx blue",
                        "white balance shift",
                        "recipe card",
                    ],
                ),
                FeedbackFeature(
                    "calibration",
                    "Calibration and Process Version",
                    ["process version", "primaries", "camera calibration"],
                ),
                FeedbackFeature("histogram", "Histogram", ["clipping indicators", "histogram"]),
            ],
        ),
        FeedbackArea(
            "masking", "Masking", symbol: "circle.dashed.inset.filled",
            summary: "Masks and local adjustments: AI masks, brushes, gradients and ranges.",
            tracker: ["MSK", "INF"],
            features: [
                FeedbackFeature("subject", "Subject", ["select subject", "person", "ai mask"]),
                FeedbackFeature("sky", "Sky", ["select sky", "clouds"]),
                FeedbackFeature("background", "Background", ["select background"]),
                FeedbackFeature(
                    "objects", "Objects",
                    ["object selector", "select object", "segment anything", "sam", "click to select", "hover"],
                ),
                FeedbackFeature(
                    "people", "People",
                    ["face", "skin", "eyes", "iris", "lips", "teeth", "hair", "eyebrows", "body", "clothes"],
                ),
                FeedbackFeature(
                    "landscape",
                    "Landscape",
                    ["water", "vegetation", "mountains", "architecture", "ground"],
                ),
                FeedbackFeature("depth-range", "Depth Range", ["depth map", "depth anything", "near", "far"]),
                FeedbackFeature(
                    "brush",
                    "Brush",
                    ["paint", "erase", "auto mask", "flow", "density", "pressure", "pen"],
                ),
                FeedbackFeature("linear", "Linear Gradient", ["graduated filter", "gradient", "grad"]),
                FeedbackFeature("radial", "Radial Gradient", ["radial filter", "ellipse", "circle"]),
                FeedbackFeature("color-range", "Color Range", ["color picker", "eyedropper", "hue range"]),
                FeedbackFeature("luminance-range", "Luminance Range", ["brightness range", "luminance map"]),
                FeedbackFeature(
                    "combining", "Combining Masks",
                    ["add", "subtract", "intersect", "invert", "existing mask", "components"],
                ),
                FeedbackFeature(
                    "refine",
                    "Refine Edges and Edge Brush",
                    ["edges", "hair", "matting", "refine", "edge brush"],
                ),
                FeedbackFeature(
                    "overlay", "Overlay and Mask List",
                    ["show overlay", "overlay color", "rename", "duplicate", "delete mask", "pins"],
                ),
                FeedbackFeature("local-adjustments", "Local Adjustments", ["mask sliders", "amount", "local exposure"]),
                FeedbackFeature(
                    "point-color", "Point Color in Masks",
                    ["mask swatch", "mask's own colour", "even skin tone", "skin uniformity"],
                ),
                FeedbackFeature("presets", "Mask Presets", ["preset", "saved mask"]),
                FeedbackFeature("update-ai", "Update AI Masks", ["recompute", "update masks", "refresh"]),
                FeedbackFeature(
                    "models",
                    "AI Model Downloads",
                    ["download", "model", "licence", "license", "evaluation models"],
                ),
            ],
        ),
        FeedbackArea(
            "crop", "Crop & Straighten", symbol: "crop",
            summary: "Crop, straighten, rotate and flip.",
            tracker: ["LNS"],
            features: [
                FeedbackFeature("crop", "Crop and Aspect Ratio", ["aspect", "ratio", "lock", "constrain to image"]),
                FeedbackFeature("straighten", "Straighten and Angle", ["level", "angle", "horizon", "tilt"]),
                FeedbackFeature("rotate", "Rotate and Flip", ["rotate left", "rotate right", "flip", "orientation"]),
                FeedbackFeature(
                    "overlays",
                    "Overlays and Guides",
                    ["rule of thirds", "grid", "golden ratio", "overlay"],
                ),
            ],
        ),
        FeedbackArea(
            "healing", "Healing", symbol: "bandage",
            summary: "Remove, Heal and Clone, person and object picks, Find, and Remove Dust.",
            tracker: ["RM"],
            features: [
                FeedbackFeature("remove", "Remove", ["content aware", "content-aware fill", "erase", "remove tool"]),
                FeedbackFeature(
                    "generative", "Generative Remove",
                    ["generative fill", "generative", "ai fill", "generated fill", "flux"],
                ),
                FeedbackFeature("heal", "Heal", ["healing brush", "spot heal", "spot"]),
                FeedbackFeature("clone", "Clone", ["clone stamp"]),
                FeedbackFeature("picks", "Person and Object Picks", ["click picks", "remove person", "remove object"]),
                FeedbackFeature("find", "Find and Remove All", ["find", "things", "remove all"]),
                FeedbackFeature("dust", "Remove Dust", ["dust", "sensor dust", "spots"]),
                FeedbackFeature("visualize", "Visualize Spots", ["visualize", "spots view"]),
                FeedbackFeature("red-eye", "Red Eye Correction", ["red eye", "pet eye"]),
            ],
        ),
        FeedbackArea(
            "recipes", "Recipes & Looks", symbol: "wand.and.stars",
            summary: "Recipes, presets, LUTs and the Film Looks window.",
            tracker: ["TON", "EDT"],
            features: [
                FeedbackFeature("applying", "Applying Recipes", ["apply", "amount", "hover preview", "preset"]),
                FeedbackFeature(
                    "creating",
                    "Creating and Exporting Recipes",
                    ["new recipe", "save preset", "export recipe", "redrecipe"],
                ),
                FeedbackFeature(
                    "importing", "Importing Presets and LUTs",
                    ["import", "xmp", "lightroom preset", "cube", "3dl", "haldclut", "lut", "log"],
                ),
                FeedbackFeature("film-looks", "Film Looks Window", ["film", "film stock", "film looks"]),
                FeedbackFeature("favorites", "Favorites and Search", ["favorite", "favourite", "search recipes"]),
            ],
        ),
        FeedbackArea(
            "history", "History & Snapshots", symbol: "clock.arrow.circlepath",
            summary: "Undo, the History panel, earlier sessions and snapshots.",
            tracker: ["EDT"],
            features: [
                FeedbackFeature("undo", "Undo and Redo", ["undo", "redo"]),
                FeedbackFeature("history", "History Panel", ["history steps", "clear history"]),
                FeedbackFeature("sessions", "Earlier Sessions", ["sessions", "previous sessions", "restore"]),
                FeedbackFeature("snapshots", "Snapshots", ["snapshot", "version"]),
                FeedbackFeature("reset", "Previous and Reset", ["previous button", "reset all", "reset"]),
            ],
        ),
        FeedbackArea(
            "sync", "Copy, Paste & Sync", symbol: "doc.on.doc",
            summary: "Copying, pasting and syncing settings between photos.",
            tracker: ["EDT"],
            features: [
                FeedbackFeature("copy", "Copy Settings", ["copy", "checklist"]),
                FeedbackFeature("paste", "Paste and Paste from Previous", ["paste", "previous"]),
                FeedbackFeature("sync", "Sync Settings", ["sync", "synchronize", "selection", "batch"]),
                FeedbackFeature("auto-sync", "Auto Sync", ["auto sync"]),
            ],
        ),
        FeedbackArea(
            "library", "Library", symbol: "square.grid.3x3",
            summary: "The Library module: the grid, the loupe, folders, the filmstrip, thumbnails, ratings and flags.",
            tracker: ["UX", "LIB"],
            features: [
                FeedbackFeature(
                    "modules",
                    "Library and Develop Modules",
                    ["module", "library module", "develop module", "switch", "module picker"],
                ),
                FeedbackFeature(
                    "grid",
                    "Grid",
                    ["grid", "thumbnail size", "cell style", "expanded cells", "rubber band", "context menu", "j"],
                ),
                FeedbackFeature("loupe", "Loupe", ["loupe", "zoom", "1:1", "fit", "large photo"]),
                FeedbackFeature(
                    "filter",
                    "Filter Bar and Sorting",
                    ["filter", "search", "find", "sort", "metadata", "attribute", "preset", "lock", "offline"],
                ),
                FeedbackFeature(
                    "folders",
                    "Folders Panel",
                    ["add folder", "remove folder", "locate", "missing folder"],
                ),
                FeedbackFeature("subfolders", "Show Photos in Subfolders", ["subfolders", "nested"]),
                FeedbackFeature(
                    "filmstrip",
                    "Filmstrip and Selecting Photos",
                    ["filmstrip", "select", "next photo", "previous photo"],
                ),
                FeedbackFeature("thumbnails", "Thumbnails", ["thumbnail", "preview", "blank thumbnail"]),
                FeedbackFeature(
                    "ratings",
                    "Ratings, Flags, Labels and Marks",
                    [
                        "stars", "rating", "pick", "reject", "flag", "label", "culling", "mark", "quick collection",
                        "custom label", "auto advance", "undo rating",
                    ],
                ),
                FeedbackFeature(
                    "disk-changes",
                    "Changes on Disk",
                    ["new photos", "deleted", "renamed", "copied", "refresh"],
                ),
            ],
        ),
        FeedbackArea(
            "viewing", "Viewing", symbol: "eye",
            summary: "Zoom, Before / After, clipping, overlays and the display.",
            tracker: ["UX"],
            features: [
                FeedbackFeature("zoom", "Zoom and Pan", ["fit", "fill", "1:1", "2:1", "zoom", "pan", "pinch", "100%"]),
                FeedbackFeature("navigator", "Navigator", ["navigator", "minimap"]),
                FeedbackFeature(
                    "before-after",
                    "Before / After",
                    ["before", "after", "compare", "side by side", "split"],
                ),
                FeedbackFeature(
                    "clipping",
                    "Clipping and Sensor Clipping",
                    ["clipping", "overexposed", "blown", "sensor clipping"],
                ),
                FeedbackFeature("color-assessment", "Color Assessment View", ["assessment", "grey frame", "iso 12646"]),
                FeedbackFeature("info-overlay", "Info Overlay", ["info", "exif overlay"]),
                FeedbackFeature(
                    "lights-out",
                    "Lights Out and Full Screen",
                    ["lights out", "full screen", "presentation"],
                ),
                FeedbackFeature(
                    "display",
                    "Display Colour and HDR",
                    ["hdr", "edr", "display p3", "color management", "monitor"],
                ),
            ],
        ),
        FeedbackArea(
            "export", "Export", symbol: "square.and.arrow.up",
            summary: "The Export dialog: formats, sizes, metadata and presets.",
            tracker: ["EDT"],
            features: [
                FeedbackFeature("dialog", "Export Dialog", ["export", "location", "file name"]),
                FeedbackFeature(
                    "formats", "Formats and Quality",
                    ["jpeg", "jpg", "heic", "avif", "png", "tiff", "quality", "bit depth", "file size"],
                ),
                FeedbackFeature("size", "Size and Resizing", ["resize", "long edge", "megapixels", "dimensions"]),
                FeedbackFeature("metadata", "Metadata", ["exif", "gps", "location", "copyright"]),
                FeedbackFeature(
                    "presets",
                    "Export Presets and Export with Previous",
                    ["preset", "previous", "repeat export"],
                ),
                FeedbackFeature(
                    "looks-different", "Export Looks Different from the Editor",
                    ["colour shift", "different", "mismatch", "darker", "sharper"],
                ),
            ],
        ),
        FeedbackArea(
            "focus-stacking", "Focus Stacking", symbol: "square.stack.3d.up",
            summary: "Stack detection, merging and the Stack workspace.",
            tracker: ["FS"],
            features: [
                FeedbackFeature("detection", "Stack Detection", ["detected", "banner", "focus bracketing"]),
                FeedbackFeature("merging", "Merging", ["auto", "smooth", "detail", "merge", "fusion"]),
                FeedbackFeature(
                    "workspace",
                    "Stack Workspace and Retouch",
                    ["retouch", "paint frame", "leave frames out"],
                ),
                FeedbackFeature("depth-map", "Depth Map", ["depth"]),
                FeedbackFeature("alignment", "Alignment", ["align", "breathing", "ghosting", "halos"]),
            ],
        ),
        FeedbackArea(
            "raw", "Photos & Cameras", symbol: "camera.aperture",
            summary: "Opening photos: camera support, colours on open, and raw artefacts.",
            tracker: ["CAM"],
            features: [
                FeedbackFeature("wont-open", "A Photo Won't Open", ["error", "can't open", "decode", "failed"]),
                FeedbackFeature(
                    "unsupported", "Unsupported Camera or Format",
                    ["camera support", "new camera", "cr3", "nef", "arw", "raf", "dng", "orf", "rw2", "pef"],
                ),
                FeedbackFeature(
                    "colours", "Colours Look Wrong When a Photo Opens",
                    ["color cast", "tint", "as shot", "profile", "magenta", "green"],
                ),
                FeedbackFeature(
                    "demosaic", "Demosaic Artefacts",
                    ["maze", "moire", "moiré", "false color", "zipper", "x-trans", "worms", "artifacts"],
                ),
                FeedbackFeature(
                    "highlights",
                    "Highlights and Clipped Areas",
                    ["highlight reconstruction", "blown", "clipped"],
                ),
                FeedbackFeature(
                    "hot-pixels",
                    "Hot Pixels and Banding",
                    ["hot pixel", "stuck pixel", "banding", "stripes", "lines"],
                ),
                FeedbackFeature(
                    "phone",
                    "Phone DNGs and ProRAW",
                    ["iphone", "proraw", "pixel", "android", "phone", "gain map"],
                ),
                FeedbackFeature("bitmap", "JPEG, HEIC, TIFF and PNG", ["jpeg", "heic", "tiff", "png", "not raw"]),
            ],
        ),
        FeedbackArea(
            "saving", "Saving & Files", symbol: "externaldrive",
            summary: "Saving edits: sidecar files, conflicts, iCloud Drive and other disks.",
            tracker: ["AUD"],
            features: [
                FeedbackFeature(
                    "not-saved",
                    "Edits Not Saved",
                    ["lost edits", "not saved", "save failed", "disappeared"],
                ),
                FeedbackFeature("sidecars", "Sidecar Files", ["redlamp file", "sidecar", ".redlamp"]),
                FeedbackFeature(
                    "read-only",
                    "Read-Only or Conflicting Edits",
                    ["read only", "conflict", "newer version", "other app"],
                ),
                FeedbackFeature(
                    "disks", "iCloud Drive and External or Network Disks",
                    ["icloud", "external disk", "nas", "network", "smb", "usb"],
                ),
            ],
        ),
        FeedbackArea(
            "workspace", "Workspace", symbol: "macwindow",
            summary: "Panels, sliders, shortcuts, the command palette, themes, settings and updates.",
            tracker: ["UX"],
            features: [
                FeedbackFeature(
                    "panels",
                    "Panels and Layout",
                    ["panel", "solo mode", "collapse", "sidebar", "inspector"],
                ),
                FeedbackFeature(
                    "sliders",
                    "Sliders and Value Fields",
                    ["slider", "value", "type a value", "drag", "arithmetic", "scroll"],
                ),
                FeedbackFeature("shortcuts", "Keyboard Shortcuts", ["shortcut", "key", "keyboard", "hotkey"]),
                FeedbackFeature("palette", "Command Palette", ["command k", "palette"]),
                FeedbackFeature("find", "Find Adjustment", ["command f", "search adjustment"]),
                FeedbackFeature("toolbar", "Toolbar", ["toolbar", "top bar"]),
                FeedbackFeature(
                    "themes",
                    "Themes and Appearance",
                    ["theme", "dark mode", "light mode", "tint", "transparency"],
                ),
                FeedbackFeature("settings", "Settings", ["preferences", "settings window"]),
                FeedbackFeature("updates", "Updates", ["update", "sparkle", "check for updates", "version"]),
            ],
        ),
        FeedbackArea(
            "performance", "Performance & Stability", symbol: "gauge.with.dots.needle.67percent",
            summary: "Speed, crashes, freezes, memory and heat.",
            tracker: ["ARC", "AUD"],
            features: [
                FeedbackFeature(
                    "slow-editing",
                    "Slow or Laggy Editing",
                    ["slow", "lag", "laggy", "stutter", "sluggish", "delay"],
                ),
                FeedbackFeature("crash", "Crashes", ["crash", "quit unexpectedly", "closed"]),
                FeedbackFeature(
                    "freeze",
                    "Freezes",
                    ["freeze", "hang", "beach ball", "spinning wheel", "not responding"],
                ),
                FeedbackFeature(
                    "memory",
                    "Memory, Heat and Battery",
                    ["memory", "ram", "hot", "fan", "battery", "energy"],
                ),
                FeedbackFeature("slow-library", "Slow Folders and Thumbnails", ["slow folder", "loading", "scanning"]),
            ],
        ),
        FeedbackArea(
            otherID, "Something Else", symbol: "questionmark.bubble",
            summary: "General feedback, the website and docs, and the command-line tool.",
            tracker: ["EXT"],
            features: [
                FeedbackFeature("general", "General Feedback", ["feedback", "thanks", "idea", "general"]),
                FeedbackFeature("website", "Website and Documentation", ["website", "docs", "readme", "redlamp.app"]),
                FeedbackFeature("cli", "Command-Line Tool", ["cli", "redlamp command", "terminal"]),
                FeedbackFeature("not-sure", "Not Sure", ["unsure", "don't know"]),
            ],
        ),
    ]
}
