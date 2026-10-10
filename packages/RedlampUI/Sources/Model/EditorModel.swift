import CoreGraphics
import Foundation
import Observation
import RedlampCanvas
import RedlampDocument
import RedlampEngineAPI
import RedlampRecipes

/// All editor state. Views read it; only its methods change it.
///
/// Talks to the rendering engine exclusively through `EditingEngine`.
@MainActor
@Observable
public final class EditorModel {
    public let engine: any EditingEngine
    public let canvas = CanvasController()
    /// What happened this session, for feedback reports.
    public let activity = ActivityLog()
    @ObservationIgnored private var activityRecorder: ActivityRecorder?
    @ObservationIgnored private var openStarted: ContinuousClock.Instant?
    @ObservationIgnored private let sidecars = SidecarStore()
    @ObservationIgnored let saves = SaveQueue(store: SidecarStore())

    // MARK: Library

    /// The open folder's photos.
    public let library: FolderLibrary
    public var folder: URL? {
        library.openFolder
    }

    /// Not observed: views observe `library.count` or `library.revision`.
    public var items: [LibraryItem] {
        library.items
    }

    @ObservationIgnored public let thumbnailLoader: ThumbnailLoader
    /// The selected photo's thumbnail, shown while it decodes.
    public internal(set) var selectionThumbnail: CGImage?
    @ObservationIgnored private var selectionThumbnailRequest: UInt64?
    /// Where the selection is in `items`, so a deleted photo's neighbour can take its place.
    @ObservationIgnored var selectionIndex: Int?
    @ObservationIgnored var libraryObservation: LibraryObservation?
    /// Stack suggestions the user dismissed; they don't come back when the folder changes.
    @ObservationIgnored var dismissedStacks: Set<StackSuggestion> = []
    public internal(set) var selection: URL?
    /// The photos selected in the filmstrip, in its order: the open one (`selection`) and any
    /// others ⌘- or ⇧-clicked with it.
    public internal(set) var selectedPhotos: [URL] = []
    /// Focus stacks found in the folder that have no stack document yet.
    public internal(set) var stackSuggestions: [StackSuggestion] = []
    /// The Stack workspace, when open over the editor.
    public var stackWorkspace: StackWorkspaceModel?

    // MARK: Current image

    public private(set) var info: ImageInfo? {
        didSet {
            if info?.url != oldValue?.url {
                pixelReadout = nil
            }
        }
    }

    /// Counts photos opened. The engine analyses whatever photo is open when a request reaches
    /// it, so a result applies only if the visit it started in is still the current one: not
    /// after a switch to another photo, nor after switching back.
    @ObservationIgnored private var visits = 0
    /// The open photo, in this visit of it. Taken before an analysis starts, and compared after.
    /// None while another photo is opening: the engine already has that one.
    var currentVisit: PhotoVisit? {
        guard opening == nil else { return nil }
        return info.map { PhotoVisit(url: $0.url, number: visits) }
    }

    /// A decoded photo the editor changes to once its sidecar is read. Until then the open photo
    /// stays but takes no edits, and nothing renders: the engine already has the new one. Ratings,
    /// flags, labels and moving on go to the new one. Observed: the menus and the palette enable
    /// what `canPerform` allows for it.
    private(set) var opening: URL?
    @ObservationIgnored private var openingKeepsSelection = false
    @ObservationIgnored private var openingFallback: Task<Void, Never>?
    /// Another writer's edit of the open photo that arrived while the next one was opening,
    /// shown if the editor goes back to it.
    @ObservationIgnored private var adoptionWhileOpening: SidecarBase?
    /// How long the open photo stays while the next one's sidecar is read; after it, the next
    /// one's thumbnail shows until the read is done.
    @ObservationIgnored var openingPatience = Duration.milliseconds(100)
    /// How long after a sidecar read that failed it is read again, doubled each time it fails
    /// again; the photo is read-only until it reads.
    @ObservationIgnored var sidecarReadRetryDelay = Duration.seconds(2)
    @ObservationIgnored private var sidecarReadRetry: Task<Void, Never>?
    /// Waited for before each sidecar read (tests hold reads here).
    @ObservationIgnored var beforeReadingSidecar: @Sendable (URL) async -> Void = { _ in }

    public private(set) var isLoading = false
    public internal(set) var errorMessage: String?
    /// The photo is in a format Redlamp doesn't read yet (`EngineError.notSupportedYet`), so its
    /// message asks for the format rather than offering a bug report.
    public internal(set) var formatNotSupportedYet = false
    /// The photo's sidecar was written by a newer Redlamp, or can't be read. What can be read
    /// of its edit is shown, but changes aren't saved: this version would lose what it doesn't
    /// understand.
    public var isReadOnly: Bool {
        readOnlyReason != nil
    }

    public internal(set) var readOnlyReason: SidecarProtection?
    /// Copies of the photo's edit made on another Mac that this build couldn't merge; they stay
    /// on disk, unresolved, for one that can.
    public internal(set) var hasUnmergedEdits = false
    /// The last save that failed, shown until one goes through (see `EditorModel+Saving`).
    public internal(set) var saveError: SaveError?
    /// Each photo's writes that failed, oldest first, until they go through.
    @ObservationIgnored var failedSaves: [URL: FailedSave] = [:]
    @ObservationIgnored var saveRetry: (task: Task<Void, Never>?, delay: Duration) = (nil, .seconds(1))
    /// The open photo's rating, flag and label, saved with its edit.
    public internal(set) var photoMetadata = PhotoMetadata()
    /// What was set of the rating, flag and label while the photo was opening, made again on
    /// its sidecar's when it opens.
    @ObservationIgnored var metadataChangesWhileOpening: [@Sendable (inout PhotoMetadata) -> Void] = []
    /// Reading `recipe` observes every change to it. Views observe only what they show —
    /// `value(_:)` for one parameter, or `masks`, `pointCurve`, … — so a slider drag
    /// re-evaluates a single row rather than every panel.
    public private(set) var recipe: EditRecipe {
        get {
            access(keyPath: \.recipe)
            return storedRecipe
        }
        set {
            guard opening == nil else { return }
            let old = storedRecipe
            withMutation(keyPath: \.recipe) { storedRecipe = newValue }
            for parameter in newValue.parametersChanged(from: old) {
                withMutation(keyPath: \.[observing: parameter]) {}
            }
            if newValue.treatment != old.treatment {
                withMutation(keyPath: \.treatment) {}
            }
            if newValue.baseLook != old.baseLook {
                withMutation(keyPath: \.baseLook) {}
            }
            if newValue.processVersion != old.processVersion {
                withMutation(keyPath: \.processVersion) {}
            }
            if newValue.appliedRecipe != old.appliedRecipe {
                withMutation(keyPath: \.appliedRecipe) {}
            }
            if newValue.whiteBalanceMode != old.whiteBalanceMode {
                withMutation(keyPath: \.whiteBalanceMode) {}
            }
            if newValue.pointCurve != old.pointCurve {
                withMutation(keyPath: \.pointCurve) {}
            }
            if newValue.panelsOff != old.panelsOff {
                withMutation(keyPath: \.panelsOff) {}
            }
            if newValue.pointColor.isEmpty != old.pointColor.isEmpty {
                withMutation(keyPath: \.hasPointColor) {}
            }
            if newValue.masks != old.masks {
                withMutation(keyPath: \.masks) {}
                if newValue.masks.map(MaskOutline.init) != old.masks.map(MaskOutline.init) {
                    withMutation(keyPath: \.maskOutlines) {}
                }
                if Self.shapes(of: newValue) != Self.shapes(of: old) {
                    withMutation(keyPath: \.maskShapes) {}
                }
            }
        }
    }

    @ObservationIgnored private var storedRecipe = EditRecipe()

    /// The edit, read without observing it (for lists that must not reload during drags).
    var unobservedRecipe: EditRecipe {
        storedRecipe
    }

    private subscript(observing parameter: ParameterID) -> Double {
        access(keyPath: \.[observing: parameter])
        return storedRecipe[parameter]
    }

    public var treatment: Treatment {
        access(keyPath: \.treatment)
        return storedRecipe.treatment
    }

    public var processVersion: Int {
        access(keyPath: \.processVersion)
        return storedRecipe.processVersion
    }

    public var baseLook: BaseLookReference {
        access(keyPath: \.baseLook)
        return storedRecipe.baseLook
    }

    public var appliedRecipe: AppliedRecipe? {
        access(keyPath: \.appliedRecipe)
        return storedRecipe.appliedRecipe
    }

    public var whiteBalanceMode: WhiteBalanceMode {
        access(keyPath: \.whiteBalanceMode)
        return storedRecipe.whiteBalanceMode
    }

    public var pointCurve: [CurvePoint] {
        access(keyPath: \.pointCurve)
        return storedRecipe.pointCurve
    }

    public var masks: [MaskLayer] {
        access(keyPath: \.masks)
        return storedRecipe.masks
    }

    /// Whether the edit has Point Color swatches of its own (a mask's aren't counted).
    public var hasPointColor: Bool {
        access(keyPath: \.hasPointColor)
        return !storedRecipe.pointColor.isEmpty
    }

    /// The panels switched off from their headers (UX-30).
    public var panelsOff: Set<SwitchablePanel> {
        access(keyPath: \.panelsOff)
        return storedRecipe.panelsOff
    }

