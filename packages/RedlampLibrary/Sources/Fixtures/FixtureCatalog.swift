import Foundation

/// What synthetic photos are made of: 25 cameras, 40 lenses, the settings they shoot at,
/// places, keywords, captions, and the names of events, clients and jobs. Keywords are chosen so
/// that none is part of another, and no folder, file, camera or lens name holds "sunset", which
/// the query corpus searches for as free text.
enum FixtureCatalog {
    struct Camera: Sendable {
        let make: String
        let model: String
        /// Which lenses fit: the lenses with the same mount.
        let mount: String
        /// How its files are named: `DSCF0001.JPG`.
        let prefix: String
    }

    struct Lens: Sendable {
        let name: String
        let mount: String
        let focal: ClosedRange<Double>
        /// Its widest aperture.
        let aperture: Double
    }

    struct Place: Sendable {
        let latitude: Double
        let longitude: Double
    }

    static let cameras: [Camera] = [
        Camera(make: "FUJIFILM", model: "X-T5", mount: "fujifilm-x", prefix: "DSCF"),
        Camera(make: "FUJIFILM", model: "X-T4", mount: "fujifilm-x", prefix: "DSCF"),
        Camera(make: "FUJIFILM", model: "X-H2S", mount: "fujifilm-x", prefix: "DSCF"),
        Camera(make: "FUJIFILM", model: "X100V", mount: "x100v", prefix: "DSCF"),
        Camera(make: "SONY", model: "ILCE-7M4", mount: "sony-e", prefix: "DSC0"),
        Camera(make: "SONY", model: "ILCE-7RM5", mount: "sony-e", prefix: "DSC0"),
        Camera(make: "SONY", model: "ILCE-6400", mount: "sony-e", prefix: "DSC0"),
        Camera(make: "SONY", model: "DSC-RX100M7", mount: "rx100m7", prefix: "DSC0"),
        Camera(make: "Canon", model: "Canon EOS R5", mount: "canon-rf", prefix: "IMG_"),
        Camera(make: "Canon", model: "Canon EOS R6 Mark II", mount: "canon-rf", prefix: "IMG_"),
        Camera(make: "Canon", model: "Canon EOS 5D Mark IV", mount: "canon-ef", prefix: "IMG_"),
        Camera(make: "Canon", model: "Canon EOS 90D", mount: "canon-ef", prefix: "IMG_"),
        Camera(make: "NIKON CORPORATION", model: "NIKON Z 8", mount: "nikon-z", prefix: "DSC_"),
        Camera(make: "NIKON CORPORATION", model: "NIKON Z 6_2", mount: "nikon-z", prefix: "DSC_"),
        Camera(make: "NIKON CORPORATION", model: "NIKON D850", mount: "nikon-f", prefix: "DSC_"),
        Camera(make: "Panasonic", model: "DC-GH6", mount: "micro-four-thirds", prefix: "P10"),
        Camera(make: "OM Digital Solutions", model: "OM-1", mount: "micro-four-thirds", prefix: "P"),
        Camera(make: "LEICA CAMERA AG", model: "LEICA Q2", mount: "q2", prefix: "L10"),
        Camera(make: "LEICA CAMERA AG", model: "LEICA SL2", mount: "leica-l", prefix: "L10"),
        Camera(make: "RICOH IMAGING COMPANY, LTD.", model: "RICOH GR III", mount: "gr-iii", prefix: "R0"),
        Camera(make: "Apple", model: "iPhone 15 Pro", mount: "iphone-15-pro", prefix: "IMG_"),
        Camera(make: "Apple", model: "iPhone 13", mount: "iphone-13", prefix: "IMG_"),
        Camera(make: "Google", model: "Pixel 8 Pro", mount: "pixel-8-pro", prefix: "PXL_"),
        Camera(make: "samsung", model: "Galaxy S23 Ultra", mount: "galaxy-s23", prefix: "SAM_"),
        Camera(make: "DJI", model: "FC3582", mount: "dji-fc3582", prefix: "DJI_"),
    ]

