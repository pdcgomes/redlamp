import RedlampRecipes

/// The kit's README.txt: what the owner does on the phone.
enum AppLookKitReadme {
    static func text(files: [CaptureKitManifest.File]) -> String {
        let charts = files.filter { $0.role == "chart" }.map(\.file)
        let photos = files.filter { $0.role == "photo" }.map { "  \($0.file)  (\($0.subject ?? "photo"))" }
        return """
        REDLAMP CAPTURE KIT (version \(CaptureChart.kitVersion))

        This kit measures one phone-app filter or preset so Redlamp can rebuild it as its own look.
        You run every image in this kit through ONE filter, export the results, and send them back.
        Repeat the whole process once per filter, into a new folder each time.

        WHAT'S IN THE KIT
          \(charts.joined(separator: "\n  "))
            Colour charts. They look like grids of coloured squares on grey. They measure the colours.
        \(photos.joined(separator: "\n"))
            Ordinary photos. They measure vignette, grain, blur and glow, and check the result.
          kit.json   checksums of every file (for the Mac; ignore it on the phone)

        THE RULES (they matter more than anything else)
          1. Use the same filter, at the same strength, on every image. Leave its strength slider where
             the app puts it (usually 100%), or write down the value you used.
          2. Don't crop, rotate, straighten or change the aspect ratio. Keep "Original".
          3. Don't add anything else: no extra adjustments, text, stickers, frames or retouching.
          4. Export at the largest size and best quality the app offers. JPEG is fine.
          5. Write down the app and the filter's exact name. You'll type them on the Mac once.

        1. SEND THE KIT TO THE IPHONE
          On the Mac, select all the .png and .jpg files of the kit in Finder (not the .zip), then
          right-click > Share > AirDrop > your iPhone. They land in the Photos app. (The .zip is the
          same kit in one file, if you'd rather keep it in the Files app.)

        2A. PREQUEL
          1. Open Prequel and tap the button that starts a new edit, then pick the first kit image
             from your library.
          2. If Prequel shows a crop or format choice, pick "Original" (not 1:1, 4:5 or 9:16).
          3. Open the filters, choose the filter you want to capture and apply it. Don't touch its
             other effects or adjustments.
          4. Tap the export/save button and save to your photo library at the highest quality.
             (If the free version adds a watermark, that's fine for photos but keep it away from the
             charts if you can; the importer tolerates small marks in a corner.)
          5. Do the same for every other kit image, with exactly the same filter.
          Some Prequel filters add random dust, light leaks or grain that change on every export.
          That's fine: the importer measures them separately from the colour.

        2B. LIGHTROOM MOBILE
          1. Open Lightroom, tap the add-photos button (the picture with a +), choose your photo
             library, select all the kit images and add them.
          2. Open the first kit image, tap Presets, choose the preset and tap the check mark. If the
             preset has an Amount slider, leave it at 100.
          3. Tap the three dots (...) > Copy Settings. Make sure every group except Crop/Geometry is
             ticked, and confirm.
          4. Go back to the grid, select all the other kit images, tap the three dots (...) > Paste
             Settings.
          5. Select all the kit images, tap Share > Export As: File Type JPG, Dimensions "Largest
             Available", Quality 100, and under More Options: Color Space sRGB, Watermark off,
             Output Sharpening off. Save to the camera roll.

        3. SEND THE RESULTS BACK
          In Photos, select all the exported images, tap Share > AirDrop > the Mac. On the Mac, move
          them from Downloads into a folder of their own named after the filter, for example
          ~/Downloads/capture-warm-film. The app may rename the files; that's fine.

        4. ON THE MAC
          redlamp recipe app-import ~/Downloads/capture-warm-film --name "Your Redlamp name" \\
              --app prequel --filter "Filter name in the app" --install
          Use --app lightroom for Lightroom presets. The name you give is the only name the look will
          have in Redlamp; the app and filter names are kept only in the report and the recipe's private notes.
          The result, a report and a before/after sheet go into build/app-looks/out/.

        IF THE MAC SAYS
          "the app cut the colour lattice": the app cropped the chart. Re-export that chart with
            the Original aspect ratio.
          "no capture-chart markers found": the chart was rotated, heavily distorted or not exported.
          "chart N is missing": one chart didn't come back; the look still works but that range of
            colours is guessed. Send the missing chart if you can.

        """
    }

    /// The one-image kit: one pick, one apply and one export per filter.
    static func compactText(file: String, tiles: [String]) -> String {
        """
        REDLAMP ONE-IMAGE CAPTURE KIT (version \(CaptureChart.kitVersion))

        One image measures one phone-app filter or preset so Redlamp can rebuild it as its own look.
        Per filter: open \(file), apply the filter, export. That's all.

        WHAT'S IN THE KIT
          \(file)   3072 x 3072 PNG: colour squares on grey, markers, a grey ramp, fine stripes and
                    \(tiles.count) small photos (\(tiles.joined(separator: ", "))).
          kit.json          checksums (for the Mac; ignore it on the phone)
        It's a PNG so the colours reach the app exactly; the app's JPEG export is fine.

        THE RULES
          1. Same filter at the app's default strength (usually 100%), or write down the value.
          2. No crop, rotate or aspect change: keep "Original". (A 4:5 crop still works; 9:16 doesn't.)
          3. Nothing else: no extra adjustments, text, stickers, frames or retouching.
          4. Export at the largest size and best quality the app offers.
          5. Write down the app and the filter's exact name.

        1. SEND THE IMAGE TO THE IPHONE
          On the Mac, right-click \(file) > Share > AirDrop > your iPhone. It lands in Photos.

        2A. PREQUEL (repeat for each filter)
          1. Open Prequel, start a new edit and pick redlamp-kit from your library.
          2. If Prequel asks for a format, pick "Original".
          3. Choose the filter and apply it; leave its other effects alone.
          4. Save/export to your library at the highest quality or resolution offered.
          5. Back out, and start the next filter from step 1 with the same kit image.

        2B. LIGHTROOM MOBILE
          Import the kit image once: tap the add-photos button, choose it from your library.
          For each preset:
            1. Open the kit image, tap Presets, choose the preset, tap the check mark (Amount 100).
            2. Tap Share > Export As: JPG, Dimensions "Largest Available", Quality 100; under More
               Options: Color Space sRGB, Output Sharpening off, Watermark off. Save to camera roll.
            3. Tap the three dots (...) > Reset > All (or "To Import"), so the next preset starts
               from the plain kit image (a preset only changes the settings it contains; the rest
               would carry over).
          That loop of apply, export, reset is the fastest: no re-import and no copies to manage.
          Copies (... > Create Copy) or Versions also work if you want each preset kept in the app,
          but they add taps per preset.

        3. SEND THE RESULTS BACK
          Select the exports in Photos > Share > AirDrop > the Mac. They arrive in Downloads.

        4. ON THE MAC (once per export)
          redlamp recipe app-import ~/Downloads/IMG_1234.JPG --name "Your Redlamp name" \\
              --app prequel --filter "Filter name in the app" --install
          Pass the export file itself, or a folder holding just that one export. Use --app lightroom
          for Lightroom presets. The name is Redlamp's own; the app and filter are kept only in the
          report and the recipe's private notes. Results go into build/app-looks/out/.
          The report gives the export's size and how much detail survived: if it warns the patches
          were too small, export larger (for the full 3-chart kit, run app-kit without --compact).

        """
    }
}
