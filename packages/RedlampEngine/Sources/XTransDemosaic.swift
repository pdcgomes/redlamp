/*
 * Frank Markesteijn's demosaic for Fujifilm X-Trans sensors: the tables and the GPU encoding of the
 * kernels in DemosaicXTrans.metal, ported for Redlamp from LibRaw 0.22.2,
 * src/demosaic/xtrans_demosaic.cpp (LibRaw::xtrans_interpolate).
 *
 * Original: Copyright 2019-2025 LibRaw LLC (info@libraw.org). LibRaw uses code from dcraw.c,
 * copyright 1997-2018 by Dave Coffin; LibRaw does not use RESTRICTED code from dcraw.c. LibRaw is
 * licensed under the GNU LGPL 2.1 or the CDDL 1.0, at the user's choice; Redlamp uses the CDDL.
 *
 * This file is covered by the Common Development and Distribution License (CDDL) Version 1.0
 * (LICENSES/CDDL-1.0.txt), not by the MPL-2.0 that covers the rest of Redlamp.
 *
 * Modifications by the Redlamp contributors, 2026: the hexagon table is built per CFA pattern in
 * Swift, offsets as (column, row) pairs; the image is processed in bands of rows on the GPU; the
 * CIELab conversion takes the session's camera matrix.
 */

import Metal
import RedlampEngineAPI
import RedlampKernels
import RedlampServices
import simd

/// The green hexagons around every position of the X-Trans 3 × 3 cell, and where its solitary
/// green sits. Nil for a pattern Markesteijn's algorithm can't use.
struct XTransMarkesteijn {
    /// Eight (column, row) offsets per cell position, indexed by `(row % 3) * 3 + column % 3`.
    let hex: [SIMD2<Int32>]
    let solitaryRow: Int32
    let solitaryColumn: Int32

    /// Output rows per band, and the rows of context each side; the kernels read at most 8 away.
    static let bandRows = 256
    static let apron = 16

    init?(_ pattern: CFAPattern) {
        guard pattern.width == 6, pattern.height == 6 else { return nil }
        func color(_ row: Int, _ column: Int) -> UInt8 {
            pattern.colors[((row % 6 + 6) % 6) * 6 + (column % 6 + 6) % 6]
        }
        var counts = [0, 0, 0, 0]
        for value in pattern.colors {
            counts[Int(min(value, 3))] += 1
        }
        guard (6 ... 10).contains(counts[0]), (16 ... 24).contains(counts[1]), (6 ... 10).contains(counts[2]),
              counts[3] == 0
        else { return nil }

        let orth = [1, 0, 0, 1, -1, 0, 0, -1, 1, 0, 0, 1]
        let patt = [
            [0, 1, 0, -1, 2, 0, -1, 0, 1, 1, 1, -1, 0, 0, 0, 0],
            [0, 1, 0, -2, 1, 0, -2, 0, 1, 1, -2, -2, 1, -1, -1, 1],
        ]
        var table = [SIMD2<Int32>?](repeating: nil, count: 72)
        var solitary: (Int, Int)?
        for row in 0 ..< 3 {
            for column in 0 ..< 3 {
                let g = color(row, column) == 1 ? 1 : 0
                var ng = 0
                for d in stride(from: 0, to: 10, by: 2) {
                    ng = color(row + orth[d], column + orth[d + 2]) == 1 ? 0 : ng + 1
                    if ng == 4 {
                        solitary = (row, column)
                    }
                    guard ng == g + 1 else { continue }
                    for c in 0 ..< 8 {
                        let v = orth[d] * patt[g][c * 2] + orth[d + 1] * patt[g][c * 2 + 1]
                        let h = orth[d + 2] * patt[g][c * 2] + orth[d + 3] * patt[g][c * 2 + 1]
                        table[(row * 3 + column) * 8 + (c ^ (g * 2 & d))] = SIMD2(Int32(h), Int32(v))
                    }
                }
            }
        }
        guard let solitary, color(solitary.0, solitary.1 + 1) != 1 else { return nil }
        let hex = table.compactMap(\.self)
        guard hex.count == 72 else { return nil }
        self.hex = hex
        solitaryRow = Int32(solitary.0)
        solitaryColumn = Int32(solitary.1)
    }