    /// The masks without their adjustment values: views that list masks and components
    /// observe this, so dragging a mask's slider doesn't re-render them.
    public var maskOutlines: [MaskOutline] {
        access(keyPath: \.maskOutlines)
        return storedRecipe.masks.map(MaskOutline.init)
    }

    /// Every mask component's shape, by component: the canvas guides observe this.
    public var maskShapes: [UUID: MaskShape] {
        access(keyPath: \.maskShapes)
        return Self.shapes(of: storedRecipe)
    }

    private static func shapes(of recipe: EditRecipe) -> [UUID: MaskShape] {
        Dictionary(recipe.masks.flatMap(\.components).map { ($0.id, $0.shape) }) { first, _ in first }
    }

    /// Just the tone curve, observing only the parameters that shape it.
    public var toneCurve: EditRecipe {
        var curve = EditRecipe()
        curve.pointCurve = pointCurve
        for parameter in PanelID.toneCurve.parameters {
            curve[parameter] = value(parameter)
        }
        return curve
    }

    /// This session's steps: everything since the photo was opened.
    public internal(set) var history: [HistoryStep] = []
    public internal(set) var historyIndex = 0
    /// The photo's earlier sessions, newest first. They load after the photo opens.
    public internal(set) var earlierSessions: [HistorySession] = []
    public private(set) var snapshots: [Snapshot] = []
    /// Frames go straight to the canvases; views only observe whether there is one.
    @ObservationIgnored public let frames = FrameFeed()
    public private(set) var hasFrame = false
    /// Published at most ~30 times a second: enough for a live readout, while frames
    /// arrive at up to the display rate.
    public private(set) var histogram = Histogram.empty
    public private(set) var lastRenderTime: Duration?

    // MARK: View state

    /// Before / After (`\`), shown in `compareLayout`.
    public var showBefore = false {
        didSet { updateComparison() }
    }

    public var compareLayout = CompareLayout.toggle {
        didSet {
            guard compareLayout != oldValue else { return }
            onCompareLayoutChange?(compareLayout)
            updateComparison()
        }
    }

    /// Where the diagonal split's line sits: 0 top-left, 0.5 through the centre, 1 bottom-right.
    public var splitPosition = 0.5 {
        didSet { canvas.comparison = canvasComparison }
    }

    public var showClipping = false {
        didSet { requestRender() }
    }

    /// Marks photosites the sensor clipped, by channel (darktable's raw overexposed indicator).
    public var showRawClipping = false {
        didSet { requestRender() }
    }

    /// A middle-grey surround and white frame for judging colour (ISO 12646).
    public var colorAssessment = false

    /// What the photo renders as under the pointer, for the histogram's line (UX-32); nil while
    /// the pointer isn't over the photo.
    public internal(set) var pixelReadout: PixelReadout?
    /// The histogram's line shows L*a*b* rather than RGB (Lightroom Classic's Show Lab Color
    /// Values). Kept across launches.
    public var showsLabReadout = UserDefaults.standard.bool(forKey: "app.redlamp.labReadout") {
        didSet { UserDefaults.standard.set(showsLabReadout, forKey: "app.redlamp.labReadout") }
    }

    /// The photo point under the pointer, as the canvas reports it.
    @ObservationIgnored var readoutPoint: CGPoint?
    /// The edit the canvas was last asked to show, which the readout reads.
    @ObservationIgnored var readoutRecipe: EditRecipe?
    @ObservationIgnored var readoutTask: Task<Void, Never>?
    /// The point or the edit changed while a readout was being made.
    @ObservationIgnored var readoutStale = false

    public var eyedropperActive = false {
        didSet {
            if eyedropperActive {
                pointColorEyedropperActive = false
                calibrationTargetActive = false
            }
        }
    }

    /// Point Color's eyedropper: a click on the photo adds a swatch of the colour there. It, the
    /// white balance eyedropper and Calibrate from Target are never on together.
    public var pointColorEyedropperActive = false {
        didSet {
            if pointColorEyedropperActive {
                eyedropperActive = false
                calibrationTargetActive = false
            }
        }
    }

    /// Calibrate from Target (CAM-28): a click on the photo measures a target's grey patch.
    public var calibrationTargetActive = false {
        didSet {
            if calibrationTargetActive {
                eyedropperActive = false
                pointColorEyedropperActive = false
            }
        }
    }

    /// The patch Calibrate from Target measured, while its popover asks for the reference L*.
    public internal(set) var calibrationTarget: CalibrationTarget?

    /// The Point Color swatch the sliders edit (see `selectedPointColorSwatch`).
    public var selectedPointColorSwatchID: UUID? {
        didSet {
            if visualizePointColorRange {
                requestRender()
            }
        }
    }

    /// Point Color's Visualize Range, for the selected swatch.
    public var visualizePointColorRange = false {
        didSet {
            if visualizePointColorRange != oldValue {
                requestRender()
            }
        }
    }

    public var activeTool: EditTool = .edit {
        didSet {
            if activeTool != .masking {
                drawingKind = nil
                edgeBrushTarget = nil
            }
            // Point Color's controls move between the edit's swatches and the mask's.
            if (activeTool == .masking) != (oldValue == .masking) {
                leavePointColor()
                if oldValue == .masking {
                    Task { [weak self] in
                        guard let self, activeTool != .masking else { return }
                        await engine.releaseMaskModels()
                    }
                }
            }
            if activeTool != .heal {
                dustMessage = nil
                pickMessage = nil
                findMessage = nil
                foundThings = []
                if oldValue == .heal {
                    releaseGenerativeFill()
                }
            }
            requestRender()
        }
    }

    /// Crop tool settings: the aspect the crop keeps, and whether it stays inside the photo
    /// (Lightroom's Constrain to Image).
    public var cropAspect: CropAspect = .original
    public var cropAspectLocked = true
    /// The guide drawn in the crop (`O` cycles it, `⇧O` turns it).
    public var cropOverlay: CropOverlay = .thirds
    public var cropOverlayTurns = 0
    /// The next drag in the Crop tool draws a line to level (as ⌘-drag always does).
    public var isStraightening = false
    /// Guided Upright: drags on the canvas draw guides, in the photo's coordinates.
    public var isPlacingGuides = false {
        didSet { requestRender() }
    }

    public internal(set) var uprightGuides: [GuideLine] = []
    public var constrainCropToImage = true {
        didSet {
            guard constrainCropToImage, !oldValue else { return }
            var next = recipe
            constrainCrop(&next)
            commit(next, .crop, "Constrain to Image")
        }
    }

    /// The crop as last drawn, which Angle and Transform changes fit inside the photo again.
    @ObservationIgnored var cropIntent: CropRect = .full

    // MARK: Healing state

    /// The Heal or Clone spot the Healing tool's sliders change.
    public var selectedSpotID: UUID?
    /// What the next spot does, and its settings (what the sliders show with no spot selected).
    public var spotMode: RetouchSpot.Mode = .heal
    /// A picked or found person or object takes its shadow and reflection with it (RM-13). Kept
    /// across launches.
    public var removesShadows = UserDefaults.standard.object(forKey: "app.redlamp.removeShadows") as? Bool ?? true {
        didSet { UserDefaults.standard.set(removesShadows, forKey: "app.redlamp.removeShadows") }
    }

    /// Generative Remove (RM-10): new Remove spots are filled by the generative model, as Lightroom's
    /// Generative AI switch does. Kept across launches.
    public var fillsGeneratively = UserDefaults.standard.bool(forKey: "app.redlamp.generativeRemove") {
        didSet { UserDefaults.standard.set(fillsGeneratively, forKey: "app.redlamp.generativeRemove") }
    }

    /// Whether generative fill can run here, as the Healing tool last asked.
    public internal(set) var generativeAvailability = GenerativeFillAvailability.unavailable("")
    /// Why it may not work here, when this Mac has less memory than the model has been tested on.
    public internal(set) var generativeCaution: String?
    /// The fill being made: its spot, how far along the spots being filled are (0…1), and the work,
    /// to cancel.
    public internal(set) var generating: (spot: UUID, progress: Double)?
    var generatingTask: Task<Void, Never>?
    /// Each spot's fills made this session, the one in the edit among them; the others are kept only
    /// until the photo closes.
    public internal(set) var generatedFills: [UUID: [GeneratedFill]] = [:]
    public internal(set) var generativeMessage: String?
    /// The generative model's download, 0…1, while it runs.
    public internal(set) var generativeDownload: Double?
    public var spotSettings = SpotSettings()
    /// Lightroom's Visualize Spots, while the Healing tool is active.
    public var visualizeSpots = false {
        didSet { requestRender() }
    }

    /// Whether the Healing tool draws its spots, their outlines and pins over the photo (`H`).
    public var showSpots = true

    /// What a click in the Healing tool does.
    public var spotPick: SpotPick = .spot
    public internal(set) var isPickingRegion = false
    /// The outline of each picked person or object's mask, by the mask's hash, once traced
    /// (`traceOutline(of:)`); kept until the photo closes.
    public internal(set) var regionOutlines: [String: [[ImagePoint]]] = [:]
    /// Why the last pick found nothing, shown in the Healing panel.
    public var pickMessage: String?
    public internal(set) var isFindingDust = false
    /// Remove Dust across a selection, while it looks at each photo.
    public internal(set) var dustSearch: SettingsSync.Progress?
    /// What the last Remove Dust found, shown in the Healing panel.
    public var dustMessage: String?
    /// Find (RM-08): what it can look for, what to look for next (everything when nil), the things
    /// it outlined in the open photo, and what the last search came to.
    public internal(set) var thingsToFind: [String] = []
    public var thingToFind: String?
    public internal(set) var foundThings: [FoundThing] = []
    public internal(set) var isFindingThings = false
    public var findMessage: String?