    static let lenses: [Lens] = [
        Lens(name: "XF16-55mmF2.8 R LM WR", mount: "fujifilm-x", focal: 16 ... 55, aperture: 2.8),
        Lens(name: "XF35mmF1.4 R", mount: "fujifilm-x", focal: 35 ... 35, aperture: 1.4),
        Lens(name: "XF56mmF1.2 R", mount: "fujifilm-x", focal: 56 ... 56, aperture: 1.2),
        Lens(name: "XF18-55mmF2.8-4 R LM OIS", mount: "fujifilm-x", focal: 18 ... 55, aperture: 2.8),
        Lens(name: "XF100-400mmF4.5-5.6 R LM OIS WR", mount: "fujifilm-x", focal: 100 ... 400, aperture: 4.5),
        Lens(name: "FE 24-70mm F2.8 GM II", mount: "sony-e", focal: 24 ... 70, aperture: 2.8),
        Lens(name: "FE 35mm F1.8", mount: "sony-e", focal: 35 ... 35, aperture: 1.8),
        Lens(name: "FE 85mm F1.8", mount: "sony-e", focal: 85 ... 85, aperture: 1.8),
        Lens(name: "FE 70-200mm F2.8 GM OSS II", mount: "sony-e", focal: 70 ... 200, aperture: 2.8),
        Lens(name: "FE 16-35mm F4 ZA OSS", mount: "sony-e", focal: 16 ... 35, aperture: 4),
        Lens(name: "E 18-135mm F3.5-5.6 OSS", mount: "sony-e", focal: 18 ... 135, aperture: 3.5),
        Lens(name: "RF24-105mm F4 L IS USM", mount: "canon-rf", focal: 24 ... 105, aperture: 4),
        Lens(name: "RF50mm F1.8 STM", mount: "canon-rf", focal: 50 ... 50, aperture: 1.8),
        Lens(name: "RF100-500mm F4.5-7.1 L IS USM", mount: "canon-rf", focal: 100 ... 500, aperture: 4.5),
        Lens(name: "RF15-35mm F2.8 L IS USM", mount: "canon-rf", focal: 15 ... 35, aperture: 2.8),
        Lens(name: "RF85mm F1.2 L USM", mount: "canon-rf", focal: 85 ... 85, aperture: 1.2),
        Lens(name: "EF24-70mm f/2.8L II USM", mount: "canon-ef", focal: 24 ... 70, aperture: 2.8),
        Lens(name: "EF50mm f/1.4 USM", mount: "canon-ef", focal: 50 ... 50, aperture: 1.4),
        Lens(name: "EF70-200mm f/2.8L IS III USM", mount: "canon-ef", focal: 70 ... 200, aperture: 2.8),
        Lens(name: "EF-S18-135mm f/3.5-5.6 IS USM", mount: "canon-ef", focal: 18 ... 135, aperture: 3.5),
        Lens(name: "NIKKOR Z 24-120mm f/4 S", mount: "nikon-z", focal: 24 ... 120, aperture: 4),
        Lens(name: "NIKKOR Z 50mm f/1.8 S", mount: "nikon-z", focal: 50 ... 50, aperture: 1.8),
        Lens(name: "NIKKOR Z 70-200mm f/2.8 VR S", mount: "nikon-z", focal: 70 ... 200, aperture: 2.8),
        Lens(name: "NIKKOR Z 14-30mm f/4 S", mount: "nikon-z", focal: 14 ... 30, aperture: 4),
        Lens(name: "AF-S NIKKOR 24-70mm f/2.8E ED VR", mount: "nikon-f", focal: 24 ... 70, aperture: 2.8),
        Lens(name: "AF-S NIKKOR 85mm f/1.8G", mount: "nikon-f", focal: 85 ... 85, aperture: 1.8),
        Lens(name: "LUMIX G VARIO 12-35mm F2.8", mount: "micro-four-thirds", focal: 12 ... 35, aperture: 2.8),
        Lens(name: "M.Zuiko Digital ED 12-40mm F2.8 PRO", mount: "micro-four-thirds", focal: 12 ... 40, aperture: 2.8),
        Lens(name: "M.Zuiko Digital 45mm F1.8", mount: "micro-four-thirds", focal: 45 ... 45, aperture: 1.8),
        Lens(name: "APO-SUMMICRON-SL 35 f/2 ASPH.", mount: "leica-l", focal: 35 ... 35, aperture: 2),
        Lens(name: "VARIO-ELMARIT-SL 24-70 f/2.8 ASPH.", mount: "leica-l", focal: 24 ... 70, aperture: 2.8),
        Lens(name: "FUJINON 23mm F2", mount: "x100v", focal: 23 ... 23, aperture: 2),
        Lens(name: "ZEISS Vario-Sonnar T* 9-72mm F2.8-4.5", mount: "rx100m7", focal: 9 ... 72, aperture: 2.8),
        Lens(name: "SUMMILUX 28 f/1.7 ASPH.", mount: "q2", focal: 28 ... 28, aperture: 1.7),
        Lens(name: "GR LENS 18.3mm F2.8", mount: "gr-iii", focal: 18.3 ... 18.3, aperture: 2.8),
        Lens(
            name: "iPhone 15 Pro back triple camera 6.765mm f/1.78", mount: "iphone-15-pro",
            focal: 6.765 ... 6.765, aperture: 1.78,
        ),
        Lens(
            name: "iPhone 13 back dual wide camera 5.1mm f/1.6",
            mount: "iphone-13",
            focal: 5.1 ... 5.1,
            aperture: 1.6,
        ),
        Lens(name: "Pixel 8 Pro back camera 6.9mm f/1.68", mount: "pixel-8-pro", focal: 6.9 ... 6.9, aperture: 1.68),
        Lens(name: "Galaxy S23 Ultra back camera 6.3mm f/1.7", mount: "galaxy-s23", focal: 6.3 ... 6.3, aperture: 1.7),
        Lens(name: "DJI FC3582 6.7mm f/1.7", mount: "dji-fc3582", focal: 6.7 ... 6.7, aperture: 1.7),
    ]

