import Foundation
import MLX
import Testing
@testable import RedlampGenerative

struct MLXRuntimeTests {
    @Test func `MLX multiplies matrices on the GPU`() {
        let a = MLXArray(converting: [1, 2, 3, 4], [2, 2])
        let b = MLXArray(converting: [5, 6, 7, 8], [2, 2])
        let product = matmul(a, b, stream: .gpu)
        #expect(product.asArray(Float.self) == [19, 22, 43, 50])
    }
}