    // MARK: Masking state

    public var selectedMaskID: UUID? {
        didSet {
            // Point Color's eyedropper adds to the mask it was turned on for.
            if selectedMaskID != oldValue, activeTool == .masking {
                pointColorEyedropperActive = false
            }
            requestRender()
        }
    }

    public var selectedComponentID: UUID?
    public var showMaskOverlay = true {
        didSet { requestRender() }
    }

    /// The People picker while it's open (UX-21), the crops of the faces it shows, and the box
    /// of the person under the pointer, which the canvas outlines.
    var peoplePicker: PeoplePicker?
    var peopleCrops: [Int: CGImage] = [:]
    var hoveredPersonBox: ImageRect?
    /// The people found in the photo, which names People components "Person 2".
    var foundPeople: (visit: PhotoVisit, people: [PersonFound])?

    /// Each mask's coverage, small, as the black and white overlay draws it, for the Masks panel's
    /// list (`refreshMaskThumbnails`), and what each was drawn from.
    public internal(set) var maskThumbnails: [UUID: CGImage] = [:]
    var maskThumbnailKeys: [UUID: Int] = [:]
    /// Where each mask's pin goes, found with its thumbnail: the point furthest inside it, in the
    /// photo's coordinates. A mask without one has its pin at its first component's centre.
    public internal(set) var maskPins: [UUID: ImagePoint] = [:]

    /// The mask under the pointer in the Masks panel's list (`MasksPanel`), which the canvas
    /// previews even with the overlay off.
    public var hoveredMaskID: UUID? {
        didSet {
            if hoveredMaskID != oldValue {
                requestRender()
            }
        }
    }

    /// The mask whose pin on the canvas is under the pointer (`MaskOverlayView`), previewed as the
    /// list's are while the pointer isn't over a panel.
    public var hoveredPinMaskID: UUID? {
        didSet {
            if hoveredPinMaskID != oldValue {
                requestRender()
            }
        }
    }

    /// Whether the pointer is over a panel or the toolbar rather than the canvas they float over
    /// (`EditorSplitViewController`). The canvas sees the pointer through them, so a pin beneath
    /// the inspector takes its hover there.
    public internal(set) var pointerOverPanel = false {
        didSet {
            if pointerOverPanel != oldValue, hoveredPinMaskID != nil {
                requestRender()
            }
        }
    }

    /// The component under the pointer in the new Masks panel, whose own coverage the canvas
    /// previews (`componentPreview`).
    public var hoveredComponentID: UUID? {
        didSet {
            if hoveredComponentID != oldValue {
                requestRender()
            }
        }
    }

    /// The mask type armed for drawing on the canvas, if any.
    public internal(set) var drawingKind: MaskKind?
    public internal(set) var drawingOperation: MaskOperation = .add
    /// When set, the drawn shape is added to this mask instead of creating a new one.
    public internal(set) var drawingTarget: UUID?
    /// While brushing: the brush component strokes go into, once the first stroke made it.
    public internal(set) var drawingComponentID: UUID?
    /// Lightroom's A and B brushes and Erase, saved across launches.
    public var brushes = BrushSettingsSet.saved() {
        didSet { brushes.save() }
    }

    public var activeBrush: BrushChoice = .a
    /// The Refine Edge brush, while armed on an AI component: each stroke solves the component's
    /// edge again where it paints.
    public internal(set) var edgeBrushTarget: EdgeBrushTarget?
    /// The Refine Edge brush's size, in the brushes' units (0...100).
    public var edgeBrushSize: Double = 12
    /// Refine Edge strokes painted and not yet solved, the one being painted last; shown on the
    /// canvas until their edge is.
    public internal(set) var edgeBrushStrokes: [EdgeBrushStroke] = []
    /// Whether a Refine Edge stroke is being solved.
    public internal(set) var isSolvingEdges = false
    /// The AI mask being computed, for a progress indicator.
    public internal(set) var aiMaskProgress: MaskKind?
    /// Why the last AI mask couldn't be made, shown in the Masking panel.
    public var maskMessage: String?
    /// The AI mask kinds the engine can make for the open photo.
    public internal(set) var availableAIMaskKinds: Set<MaskKind> = []
    /// The People parts the engine can make for the open photo.
    var offeredPersonParts: Set<PersonPart> = []
    /// A model the chosen mask needs, waiting for the user to agree to download it.
    public internal(set) var pendingModel: (
        model: ModelInfo, kind: MaskKind, part: PersonPart, landscape: LandscapeClass,
    )?
    /// The model being downloaded, 0...1.
    public internal(set) var modelDownloadProgress: Double?
    /// What a click would select while choosing an object (a low-resolution mask).
    public internal(set) var objectPreview: MaskBitmap?
    @ObservationIgnored var objectHoverTask: Task<Void, Never>?
    /// What a drag selects with in an Objects mask.
    public var objectSelection = ObjectSelection.rectangle
    /// Bumped when the user's mask presets change, so menus listing them update.
    var maskPresetsVersion = 0
    public var expandedPanels: Set<PanelID> = [.basic, .toneCurve, .colorMixer]
    public var expandedSidebarSections = Set(SidebarSection.allCases)
    public var soloMode = false
    public var leftPanelVisible = true
    public var rightPanelVisible = true
    public var filmstripVisible = true
    #if DEBUG || REDLAMP_PROFILING
        /// `filmstrip=shown` in a capture script: the floating filmstrip stays up with a photo
        /// selected, as it does while the pointer is over it.
        var keepsFilmstripShown = false
    #endif

    // MARK: Shortcut-driven view state

    /// 0 off, 1 basic, 2 detailed (Lightroom's `I`).
    public var infoOverlay = 0
    /// 0 normal, 1 dimmed, 2 off (Lightroom's `L`).
    public var lightsOut = 0
    public internal(set) var isPresenting = false
    @ObservationIgnored var visibilityBeforePresenting: (left: Bool, right: Bool, filmstrip: Bool)?
    /// The slider `,` `.` select and `-` `=` nudge; highlighted in the panels.
    public var focusedParameter: ParameterID?
    public var revealedParameter: ParameterID?
    /// The command palette (⌘K, or ⌘F for sliders), while it's open.
    var presentedPalette: CommandPaletteModel?
    /// Everything the command palette does, for the harness's log and the tests.
    @ObservationIgnored @_spi(Harness) public var onCommandPaletteEvent: ((PaletteEvent) -> Void)?
    /// Holding Option turns group titles into "Reset …" buttons, as in Lightroom.
    public var optionKeyHeld = false
    /// Space held while a tool draws over the canvas: a drag pans the photo and a click zooms, as in
    /// Lightroom's brush tools.
    public internal(set) var isSpacePanning = false
    /// The photo was clicked or dragged while Space was held, so letting go doesn't toggle the zoom.
    var spacePanUsed = false
    public var showMaskPins = true
    public var maskOverlayColor: MaskOverlayColor = .red {
        didSet { requestRender() }
    }

    public var maskOverlayStyle: MaskOverlayStyle = .colorOverlay {
        didSet { requestRender() }
    }

    /// How strongly the overlay tints the mask in the Color Overlay modes, 0...1.
    public var maskOverlayOpacity = MaskOverlayStyle.defaultOpacity {
        didSet { requestRender() }
    }

    /// Luminance Range's "Show Luminance Map": the photo's lightness in grey, the range tinted.
    public var showLuminanceMap = false {
        didSet { requestRender() }
    }

    public var showShortcuts = false
    /// The photo viewed before the current one, for Paste from Previous.
    public internal(set) var previousSelection: URL?
    /// Window-level effects the app layer performs (full screen, toolbar visibility).
    @ObservationIgnored public var onToggleFullScreen: (() -> Void)?
    @ObservationIgnored public var onToggleToolbar: (() -> Void)?
    /// Opens the Camera Bench window (CAM-15), which the app owns.
    @ObservationIgnored public var onTestCamera: (() -> Void)?
    /// Opens Report a Bug or Send Feedback; the app presents it (`FeedbackActions`).
    @ObservationIgnored public var onSendFeedback: ((FeedbackPrefill?) -> Void)?

