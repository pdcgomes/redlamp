+++
deck = "Every slider in the Masking tool, with its range, its default and the step the arrow keys take, read from the app's own definitions."
sources = [
  "`packages/RedlampEngineAPI/Sources/ParameterSpec.swift` (the tables, generated)",
  "`packages/RedlampUI/Sources/Model/BrushSettings.swift` (the B and Erase brushes)",
  "`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift` (the Refine Edge Brush's Size)",
]
+++

Each table is read from `ParameterCatalog`, where the app defines every slider once for the engine and the panels alike. Values are written as the slider's field shows them; [[⇧]] with an arrow key steps ten times as far.

## The mask

{{table: sliders maskAmount maskDetail}}

## Adjustments

{{table: sliders localTemperature localTint localExposure localContrast localHighlights localShadows localWhites localBlacks localTexture localClarity localDehaze localHue localSaturation localSharpness localNoise localMoire localDefringe localHalation localBloom localColorHue localColorSaturation}}

## Components

Radial Gradient's Feather, the brush's four sliders, Color Range's Refine, and the Feather and Edge of every AI mask but Depth Range:

{{table: sliders maskFeather maskBrushSize maskBrushFeather maskBrushFlow maskBrushDensity maskColorRefine maskAIFeather maskAIEdge}}

The brush's defaults above are brush A's. Brush B starts at Size 8 and Feather 20, and Erase at Size 15; all three remember their own settings. The Refine Edge Brush's Size, from 1 to 100 and 12 to start, isn't one of the app's catalogued sliders, so it isn't in these tables.
