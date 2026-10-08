import RedlampEngineAPI

public extension GrayMask {
    /// A file's matte, as the decoder read it, in the oriented frame.
    init(_ matte: EmbeddedMatteImage) {
        self = GrayMask(width: matte.width, height: matte.height, coverage: matte.coverage)
            .oriented(exif: matte.orientation)
    }
}