    /// Every recipe and Base Look on this machine.
    public let recipes: RecipeCatalog
    /// Each camera's exposure anchor for Redlamp Reproduction (`EditorModel+Reproduction`).
    public let cameras: CameraCalibrations
    /// Why the last calibration couldn't be kept or forgotten, shown under the Base Look.
    public internal(set) var calibrationMessage: String?
    /// The recipe under the pointer, rendered without being applied.
    public internal(set) var previewingRecipe: Recipe?
    /// An edit rendered in place of the photo's without being applied: the command
    /// palette's white balance, treatment, snapshot and history previews.
    public internal(set) var previewingEdit: EditRecipe?
    /// The last applied recipe and the edit it was applied to, so its Amount stays adjustable.
    var recipeApplication: (recipe: Recipe, base: EditRecipe)?
    /// The photo's auto white balance, for recipes that ask for it.
    @ObservationIgnored var autoWhiteBalance: WhiteBalanceValue?
    public internal(set) var hasClipboard = false
    /// Sync, and Paste or Update AI Masks on the selection's other photos, in the background.
    public let settingsSync = SettingsSync { nil }
    /// Makes an engine for photos that aren't open (the worker's), when it needs one. Set by the
    /// app; without it, AI masks pasted onto those photos keep the bitmaps they came with.
    @ObservationIgnored public var makeWorkerEngine: (() -> (any EditingEngine)?)?
    /// The Copy Settings checklist, while it is open.
    public var settingsChooser: SettingsChooser?
    /// What the checklist ticked last time (the first time, `SettingsSelection.default`).
    public internal(set) var copySelection = SettingsSelection.saved() {
        didSet { copySelection.save() }
    }

    /// An app-modal dialog (Export) is open: every action is unavailable, so menus, keys and
    /// the palette can't change the photo behind it.
    public internal(set) var isModalDialogOpen = false
    /// What a background export is doing ("Exporting…", then "Exported…" for a moment).
    public internal(set) var exportStatus: String?
    @ObservationIgnored var exportStatusTask: Task<Void, Never>?

    /// Called when the folder changes, so the app can remember it.
    @ObservationIgnored public var onFolderChange: ((URL) -> Void)?
    /// Called when the Before / After layout changes, so the app can remember it.
    @ObservationIgnored public var onCompareLayoutChange: ((CompareLayout) -> Void)?

    @ObservationIgnored private var temporaryClipping = false
    @ObservationIgnored var clipboard: CopiedSettings?
    @ObservationIgnored var pendingDrawingName: String?
    @ObservationIgnored var pendingDrawingKind: MaskKind?
    @ObservationIgnored var editStart: EditRecipe?
    @ObservationIgnored var editParameter: ParameterID?
    /// The `=` / `-` presses on one slider since their last pause (EditorModel+Shortcuts).
    @ObservationIgnored var nudgeRun: NudgeRun?
    @ObservationIgnored private var session = (id: UUID(), started: Date())
    /// The next save removes the earlier sessions' files (Clear History).
    @ObservationIgnored var clearsSavedHistory = false
    /// Earlier sessions of the open photo whose saves haven't gone through, in each of its saves.
    @ObservationIgnored var unsavedSessions: [HistorySession] = []
    @ObservationIgnored var historyTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    /// Canvas geometry for a photo whose first frame hasn't arrived yet. Until it does, the
    /// previous photo stays on screen rather than flashing the placeholder in between.
    @ObservationIgnored private var pendingCanvas: (imageSize: PixelSize, firstGeneration: UInt64)?
    /// The size and part of the photo the last render asked for.
    @ObservationIgnored private var requestedTarget: CanvasController.RenderTarget?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var unsavedSince: ContinuousClock.Instant?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var framesTask: Task<Void, Never>?

    public init(
        engine: any EditingEngine, recipes: RecipeCatalog? = nil, library: FolderLibrary? = nil,
        thumbnailLoader: ThumbnailLoader? = nil, cameras: CameraCalibrations? = nil,
    ) {
        self.engine = engine
        self.recipes = recipes ?? RecipeCatalog(engine: engine)
        self.cameras = cameras ?? CameraCalibrations()
        self.library = library ?? FolderLibrary()
        self
            .thumbnailLoader = thumbnailLoader ??
            ThumbnailLoader(scheduler: self.library.scheduler) { [engine] url, size in
                engine.decodeThumbnail(for: url, maxPixelSize: size)
            }
        canvas.onRenderSizeChange = { [weak self] _ in self?.requestRender() }
        settingsSync.makeEngine = { [weak self] in self?.makeWorkerEngine?() }
        settingsSync.photoAnchor = { [weak self] url in await self?.anchor(forPhotoAt: url) }
        settingsSync.saves = saves
        settingsSync.editor = self
        saves.reportResults { [weak self] url, write, outcome, superseded in
            self?.saved(url, write, outcome, superseded: superseded)
        }
        followLibrary()
        let frames = engine.frames()
        framesTask = Task { [weak self] in
            for await frame in frames {
                self?.receive(frame)
            }
        }
        activityRecorder = ActivityRecorder(model: self)
    }

    // MARK: - Opening a photo (folders: EditorModel+Library)

    /// Opens `url`. Unless `keepingSelection`, it becomes the only photo selected.
    public func select(_ url: URL, keepingSelection: Bool = false) {
        if url == selection, opening != nil, engine.openIfReady(url) != nil {
            // Back before the next photo was read: the open one stays as it was, in a new visit,
            // since what was started on it may have read the other photo meanwhile.
            let adoption = adoptionWhileOpening
            stopOpening()
            visits += 1
            metadataChangesWhileOpening = []
            if !keepingSelection {
                selectedPhotos = [url]
            }
            requestRender()
            if let adoption {
                adopt(adoption, for: url)
            }
            return
        }
        guard url != opening ?? selection else {
            if !keepingSelection {
                if opening == nil {
                    selectedPhotos = [url]
                } else {
                    openingKeepsSelection = false
                }
            }
            return
        }
        endNudgeRun()
        saveNow()
        stopOpening()
        metadataChangesWhileOpening = []
        openStarted = .now
        // Made again before the photo is read, over the base its saves were tracking, so what
        // another writer saved meanwhile is merged, and the read shows the result.
        retry(url)
        engine.prefetch(workingSet(around: url, comingFrom: selection))
        // The sidecar is read off the main thread even for a photo already decoded: it is
        // coordinated, and iCloud Drive may have to download it first. It waits for the
        // photo's saves still on their way, so a photo opened again reads what was left, and for
        // a Settings Sync save of it.
        let readSidecar = { [sidecars, saves, settingsSync, scheduler = library.scheduler, beforeReadingSidecar] in
            await beforeReadingSidecar(url)
            await saves.wait(for: url)
            await settingsSync.wait(for: url)
            return try? await scheduler.run(.onScreen) { OpenedSidecar(url, in: sidecars) }
        }
        if let opened = engine.openIfReady(url) {
            // The editor changes over in one turn once the sidecar is read, never showing no
            // photo, unless the read takes longer than `openingPatience`.
            opening = url
            openingKeepsSelection = keepingSelection
            openTask = Task {
                let read = await readSidecar()
                guard !Task.isCancelled else { return }
                if opening == url {
                    changeOver(to: url, ready: true)
                } else {
                    guard selection == url, info == nil else { return }
                }
                didOpen(opened, read ?? .notRead)
            }
            openingFallback = Task { [openingPatience] in
                try? await Task.sleep(for: openingPatience)
                guard opening == url, !Task.isCancelled else { return }
                changeOver(to: url, ready: false)
            }
            return
        }
        leave(for: url, keepingSelection: keepingSelection, ready: false)
        showPlaceholder(for: url)
        openTask = Task { [engine] in
            let loading = Task { await readSidecar() }
            do {
                let opened = try await engine.open(url)
                let read = await loading.value
                guard selection == url else { return }
                didOpen(opened, read ?? .notRead)
            } catch is CancellationError {
                return
            } catch {
                guard selection == url else { return }
                isLoading = false
                activity.record(.photo, "\(activity.alias(for: url)) (\(url.pathExtension.uppercased())) didn't open")
                errorMessage = error.localizedDescription
                formatNotSupportedYet = (error as? EngineError)?.notSupportedYetTracker != nil
            }
        }
    }

    /// Whether `url` is open in the editor, or opening there.
    func isOpen(_ url: URL) -> Bool {
        opening == url || selection == url && (info != nil || isLoading)
    }

    /// Returns once `url`, opening in the editor, has opened or stopped opening.
    func finishOpening(_ url: URL) async {
        var waited: Task<Void, Never>?
        while isOpen(url), currentVisit?.url != url, let task = openTask, task != waited {
            waited = task
            await task.value
        }
    }

    private func stopOpening() {
        openTask?.cancel()
        openingFallback?.cancel()
        opening = nil
        adoptionWhileOpening = nil
    }

    /// Ends the wait for `url`'s sidecar: the editor changes to it, or (not `ready`) to its
    /// thumbnail until the read is done.
    private func changeOver(to url: URL, ready: Bool) {
        openingFallback?.cancel()
        opening = nil
        adoptionWhileOpening = nil
        leave(for: url, keepingSelection: openingKeepsSelection, ready: ready)
        if ready {
            selectionThumbnailRequest.map(thumbnailLoader.cancel)
            selectionThumbnail = nil
        } else {
            showPlaceholder(for: url)
        }
    }

    private func showPlaceholder(for url: URL) {
        showFrame(nil)
        pendingCanvas = nil
        latestFrame = nil
        histogram = .empty
        isLoading = true
        showThumbnail(of: url)
    }