    /// Camera RGB to XYZ with each row divided by D65's white, as LibRaw's `cielab` uses it, from the
    /// camera-to-linear-sRGB matrix (row-major).
    static func xyzCam(cameraToSRGB m: [Double]) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let xyzFromRGB: [[Double]] = [
            [0.412453, 0.357580, 0.180423], [0.212671, 0.715160, 0.072169], [0.019334, 0.119193, 0.950227],
        ]
        let white: [Double] = [0.950456, 1, 1.088754]
        var rows = [SIMD4<Float>](repeating: .zero, count: 3)
        for i in 0 ..< 3 {
            for j in 0 ..< 3 {
                var sum = 0.0
                for k in 0 ..< 3 {
                    sum += xyzFromRGB[i][k] * m[k * 3 + j]
                }
                rows[i][j] = Float(sum / white[i])
            }
        }
        return (rows[0], rows[1], rows[2])
    }
}

extension SessionBuilder {
    /// Overwrites all but the 8 edge photosites of `pyramid`'s level 0, which must already hold a
    /// demosaic, with Markesteijn's, processing bands of rows so the per-direction planes stay small.
    func encodeMarkesteijn(
        _ table: XTransMarkesteijn,
        mosaic: any MTLTexture,
        colors: [UInt8],
        cameraToSRGB: [Double],
        into pyramid: any MTLTexture,
        encoder: any MTLComputeCommandEncoder,
    ) throws {
        let width = mosaic.width
        let height = mosaic.height
        let rows = min(height, XTransMarkesteijn.bandRows + 2 * XTransMarkesteijn.apron)
        func planes(_ format: MTLPixelFormat) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type2DArray
            descriptor.pixelFormat = format
            descriptor.width = width
            descriptor.height = rows
            descriptor.arrayLength = 4
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.gpuUnavailable }
            return texture
        }
        let candidates = try planes(.rgba16Float)
        let scratch = try planes(.rg16Float)
        let derivatives = try planes(.r32Float)
        let homogeneity = try planes(.r8Uint)
        var colors = colors
        var hex = table.hex
        let xyzCam = XTransMarkesteijn.xyzCam(cameraToSRGB: cameraToSRGB)

        for outTop in stride(from: 0, to: height, by: XTransMarkesteijn.bandRows) {
            let outBottom = min(height, outTop + XTransMarkesteijn.bandRows)
            let bandTop = max(0, min(outTop - XTransMarkesteijn.apron, height - rows))
            var params = XTransParams(
                width: UInt32(width), height: UInt32(height), bandTop: UInt32(bandTop), bandRows: UInt32(rows),
                outTop: UInt32(outTop), outBottom: UInt32(outBottom),
                solitaryRow: table.solitaryRow, solitaryColumn: table.solitaryColumn, xyzCam: xyzCam,
            )
            func dispatch(_ pipeline: any MTLComputePipelineState, _ textures: [any MTLTexture]) {
                encoder.setComputePipelineState(pipeline)
                for (index, texture) in textures.enumerated() {
                    encoder.setTexture(texture, index: index)
                }
                encoder.setBytes(&params, length: MemoryLayout<XTransParams>.stride, index: 0)
                encoder.setBytes(&colors, length: colors.count, index: 1)
                encoder.setBytes(&hex, length: hex.count * MemoryLayout<SIMD2<Int32>>.stride, index: 2)
                encoder.dispatchGrid(width: width, height: rows, pipeline: pipeline)
            }
            dispatch(kernels.xtransGreen, [mosaic, candidates])
            dispatch(kernels.xtransSolitary, [candidates])
            dispatch(kernels.xtransOpposite, [candidates, scratch])
            dispatch(kernels.xtransOppositeMerge, [candidates, scratch])
            dispatch(kernels.xtransBlocks, [candidates, scratch])
            dispatch(kernels.xtransBlocksMerge, [candidates, scratch])
            dispatch(kernels.xtransDerivatives, [candidates, derivatives])
            dispatch(kernels.xtransHomogeneity, [derivatives, homogeneity])
            dispatch(kernels.xtransAverage, [candidates, homogeneity, pyramid])
        }
    }
}