    /// Each camera's lenses, by index into `lenses`.
    static let lensesByCamera: [[Int]] = cameras.map { camera in
        lenses.indices.filter { lenses[$0].mount == camera.mount }
    }

    static let isoSpeeds = [
        100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 12800,
    ]

    static let apertures: [Double] = [1.2, 1.4, 1.8, 2, 2.8, 4, 5.6, 8, 11, 16]

    /// Exposure times in seconds, fastest first; the last seven are a quarter of a second or longer.
    static let exposureTimes: [Double] = [
        1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60, 1.0 / 30,
        1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 15, 30,
    ]

    static let places: [Place] = [
        Place(latitude: 38.7223, longitude: -9.1393),
        Place(latitude: 41.1579, longitude: -8.6291),
        Place(latitude: 35.6762, longitude: 139.6503),
        Place(latitude: 35.0116, longitude: 135.7681),
        Place(latitude: 40.7128, longitude: -74.0060),
        Place(latitude: 37.7749, longitude: -122.4194),
        Place(latitude: 51.5072, longitude: -0.1276),
        Place(latitude: 48.8566, longitude: 2.3522),
        Place(latitude: 64.1466, longitude: -21.9426),
        Place(latitude: -33.9249, longitude: 18.4241),
        Place(latitude: -33.8688, longitude: 151.2093),
        Place(latitude: -34.6037, longitude: -58.3816),
        Place(latitude: 45.5019, longitude: -73.5674),
        Place(latitude: 31.6295, longitude: -7.9811),
        Place(latitude: 21.0285, longitude: 105.8542),
    ]

    static let keywords = [
        "birds", "portrait", "landscape", "family", "architecture", "street", "food", "travel", "macro", "wildlife",
        "night", "sunset", "beach", "mountains", "city", "flowers", "dog", "snow", "autumn", "concert",
        "sports", "kids", "boats", "trains", "market", "forest", "river", "festival", "museum", "garden",
    ]

    static let captions = [
        "Morning light over the river", "Sunset over the harbour", "Family lunch in the garden",
        "Street market at noon", "Birds on the old pier", "Snow on the mountain road", "Night lights in the city",
        "Waves on the beach", "Autumn colours in the forest", "Festival crowd at dusk", "Trains at the station",
        "Boats in the bay", "Flowers after the rain", "Kids playing in the park", "The museum's main hall",
        "A dog on the beach at sunset", "First light on the peaks", "Dinner with friends", "Rain on the window",
        "Fog over the valley",
    ]

    static let events = [
        "Wedding", "Birthday", "Hike", "Beach Day", "Concert", "Graduation", "Road Trip", "Garden", "Zoo",
        "Christmas", "Museum Visit", "City Walk", "Football Match", "Family Dinner", "Snow Day", "Harbour Walk",
        "Picnic", "Airshow", "Market", "Camping",
    ]

    static let clients = [
        "Acme Corp", "Northwind Traders", "Globex", "Initech", "Umbrella Studio", "Stark Atelier",
        "Wayne Foundation", "Soylent Foods", "Hooli", "Vandelay Industries", "Pied Piper", "Duff Brewery",
    ]

    static let jobs = [
        "Catalogue", "Product Launch", "Headshots", "Annual Report", "Lookbook", "Trade Show", "Brand Shoot",
        "Team Portraits", "Interiors", "Event Coverage",
    ]
}