    /// Moves the selection to `url`, putting away what belonged to the photo left (saved by
    /// then). Unless `url` is `ready` to show now, no photo is open until it is.
    private func leave(for url: URL, keepingSelection: Bool, ready: Bool) {
        if !keepingSelection {
            selectedPhotos = [url]
        }
        sidecarReadRetry?.cancel()
        unsavedSessions = []
        if let error = saveError, failedSaves[error.url] == nil, error.url != url {
            // A Start Over that failed, which no save tries again.
            saveError = failedSaves.values.first?.error
        }
        if let selection {
            saves.enqueue(.forget, for: selection)
            if selection != url {
                previousSelection = selection
            }
        }
        selection = url
        visits += 1
        selectionIndex = library.index(of: url)
        library.remember(url)
        // Cleared first so the resets below don't render the outgoing photo.
        if !ready {
            info = nil
        }
        errorMessage = nil
        formatNotSupportedYet = false
        readOnlyReason = nil
        hasUnmergedEdits = false
        photoMetadata = library.item(for: url)?.metadata ?? PhotoMetadata()
        endEyedroppers()
        previewingRecipe = nil
        previewingEdit = nil
        // A tuple: assigning nil notifies even when it is nil already.
        if recipeApplication != nil {
            recipeApplication = nil
        }
        autoWhiteBalance = nil
        selectedMaskID = nil
        selectedComponentID = nil
        drawingKind = nil
        edgeBrushTarget = nil
        edgeBrushStrokes = []
        pendingModel = nil
    }

    /// Shows the photo's thumbnail on the canvas until its first frame arrives.
    private func showThumbnail(of url: URL) {
        selectionThumbnailRequest.map(thumbnailLoader.cancel)
        selectionThumbnail = nil
        selectionThumbnailRequest = thumbnailLoader.request(library.item(for: url) ?? LibraryItem(url: url)) {
            [weak self] image in
            guard let self, selection == url else { return }
            selectionThumbnail = image
        }
    }

    /// A photo's sidecar as read when it opens.
    private struct OpenedSidecar: Sendable {
        var sidecar: Sidecar?
        /// What the photo's saves go over (nil: the sidecar as it is when the photo opens).
        var base: SidecarBase?
        /// Shown, but never saved over.
        var protection: SidecarProtection?
        /// It couldn't be read, so it is read again (`protection` is `.unreadable`).
        var failed = false
        var hasUnmergedConflicts = false

        /// Read without an answer: never taken for a photo with no edit.
        static let notRead = OpenedSidecar(protection: .unreadable, failed: true)

        init(
            sidecar: Sidecar? = nil,
            base: SidecarBase? = nil,
            protection: SidecarProtection? = nil,
            failed: Bool = false,
        ) {
            self.sidecar = sidecar
            self.base = base
            self.protection = protection
            self.failed = failed
        }

        init(_ url: URL, in sidecars: SidecarStore) {
            let read = sidecars.readForEditing(for: url)
            self.init(sidecar: read.sidecar, base: read.base, protection: read.protection, failed: read.failed)
            hasUnmergedConflicts = sidecars.hasUnmergedConflicts(for: url)
        }
    }

    /// Reads again the sidecar of `url`, open read-only because its read failed, and opens it
    /// again with what it reads, in a new visit, until it reads or another photo opens. Not while
    /// the next photo is being read or during a drag: it tries again after `delay`.
    private func readSidecarAgain(_ url: URL, after delay: Duration) {
        sidecarReadRetry?.cancel()
        sidecarReadRetry = Task { [sidecars, scheduler = library.scheduler] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let read = try? await scheduler.run(.onScreen) { OpenedSidecar(url, in: sidecars) }
            guard !Task.isCancelled, let info, info.url == url, selection == url else { return }
            guard let read, !read.failed else { return readSidecarAgain(url, after: min(delay * 2, .seconds(60))) }
            guard opening == nil, editStart == nil else { return readSidecarAgain(url, after: delay) }
            sidecarReadRetry = nil
            // What was started on it while it was read-only is for the visit it was started in.
            leave(for: url, keepingSelection: true, ready: true)
            didOpen(info, read, keepingView: true)
            if failedSaves[url] != nil {
                retry(url)
            }
        }
    }

    /// The open photo's edit is damaged, and Start Over can set it aside for a new one.
    public var canStartOver: Bool {
        readOnlyReason == .damaged && opening == nil && info?.url == selection
    }

    /// Sets the open photo's damaged edit aside in its sidecar (`edit.damaged-<date>.json`, for
    /// recovery) and opens it again with no edit, in a new visit; or, when its edit is no longer
    /// damaged, opens it again as it now is.
    public func startOver() {
        guard canStartOver, let url = selection else { return }
        let visit = visits
        Task { [sidecars, scheduler = library.scheduler] in
            let result: Result<(URL?, OpenedSidecar), any Error>
            do {
                result = try await .success(scheduler.run(.onScreen) {
                    let copy = try sidecars.setAsideDamagedEdit(for: url)
                    return (copy, OpenedSidecar(url, in: sidecars))
                })
            } catch {
                result = .failure(error)
            }
            guard visits == visit, let info, info.url == url, selection == url, opening == nil else { return }
            switch result {
            case let .success((copy, read)):
                if let copy {
                    activity.record(
                        .photo,
                        "Started over on \(activity.alias(for: url)), its damaged edit kept as \(copy.lastPathComponent)",
                    )
                }
                leave(for: url, keepingSelection: true, ready: true)
                didOpen(info, read, keepingView: true)
            case let .failure(error):
                startOverFailed(url, error)
            }
        }
    }

    /// "Opened Photo A: CR3, Canon EOS R5, 8192 × 5464, with an edit, in 1.2 s".
    private func recordOpening(_ opened: ImageInfo, edited: Bool) {
        var parts = [opened.url.pathExtension.uppercased()]
        parts += [opened.cameraName].compactMap(\.self)
        parts.append("\(opened.pixelSize.width) × \(opened.pixelSize.height)")
        parts.append(edited ? "with an edit" : "unedited")
        if let openStarted {
            parts.append(String(format: "in %.1f s", (ContinuousClock.now - openStarted) / .seconds(1)))
        }
        activity.record(.photo, "Opened \(activity.alias(for: opened.url)): \(parts.joined(separator: ", "))")
    }

    /// `keepingView`: the photo is on screen already, and keeps its zoom unless its frame size changes.
    private func didOpen(_ opened: ImageInfo, _ read: OpenedSidecar, keepingView: Bool = false) {
        // Writes that failed again as it opened are shown; its saves go on over the base they
        // were tracking, so the next one still merges what another writer saved.
        let unsaved = read.protection == nil ? failedSaves[opened.url]?.writes ?? [] : []
        let sidecar = Self.applying(unsaved, to: read.sidecar)
        unsavedSessions = Self.sessions(in: unsaved)
        info = opened
        recordOpening(opened, edited: sidecar != nil)
        availableAIMaskKinds = []
        Task { await refreshAvailableMasks() }
        maskMessage = nil
        readOnlyReason = read.protection
        hasUnmergedEdits = read.hasUnmergedConflicts
        var metadata = sidecar?.metadata ?? PhotoMetadata()
        if read.protection == nil {
            metadataChangesWhileOpening.forEach { $0(&metadata) }
        }
        // A change made after the file was read isn't in it yet: saving once open puts it there.
        let savesMetadata = !metadataChangesWhileOpening.isEmpty && read.protection == nil
        if !metadataChangesWhileOpening.isEmpty {
            library.update(opened.url) { $0.metadata = metadata }
            metadataChangesWhileOpening = []
        }
        photoMetadata = metadata
        let loaded = Self.asShot(sidecar?.recipe ?? EditRecipe(), opened)
        recipe = loaded
        snapshots = sidecar?.snapshots ?? []
        startSession(opening: opened.url, recipe: loaded, hasSidecar: sidecar != nil)
        isLoading = false
        cropIntent = loaded.crop
        uprightGuides = []
        foundThings = []
        cancelGenerativeFill()
        generatedFills = [:]
        regionOutlines = [:]
        isPlacingGuides = false
        let frameSize = loaded.developedSize(imageSize: opened.pixelSize)
        if !hasFrame {
            showOnCanvas(frameSize)
        } else if !keepingView || frameSize != canvas.imageSize {
            pendingCanvas = (frameSize, generation &+ 1)
        }
        requestRender()
        if read.protection == nil {
            saves.enqueue(.track(read.base, opened: sidecarToSave), for: opened.url)
        }
        if savesMetadata {
            saveNow()
        }
        if read.failed {
            readSidecarAgain(opened.url, after: sidecarReadRetryDelay)
        }
    }

    /// Shows the open photo as another writer left it, or as merged with them. Not during a drag
    /// or with a change still to save: that save merges again, and this comes back then.
    func adopt(_ base: SidecarBase, for url: URL) {
        guard url == selection, opening == nil else {
            if url == selection {
                adoptionWhileOpening = base
            }
            return
        }
        guard showOtherWriters(base.sidecar ?? Sidecar(recipe: EditRecipe())) else { return }
        saves.enqueue(.track(base, opened: sidecarToSave), for: url)
    }

    /// Shows `theirs`, another writer's edit or the merge with it, in the open photo. Not during
    /// a drag or with a change still to save: that save merges again, and this comes back then.
    @discardableResult
    func showOtherWriters(_ theirs: Sidecar) -> Bool {
        guard let info, !isReadOnly, editStart == nil, !hasUnsavedChange else { return false }
        let previous = recipe
        recipe = Self.asShot(theirs.recipe, info)
        snapshots = theirs.snapshots
        photoMetadata = theirs.metadata ?? PhotoMetadata()
        cropIntent = recipe.crop
        if recipe != previous {
            // As a paste, Auto Sync doesn't send it on to the rest of the selection.
            recordHistory(.paste, "Edit from Another Mac", from: previous)
            requestRender()
        }
        return true
    }

    /// The history sessions `writes` would save, each once, as last written; no more than a
    /// sidecar keeps beside the open session.
    static func sessions(in writes: [SaveQueue.Write]) -> [HistorySession] {
        var sessions: [HistorySession] = []
        for case let .sidecar(sidecar) in writes {
            for session in sidecar.unsavedSessions + [sidecar.session].compactMap(\.self) where session.hasEdits {
                sessions.removeAll { $0.id == session.id }
                sessions.append(session)
            }
        }
        return Array(sessions.sorted { $0.started < $1.started }.suffix(SidecarStore.keptSessions - 1))
    }

    /// `sidecar` as it is once `writes` have been made to it.
    private static func applying(_ writes: [SaveQueue.Write], to sidecar: Sidecar?) -> Sidecar? {
        writes.reduce(sidecar) { sidecar, write in
            switch write {
            case let .sidecar(saved):
                return saved
            case let .metadata(change):
                var changed = sidecar ?? Sidecar(recipe: EditRecipe())
                var metadata = changed.metadata ?? PhotoMetadata()
                change(&metadata)
                changed.metadata = metadata.isEmpty ? nil : metadata
                return changed
            case .track, .forget:
                return sidecar
            }
        }
    }

    /// `recipe` with the photo's own white balance when it is As Shot.
    static func asShot(_ recipe: EditRecipe, _ info: ImageInfo) -> EditRecipe {
        var recipe = recipe
        if recipe.whiteBalanceMode == .asShot, let wb = info.asShotWhiteBalance {
            recipe[.temperature] = wb.temperature
            recipe[.tint] = wb.tint
        }
        return recipe
    }

    private func showOnCanvas(_ imageSize: PixelSize) {
        canvas.zoom = .fit
        canvas.center = CGPoint(x: 0.5, y: 0.5)
        canvas.imageSize = imageSize
    }

    // MARK: - Rendering

    private var beforeRecipe: EditRecipe {
        var before = EditRecipe()
        if let wb = info?.asShotWhiteBalance {
            before[.temperature] = wb.temperature
            before[.tint] = wb.tint
        }
        return before
    }

    public func requestRender() {
        guard let info, opening == nil else { return }
        var displayed = isShowingOriginal
            ? beforeRecipe.withGeometry(of: recipe)
            : (previewingEdit ?? previewingRecipe.map { previewEdit(for: $0) } ?? recipe)
        // The crop tool shows the whole straightened frame, with the crop drawn over it.
        if activeTool == .crop {
            displayed.crop = .full
        }
        // A new frame size shows once a frame of that size arrives.
        let frameSize = displayed.developedSize(imageSize: info.pixelSize)
        if pendingCanvas == nil, frameSize != canvas.imageSize, canvas.imageSize.width > 0 {
            pendingCanvas = (frameSize, generation &+ 1)
        }
        let target = pendingCanvas.map { CanvasController.RenderTarget(size: canvas.fitRenderSize(for: $0.imageSize)) }
            ?? (editStart != nil ? canvas.editRenderTarget() : canvas.renderTarget)
        guard target.size.width > 0 else { return }
        requestedTarget = target
        generation &+= 1
        debugRequestTimes.append((generation, .now))
        if debugRequestTimes.count > 64 {
            debugRequestTimes.removeFirst(32)
        }
        var overlay = maskOverlayShown
        var shown = displayed
        if let preview = componentPreview(in: displayed) {
            shown.masks.append(preview)
            overlay = preview.id
        }
        var request = RenderRequest(
            recipe: shown,
            targetSize: target.size,
            region: target.region,
            showClipping: showClipping || temporaryClipping,
            maskOverlay: overlay,
            generation: generation,
        )
        request.maskOverlayColor = maskOverlayColor
        request.maskOverlayStyle = showLuminanceMap && overlay != nil ? .luminanceMap : maskOverlayStyle
        request.maskOverlayOpacity = maskOverlayOpacity
        request.showRawClipping = showRawClipping
        request.visualizeSpots = activeTool == .heal && visualizeSpots ? spotSettings.visualize : nil
        request.visualizePointColor = visualizePointColorRange ? selectedPointColorSwatch?.id : nil
        request.comparison = isComparing ? beforeRecipe : nil
        engine.render(request)
        readoutRecipe = displayed
        refreshReadout()
    }

    /// Frames received from the engine, the latest ones' render times, and the time from each
    /// one's request to its arrival here (for performance diagnostics).
    @ObservationIgnored public private(set) var debugFrameCount = 0
    @ObservationIgnored public private(set) var debugRenderDurations: [Duration] = []
    @ObservationIgnored public private(set) var debugFrameLatencies: [Duration] = []
    @ObservationIgnored private var debugRequestTimes: [(generation: UInt64, at: ContinuousClock.Instant)] = []

    private func receive(_ frame: RenderedFrame) {
        guard info != nil else { return }
        if let pending = pendingCanvas {
            guard frame.generation >= pending.firstGeneration else { return }
            pendingCanvas = nil
            showOnCanvas(pending.imageSize)
        }
        debugFrameCount += 1
        debugRenderDurations.append(frame.renderDuration)
        if debugRenderDurations.count > 4000 {
            debugRenderDurations.removeFirst(2000)
        }
        if let index = debugRequestTimes.firstIndex(where: { $0.generation == frame.generation }) {
            debugFrameLatencies.append(.now - debugRequestTimes[index].at)
            debugRequestTimes.removeFirst(index + 1)
            if debugFrameLatencies.count > 4000 {
                debugFrameLatencies.removeFirst(2000)
            }
        }
        showFrame(frame)
        latestFrame = frame
        guard statsTask == nil else { return }
        let wait = lastStatsUpdate + .milliseconds(33) - .now
        statsTask = Task { [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            guard let self else { return }
            statsTask = nil
            guard let latest = latestFrame else { return }
            lastStatsUpdate = .now
            histogram = latest.histogram
            // A readout people can actually read; faster only re-renders its glass capsule.
            if lastRenderTimeUpdate.duration(to: .now) > .milliseconds(250) {
                lastRenderTimeUpdate = .now
                lastRenderTime = latest.renderDuration
            }
        }
    }

    private func showFrame(_ frame: RenderedFrame?) {
        frames.show(frame)
        if hasFrame != (frame != nil) {
            hasFrame = frame != nil
        }
    }

    @ObservationIgnored private var latestFrame: RenderedFrame?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var lastStatsUpdate = ContinuousClock.now
    @ObservationIgnored private var lastRenderTimeUpdate = ContinuousClock.now

    // MARK: - The window

    @ObservationIgnored private var windowIsOpen = true
    @ObservationIgnored private var released = false
    @ObservationIgnored private var windowChange: Task<Void, Never>?

    /// The editor window closed: once the photo opening has opened, its edit is saved, and the
    /// engine and the canvas let go of every photo.
    public func windowClosed() {
        windowIsOpen = false
        let previous = windowChange
        windowChange = Task { [weak self] in
            await previous?.value
            if let url = self?.selection {
                await self?.finishOpening(url)
            }
            guard let self, !windowIsOpen else { return }
            saveNow()
            latestFrame = nil
            showFrame(nil)
            await engine.releaseResources()
            released = true
            // A frame rendered before the engine let go.
            latestFrame = nil
            showFrame(nil)
        }
    }

    /// The editor window is back: the photo it showed is decoded and rendered again.
    public func windowReopened() {
        windowIsOpen = true
        let previous = windowChange
        windowChange = Task { [weak self] in
            await previous?.value
            guard let self, released, let url = selection, info != nil else { return }
            released = false
            engine.prefetch(workingSet(around: url, comingFrom: nil))
            guard await (try? engine.open(url)) != nil, selection == url else { return }
            requestRender()
        }
    }

    // MARK: - Parameters

    public func value(_ parameter: ParameterID) -> Double {
        self[observing: parameter]
    }

    public func isEdited(_ parameter: ParameterID) -> Bool {
        if parameter == .temperature || parameter == .tint {
            return whiteBalanceMode != .asShot
        }
        return abs(self[observing: parameter] - parameter.spec.defaultValue) > 1e-9
    }

    /// The mask the canvas overlays: the selected one in the Masking tool, except while one of
    /// its adjustments is being dragged, so the edit itself shows (Lightroom's automatic overlay
    /// toggle), and while a tool is armed for a new mask, so what it selects shows alone. Sliders
    /// that shape the mask (Feather, Detail, Refine) keep it. The mask under the pointer in the
    /// list, or on its pin with the pointer over the canvas, shows instead, overlay on or off.
    public var maskOverlayShown: UUID? {
        guard activeTool == .masking, !isShowingOriginal, !isAdjustingMask else { return nil }
        if let hovered = hoveredMaskID ?? (pointerOverPanel ? nil : hoveredPinMaskID) {
            return hovered
        }
        return showMaskOverlay && !isArmedForNewMask ? selectedMaskID : nil
    }

    /// Whether a mask's adjustment or Amount is being dragged.
    var isAdjustingMask: Bool {
        guard editStart != nil, let editParameter else { return false }
        return editParameter.isLocal || editParameter == .maskAmount
    }

    /// Starts a continuous edit (a slider drag); history records one step when it ends.
    public func beginEdit(_ parameter: ParameterID? = nil) {
        editStart = recipe
        editParameter = parameter
        if isAdjustingMask, activeTool == .masking, showMaskOverlay {
            requestRender()
        }
    }

    public func setValue(_ parameter: ParameterID, _ value: Double) {
        var next = recipe
        next[parameter] = parameter.spec.quantize(value)
        if EditRecipe.geometryParameters.contains(parameter) {
            constrainCrop(&next)
        }
        if parameter == .temperature || parameter == .tint {
            next.whiteBalanceMode = matchesAsShot(next) ? .asShot : .custom
        }
        guard next != recipe else { return }
        let previous = recipe
        recipe = next
        requestRender()
        scheduleSave()
        if editStart == nil {
            recordStep(for: parameter, from: previous)
        }
    }

    /// Ends a drag as one step, named for the slider it began on (see `beginEdit`) or `name`.
    public func endEdit(name: String? = nil) {
        if let name {
            endEdit(.edit, name)
        } else {
            finishEdit { [self] start in
                if let editParameter {
                    recordStep(for: editParameter, from: start)
                } else {
                    recordHistory(.edit, "Edit", from: start)
                }
            }
        }
    }

    /// Ends a drag as one step. `value` reads the value it changed, to show it before and after.
    func endEdit(_ action: HistoryAction, _ title: String, value: ((EditRecipe) -> String)? = nil) {
        finishEdit { [self] start in recordHistory(action, title, from: start, value: value) }
    }

    private func finishEdit(_ record: (EditRecipe) -> Void) {
        let adjustingMask = isAdjustingMask
        defer {
            editStart = nil
            editParameter = nil
            // The overlay comes back once the drag ends, and so does the margin around the
            // visible part, so panning afterwards doesn't render.
            if adjustingMask, activeTool == .masking, showMaskOverlay {
                requestRender()
            } else if pendingCanvas == nil, requestedTarget != nil, requestedTarget != canvas.renderTarget {
                requestRender()
            }
        }
        guard let start = editStart, start != recipe else { return }
        record(start)
    }

    public func reset(_ parameter: ParameterID) {
        resetParameters([parameter], name: "Reset \(parameter.displayName)")
    }

    public func resetParameters(_ parameters: [ParameterID], name: String) {
        if parameters.first?.isPointColorScoped == true {
            resetPointColorValues(parameters, name: name)
            return
        }
        var next = recipe
        next.reset(parameters.filter { $0 != .temperature && $0 != .tint })
        if parameters.contains(.temperature) || parameters.contains(.tint) {
            next.whiteBalanceMode = .asShot
            if let wb = info?.asShotWhiteBalance {
                next[.temperature] = wb.temperature
                next[.tint] = wb.tint
            }
        }
        if parameters.count == 1, let parameter = parameters.first {
            commit(next, .reset, name) { parameter.spec.formatted($0[parameter]) }
        } else {
            commit(next, .reset, name)
        }
    }

    public func resetAll() {
        commit(beforeRecipe, .reset, "Reset")
    }

    /// Alt-drag on tone sliders previews clipping, like Lightroom.
    public func setTemporaryClipping(_ on: Bool) {
        guard temporaryClipping != on else { return }
        temporaryClipping = on
        requestRender()
    }

    // MARK: - Base Look, treatment, white balance

    /// Moves the edit to another process version, Lightroom's Process: always an explicit,
    /// undoable choice, since it changes how the photo renders.
    public func setProcessVersion(_ version: Int) {
        let version = min(max(version, 1), EditRecipe.currentProcessVersion)
        guard version != recipe.processVersion else { return }
        var next = recipe
        next.processVersion = version
        constrainCrop(&next)
        commit(next, .edit, "Process Version") { "Version \($0.processVersion)" }
    }

    public func setTreatment(_ treatment: Treatment) {
        var next = recipe
        next.treatment = treatment
        commit(next, .treatment, "Treatment") { $0.treatment.name }
    }

    public func setBaseLook(_ look: BaseLookReference) {
        if let embedded = engine.embeddedBaseLook(), embedded.reference.isSameLook(as: look) {
            recipes.remember(embedded)
        }
        var next = recipe
        next.baseLook = look.withAmount(recipe.baseLook.isSameLook(as: look) ? recipe.baseLook.amount : look.amount)
        if look == BuiltInBaseLook.monochrome.reference || recipes.package(for: look)?.parameters.isMonochrome == true {
            next.treatment = .blackAndWhite
        }
        commit(anchored(next), .baseLook, "Base Look") { $0.baseLook.name }
    }

    public func setWhiteBalanceMode(_ mode: WhiteBalanceMode) {
        switch mode {
        case .asShot:
            guard let wb = info?.asShotWhiteBalance else { return }
            applyWhiteBalance(wb, mode: .asShot)
        case .auto:
            guard let visit = currentVisit else { return }
            Task {
                if let wb = await engine.autoWhiteBalance(), currentVisit == visit {
                    applyWhiteBalance(wb, mode: .auto)
                }
            }
        case .custom:
            var next = recipe
            next.whiteBalanceMode = .custom
            commit(next, .whiteBalance, "White Balance") { $0.whiteBalanceMode.name }
        default:
            if let wb = mode.presetValue {
                applyWhiteBalance(wb, mode: mode)
            }
        }
    }

    public func sampleWhiteBalance(at point: CGPoint) {
        guard let visit = currentVisit else { return }
        Task {
            guard let photoPoint = imagePoint(forCanvas: point) else { return }
            let wb = await engine.whiteBalance(sampledAt: photoPoint)
            guard currentVisit == visit else { return }
            if let wb {
                applyWhiteBalance(wb, mode: .custom, selector: true)
            }
            eyedropperActive = false
        }
    }

    /// A preset shows the mode it came from and went to; the selector, the temperature.
    private func applyWhiteBalance(_ wb: WhiteBalanceValue, mode: WhiteBalanceMode, selector: Bool = false) {
        var next = recipe
        next.whiteBalanceMode = mode
        next[.temperature] = ParameterID.temperature.spec.quantize(wb.temperature)
        next[.tint] = ParameterID.tint.spec.quantize(wb.tint)
        if selector {
            commit(next, .whiteBalance, "White Balance Selector") {
                "\(ParameterID.temperature.spec.formatted($0[.temperature])) K"
            }
        } else {
            commit(next, .whiteBalance, "White Balance") { $0.whiteBalanceMode.name }
        }
    }

    private func matchesAsShot(_ candidate: EditRecipe) -> Bool {
        guard let wb = info?.asShotWhiteBalance else { return false }
        return abs(candidate[.temperature] - ParameterID.temperature.spec.quantize(wb.temperature)) < 1
            && abs(candidate[.tint] - ParameterID.tint.spec.quantize(wb.tint)) < 0.5
    }

    public func autoTone() {
        guard let visit = currentVisit else { return }
        Task {
            let values = await engine.autoTone(for: recipe)
            guard currentVisit == visit, !values.isEmpty else { return }
            var next = recipe
            for (parameter, value) in values {
                next[parameter] = value
            }
            commit(next, .auto, "Auto Settings")
        }
    }

    // MARK: - Tone curve

    public func setPointCurve(_ points: [CurvePoint]) {
        var next = recipe
        next.pointCurve = points
        guard next != recipe else { return }
        let previous = recipe
        recipe = next
        requestRender()
        scheduleSave()
        if editStart == nil {
            recordHistory(.toneCurve, "Point Curve", from: previous)
        }
    }

    public func resetPointCurve() {
        var next = recipe
        next.pointCurve = EditRecipe.linearPointCurve
        commit(next, .reset, "Reset Point Curve")
    }

    // MARK: - Snapshots

    public func createSnapshot() {
        guard opening == nil else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        snapshots.append(Snapshot(name: formatter.string(from: Date()), recipe: recipe))
        scheduleSave()
    }

    public func applySnapshot(_ snapshot: Snapshot) {
        commit(snapshot.recipe, .snapshot, "Snapshot") { _ in snapshot.name }
    }

    public func deleteSnapshot(_ snapshot: Snapshot) {
        guard opening == nil else { return }
        snapshots.removeAll { $0.id == snapshot.id }
        scheduleSave()
    }

    // MARK: - History (see EditorModel+History)

    public func goToHistory(_ index: Int) {
        guard history.indices.contains(index), opening == nil else { return }
        activity.record(.edit, "Went to history step “\(history[index].name)”")
        let back = index < historyIndex
        historyIndex = index
        recipe = history[index].recipe
        requestRender()
        scheduleSave()
        followHistory(back: back)
    }

    /// The open photo's history session, which an Auto Sync run follows.
    var historySessionID: UUID {
        session.id
    }

    /// A new session for the photo just opened; its earlier ones load in the background.
    private func startSession(opening url: URL, recipe: EditRecipe, hasSidecar: Bool) {
        history = [HistoryStep(action: .open, title: hasSidecar ? "Opened" : "Import", recipe: recipe)]
        historyIndex = 0
        session = (UUID(), Date())
        clearsSavedHistory = false
        earlierSessions = []
        historyTask?.cancel()
        guard hasSidecar else { return }
        historyTask = Task { [sidecars] in
            let sessions = await Task.detached(priority: .utility) { sidecars.loadHistory(for: url) }.value
            guard selection == url, !Task.isCancelled else { return }
            earlierSessions = sessions.filter { $0.id != session.id }
        }
    }

    /// Applies a change without recording history (the live part of a drag).
    func applyLive(_ next: EditRecipe) {
        guard next != recipe else { return }
        recipe = next
        requestRender()
        scheduleSave()
    }

    /// A live change, such as dragging the crop: history records one step when the drag ends.
    func apply(_ next: EditRecipe) {
        guard next != recipe else { return }
        let previous = recipe
        recipe = next
        requestRender()
        scheduleSave()
        if editStart == nil {
            recordHistory(.crop, "Crop", from: previous)
        }
    }

    /// Applies a change as one step. `value` reads the value it changed, to show it before and after.
    func commit(_ next: EditRecipe, _ action: HistoryAction, _ title: String, value: ((EditRecipe) -> String)? = nil) {
        guard next != recipe else { return }
        let previous = recipe
        recipe = next
        recordHistory(action, title, from: previous, value: value)
        requestRender()
        scheduleSave()
    }

    // MARK: - Panels

    /// Whether a panel has edits, for the Edited chip on its header.
    public func isEdited(_ panel: PanelID) -> Bool {
        panel.settingsItems.contains(where: isEdited)
    }

    /// The kinds of setting a panel has changed, as Copy Settings lists them (`PanelID.settingsItems`):
    /// what its Edited chip counts.
    public func editedItems(_ panel: PanelID) -> [SettingsItem] {
        panel.settingsItems.filter(isEdited)
    }

    /// Whether any of a checklist line's settings differs from its default.
    func isEdited(_ item: SettingsItem) -> Bool {
        item.parameters.contains(where: isEdited) || item.fields.contains { field in
            switch field {
            case .treatment: treatment != .color
            case .baseLook: baseLook != BuiltInBaseLook.color.reference
            case .whiteBalanceMode: whiteBalanceMode != .asShot
            case .pointCurve: pointCurve != EditRecipe.linearPointCurve
            case .pointColor: hasPointColor
            case .crop, .orientation, .processVersion, .spots: false
            }
        }
    }

    /// Resets a panel from its header, in one step: the Tone Curve's point curve with its sliders,
    /// and the panel's switch back on.
    public func resetPanel(_ panel: PanelID) {
        guard let switchable = panel.switchable else {
            resetParameters(panel.parameters, name: "Reset \(panel.title)")
            return
        }
        var next = recipe
        next.reset(panel.parameters)
        if panel == .toneCurve {
            next.pointCurve = EditRecipe.linearPointCurve
        }
        next.setPanel(switchable, on: true)
        commit(next, .reset, "Reset \(panel.title)")
    }

    /// Whether a panel's switch is on; Basic has none.
    public func isOn(_ panel: PanelID) -> Bool {
        panel.switchable.map { !panelsOff.contains($0) } ?? true
    }

    /// Turns a panel off or on from the eye on its header (UX-30), as one step: "Detail Off".
    public func setPanel(_ panel: PanelID, on: Bool) {
        guard let switchable = panel.switchable, isOn(panel) != on else { return }
        var next = recipe
        next.setPanel(switchable, on: on)
        commit(next, .edit, Self.switchStepTitle(panel, on: on))
    }

    static func switchStepTitle(_ panel: PanelID, on: Bool) -> String {
        "\(panel.title) \(on ? "On" : "Off")"
    }

    public func togglePanel(_ panel: PanelID, solo: Bool) {
        if solo || soloMode {
            expandedPanels = expandedPanels.contains(panel) && expandedPanels.count == 1 ? [] : [panel]
        } else if expandedPanels.contains(panel) {
            expandedPanels.remove(panel)
        } else {
            expandedPanels.insert(panel)
        }
    }

    /// The left column's panels expand and collapse as the Develop panels do; Solo Mode is
    /// Option-click there, so the inspector's setting doesn't reach them.
    public func toggleSidebarSection(_ section: SidebarSection, solo: Bool) {
        if solo {
            expandedSidebarSections = expandedSidebarSections == [section] ? [] : [section]
        } else if expandedSidebarSections.contains(section) {
            expandedSidebarSections.remove(section)
        } else {
            expandedSidebarSections.insert(section)
        }
    }

    #if DEBUG || REDLAMP_PROFILING
        /// Scripted state changes for development snapshots (`--snapshot-script`).
        public func applyDebugCommand(_ key: String, _ value: String) {
            switch key {
            case "filmstrip":
                keepsFilmstripShown = value == "shown"
            case "panel":
                expandedPanels = value == "all" ? Set(PanelID.allCases) :
                    Set(value.split(separator: "+").compactMap { PanelID(rawValue: String($0)) })
            case "tool":
                activeTool = EditTool(rawValue: value) ?? .edit
            case "off":
                for panel in value.split(separator: "+").compactMap({ PanelID(rawValue: String($0)) }) {
                    setPanel(panel, on: false)
                }
            case "select":
                if let index = Int(value), items.indices.contains(index) {
                    select(items[index].url)
                }
            case "extend":
                if let index = Int(value), items.indices.contains(index) {
                    click(items[index].url, extending: true)
                }
            case "zoom":
                canvas.zoom = value == "1:1" ? .oneToOne : value == "fill" ? .fill : .fit
            case "action":
                if let action = ShortcutAction(rawValue: value) {
                    perform(action)
                }
            case "before":
                showBefore = value == "1"
            case "compare":
                compareLayout = CompareLayout(rawValue: value) ?? .toggle
            case "split":
                splitPosition = Double(value) ?? 0.5
            case "clipping":
                showClipping = value == "1"
            case "rawClipping":
                showRawClipping = value == "1"
            case "assessment":
                colorAssessment = value == "1"
            case "recipe", "preset":
                if let recipe = recipes.recipe(id: value) ?? recipes.recipe(id: "redlamp/\(value)") {
                    applyRecipe(recipe)
                }
            case "baseLook", "profile":
                if let look = BuiltInBaseLook(legacyID: value) ?? BuiltInBaseLook(legacyID: "redlamp.\(value)") {
                    setBaseLook(look.reference)
                } else if let package = recipes.baseLooks.first(where: { $0.id == value || $0.slot == value }) {
                    setBaseLook(package.reference)
                }
            case "wb":
                if let mode = WhiteBalanceMode(rawValue: value) {
                    setWhiteBalanceMode(mode)
                }
            case "linear", "radial":
                // linear=x1:y1:x2:y2   radial=cx:cy:rx:ry[:feather]
                let n = value.split(separator: ":").compactMap { Double($0) }
                guard n.count >= 4 else { return }
                let shape: MaskShape = key == "linear"
                    ? .linear(LinearMask(start: ImagePoint(x: n[0], y: n[1]), end: ImagePoint(x: n[2], y: n[3])))
                    : .radial(RadialMask(
                        center: ImagePoint(x: n[0], y: n[1]), radiusX: n[2], radiusY: n[3],
                        feather: n.count > 4 ? n[4] : 50,
                    ))
                startDrawing(key == "linear" ? .linear : .radial)
                beginDrawing(shape)
                finishDrawing()
            default:
                let parameter = ParameterID(rawValue: key) ?? ParameterID.allCases.first { key == "\($0)" }
                if let parameter, let number = Double(value) {
                    setSliderValue(parameter, number)
                }
            }
        }
    #endif

    // MARK: - Persistence

    /// Saves 600 ms after the last change and, outside a drag, at most 2 s after the first one
    /// not saved, so a run of nudges is on disk while it goes on. A drag waits until it pauses:
    /// a save wakes the folder watcher, which costs the drag frames. It moves the deadline on
    /// every event rather than spawning a task per event.
    func scheduleSave() {
        let first = unsavedSince ?? .now
        unsavedSince = first
        let deadline = ContinuousClock.now + .milliseconds(600)
        saveDeadline = editStart == nil ? min(deadline, first + .seconds(2)) : deadline
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            while !Task.isCancelled, let deadline = self?.saveDeadline, deadline > .now {
                try? await Task.sleep(until: deadline)
            }
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        saveDeadline = nil
        unsavedSince = nil
        guard let url = selection, info != nil, opening == nil, !isReadOnly else { return }
        var sidecar = sidecarToSave
        sidecar.clearsHistory = clearsSavedHistory
        clearsSavedHistory = false
        // The filmstrip's badge follows once it's on disk (`saved`).
        saves.enqueue(.sidecar(sidecar), for: url)
    }

    /// The open photo's edit, metadata and this session's history, as saving writes them.
    var sidecarToSave: Sidecar {
        var sidecar = Sidecar(
            recipe: recipe, snapshots: snapshots, metadata: photoMetadata.isEmpty ? nil : photoMetadata,
            session: HistorySession(
                id: session.id,
                started: session.started,
                steps: Array(history.prefix(historyIndex + 1)),
            ),
        )
        sidecar.unsavedSessions = unsavedSessions
        return sidecar
    }

    /// A change is waiting for its save.
    var hasUnsavedChange: Bool {
        saveTask != nil
    }
}

/// One visit of a photo in the editor: opening it again, or opening another, starts a new one.
struct PhotoVisit: Equatable {
    var url: URL
    var number: Int
}
