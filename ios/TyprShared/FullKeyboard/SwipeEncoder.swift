import Foundation

// FUTO Swipe's encoder (weights: SwipeModel/LICENSE-FUTO-SWIPE.txt), run on the CPU without a runtime.
// Network, resampling and kernels adapted from AVGVSTVS96/iikb
// Packages/KeyboardModules/Sources/KeyboardCore/Correction/{Swipe,SwipeLayout,SwipeNetwork,SwipeKernels}.swift
// (MIT), revision f42bad59ce3c0f6f35c7ec0cf727d0b67c146608. Typr ships the encoder only: the English/QWERTY
// decoder lowered German accuracy in Typr's evaluation.

/// One sample of a swipe in keyboard points; `time` in seconds from the first sample.
nonisolated struct SwipePoint: Sendable, Equatable {
    var x: Double
    var y: Double
    var time: Double
}

/// The 26 letter keys in the unit square the encoder reads a swipe in (the box around the letter keys).
nonisolated struct SwipeLayout: Sendable, Equatable {
    let frame: CGRect
    /// a–z, normalized to `frame`.
    let centers: [SIMD2<Double>]

    init?(centers: [Character: CGPoint], frame: CGRect) {
        let ordered = (0..<SwipeEncoder.letters).compactMap { centers[Character(UnicodeScalar(UInt8(97 + $0)))] }
        guard ordered.count == SwipeEncoder.letters, frame.width > 0, frame.height > 0 else { return nil }
        self.frame = frame
        self.centers = ordered.map {
            SIMD2(Double(($0.x - frame.minX) / frame.width), Double(($0.y - frame.minY) / frame.height))
        }
    }

    /// The letter keys of a letters page; nil on other pages.
    init?(layout: KeyboardLayout) {
        var centers: [Character: CGPoint] = [:]
        var box: CGRect?
        for key in layout.keys {
            guard let text = key.character, text.count == 1, let letter = text.first,
                  letter.isASCII, letter.isLowercase else { continue }
            centers[letter] = CGPoint(x: key.frame.midX, y: key.frame.midY)
            box = box.map { $0.union(key.frame) } ?? key.frame
        }
        guard let box else { return nil }
        self.init(centers: centers, frame: box)
    }

    /// x, y in the unit square, resampled to 60 Hz and then to 64 evenly spaced points.
    func resampled(_ path: [SwipePoint]) -> (x: [Float], y: [Float]) {
        let start = path[0].time
        let x = path.map { ($0.x - Double(frame.minX)) / Double(frame.width) }
        let y = path.map { ($0.y - Double(frame.minY)) / Double(frame.height) }
        let time = path.map { ($0.time - start) * 1000 }
        var rx = x
        var ry = y
        if let end = time.last, end > 1e-3 {
            let count = max(2, Int((end / (1000.0 / 60)).rounded(.toNearestOrEven)) + 1)
            let grid = (0..<count).map { end * Double($0) / Double(count - 1) }
            rx = Self.interpolate(grid, time, x)
            ry = Self.interpolate(grid, time, y)
        }
        let steps = SwipeEncoder.inputSteps
        let index = (0..<steps).map { Double(rx.count - 1) * Double($0) / Double(steps - 1) }
        let at = (0..<rx.count).map(Double.init)
        return (Self.interpolate(index, at, rx).map(Float.init), Self.interpolate(index, at, ry).map(Float.init))
    }

    /// `values` read at ascending `points`, linear between the ascending `positions` they are given at.
    static func interpolate(_ points: [Double], _ positions: [Double], _ values: [Double]) -> [Double] {
        guard positions.count > 1 else { return points.map { _ in values[0] } }
        var segment = 0
        return points.map { point in
            while segment < positions.count - 2, positions[segment + 1] < point { segment += 1 }
            let (a, b) = (positions[segment], positions[segment + 1])
            guard b > a else { return values[segment] }
            let fraction = min(max((point - a) / (b - a), 0), 1)
            return values[segment] + (values[segment + 1] - values[segment]) * fraction
        }
    }
}

/// The converted encoder weights (`swipe-encoder.tse`): "TSE1", float count (u32 LE), 8 zero bytes, then the
/// float32 tensors of `entries`. Matrices are input-major with outputs zero-padded to a multiple of 8.
nonisolated final class SwipeEncoder: Sendable {
    static let inputSteps = 64, steps = 32, letters = 26, classes = 27, hidden = 128, wide = 256
    static let coefficients = 64, frequencies = 8, blocks = 5, dilations = [1, 2, 3, 5, 8], kernel = 7
    static let dataOffset = 16

    /// ln P of each letter a–z and of the blank, `classes` per step.
    struct Emissions: Sendable {
        let values: [Float]
        subscript(step: Int, letter: Int) -> Float { values[step * SwipeEncoder.classes + letter] }
    }

    private struct Entry {
        let name: String
        let shape: [Int]
        let isMatrix: Bool
        static func padded(_ n: Int) -> Int { (n + 7) / 8 * 8 }
        var count: Int {
            isMatrix ? shape.dropFirst().reduce(1, *) * Self.padded(shape[0]) : Self.padded(shape.reduce(1, *))
        }
    }

    private static let entries: [Entry] = {
        var entries: [Entry] = []
        func add(_ name: String, _ shape: [Int], matrix: Bool = false) {
            entries.append(Entry(name: name, shape: shape, isMatrix: matrix))
        }
        for name in ["d1_x", "d1_y", "d2_x", "d2_y", "d1_curv"] { add("savgol_\(name)", [1, kernel, 1]) }
        add("input_conv_weight", [hidden, kernel, 8], matrix: true)
        add("input_conv_bias", [hidden])
        for b in 0..<blocks {
            let block = "block\(b)_"
            add(block + "dwconv_weight", [1, kernel, hidden])
            add(block + "dwconv_bias", [hidden])
            add(block + "pwconv1_weight", [4 * hidden, 1, hidden], matrix: true)
            add(block + "pwconv1_bias", [4 * hidden])
            add(block + "grn_gamma", [wide])
            add(block + "grn_beta", [wide])
            add(block + "pwconv2_weight", [hidden, 1, wide], matrix: true)
            add(block + "pwconv2_bias", [hidden])
            add(block + "se_fc1_weight", [hidden / 4, hidden], matrix: true)
            add(block + "se_fc1_bias", [hidden / 4])
            add(block + "se_fc2_weight", [hidden, hidden / 4], matrix: true)
            add(block + "se_fc2_bias", [hidden])
        }
        add("adapter_weight", [wide, 2, hidden], matrix: true)
        add("adapter_bias", [wide])
        add("lambda_weight", [1, wide], matrix: true)
        add("lambda_bias", [1])
        add("coeff_weight", [coefficients, wide], matrix: true)
        add("coeff_bias", [coefficients])
        return entries
    }()

    private static let offsets: [String: Int] = {
        var offsets: [String: Int] = [:]
        var at = dataOffset
        for entry in entries {
            offsets[entry.name] = at
            at += entry.count * 4
        }
        return offsets
    }()

    static var size: Int { dataOffset + entries.reduce(0) { $0 + $1.count } * 4 }

    private let data: Data

    init?(data: Data) {
        guard data.count == Self.size, Array(data.prefix(4)) == Array("TSE1".utf8) else { return nil }
        let floats = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard UInt32(littleEndian: floats) == UInt32((Self.size - Self.dataOffset) / 4) else { return nil }
        self.data = data
    }

    /// Mapped, not copied: clean pages the system can drop under memory pressure.
    static func bundled(_ bundle: Bundle = .main) -> SwipeEncoder? {
        guard let url = bundle.url(forResource: "swipe-encoder", withExtension: "tse", subdirectory: "SwipeModel"),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return SwipeEncoder(data: data)
    }

    /// Encoder log-probabilities for a path of at least two points.
    func emissions(of path: [SwipePoint], on layout: SwipeLayout) -> Emissions? {
        guard path.count >= 2, path.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.time.isFinite }) else { return nil }
        let (x, y) = layout.resampled(path)
        return data.withUnsafeBytes { raw in
            let scratch = Scratch()
            return encode(x: x, y: y, layout: layout, scratch, raw)
        }
    }

    /// One bump allocator per decode; freed with it. ~110k floats are used.
    private final class Scratch {
        static let capacity = 120_000
        let base = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        private var used = 0
        init() { base.initialize(repeating: 0, count: Self.capacity) }
        deinit { base.deallocate() }
        func take(_ count: Int) -> UnsafeMutablePointer<Float> {
            defer { used += (count + 7) / 8 * 8 }
            precondition(used + count <= Self.capacity)
            return base + used
        }
    }

    private func encode(x: [Float], y: [Float], layout: SwipeLayout, _ scratch: Scratch,
                        _ raw: UnsafeRawBufferPointer) -> Emissions {
        let steps = Self.inputSteps
        func tensor(_ name: String) -> UnsafeRawPointer { raw.baseAddress! + Self.offsets[name]! }
        func vector(_ name: String) -> UnsafePointer<Float> { tensor(name).assumingMemoryBound(to: Float.self) }

        let features = scratch.take(steps * 8)
        let vx = scratch.take(steps), vy = scratch.take(steps)
        let ax = scratch.take(steps), ay = scratch.take(steps)
        let angle = scratch.take(steps), curvature = scratch.take(steps)
        x.withUnsafeBufferPointer { x in
            y.withUnsafeBufferPointer { y in
                Self.savitzkyGolay(x.baseAddress!, vector("savgol_d1_x"), vx)
                Self.savitzkyGolay(y.baseAddress!, vector("savgol_d1_y"), vy)
                Self.savitzkyGolay(x.baseAddress!, vector("savgol_d2_x"), ax)
                Self.savitzkyGolay(y.baseAddress!, vector("savgol_d2_y"), ay)
                // Unwrapped heading, so curvature does not jump at ±π.
                var turns = 0.0, previous = 0.0
                for t in 0..<steps {
                    let current = Foundation.atan2(Double(vy[t]), Double(vx[t]))
                    if t > 0 {
                        let step = current - previous
                        if step > .pi { turns -= 2 * .pi } else if step < -.pi { turns += 2 * .pi }
                    }
                    previous = current
                    angle[t] = Float(current + turns)
                }
                Self.savitzkyGolay(angle, vector("savgol_d1_curv"), curvature)
                for t in 0..<steps {
                    let row = features + t * 8
                    row[0] = x[t]; row[1] = y[t]; row[2] = vx[t]; row[3] = vy[t]; row[4] = ax[t]; row[5] = ay[t]
                    row[6] = (vx[t] * vx[t] + vy[t] * vy[t] + 1e-8).squareRoot()
                    row[7] = min(max(curvature[t], -2), 2)
                }
            }
        }

        let taps = Self.kernel, half = taps / 2
        let columns = scratch.take(steps * taps * 8)
        for t in 0..<steps {
            for k in 0..<taps {
                let source = t + k - half
                let target = columns + t * taps * 8 + k * 8
                if source >= 0 && source < steps {
                    target.update(from: features + source * 8, count: 8)
                } else {
                    target.update(repeating: 0, count: 8)
                }
            }
        }
        var h = scratch.take(steps * Self.hidden)
        SwipeKernel.matmul(columns, rows: steps, inputs: taps * 8, tensor("input_conv_weight"),
                           tensor("input_conv_bias"), outputs: Self.hidden, into: h)
        SwipeKernel.hardswish(h, steps * Self.hidden)

        var other = scratch.take(steps * Self.hidden)
        let depthwise = scratch.take(steps * Self.hidden)
        let expanded = scratch.take(steps * 4 * Self.hidden)
        let gated = scratch.take(steps * Self.wide)
        let projected = scratch.take(steps * Self.hidden)
        let norm = scratch.take(Self.wide)
        let pooled = scratch.take(Self.hidden)
        let squeezed = scratch.take(Self.hidden / 4)
        for b in 0..<Self.blocks {
            let block = "block\(b)_"
            SwipeKernel.depthwise(h, steps: steps, channels: Self.hidden, taps: taps, dilation: Self.dilations[b],
                                  vector(block + "dwconv_weight"), vector(block + "dwconv_bias"), into: depthwise)
            SwipeKernel.matmul(depthwise, rows: steps, inputs: Self.hidden, tensor(block + "pwconv1_weight"),
                               tensor(block + "pwconv1_bias"), outputs: 4 * Self.hidden, into: expanded)
            SwipeKernel.gate(expanded, steps: steps, width: Self.wide, into: gated)
            SwipeKernel.normalize(gated, steps: steps, width: Self.wide, gamma: vector(block + "grn_gamma"),
                                  beta: vector(block + "grn_beta"), scratch: norm)
            SwipeKernel.matmul(gated, rows: steps, inputs: Self.wide, tensor(block + "pwconv2_weight"),
                               tensor(block + "pwconv2_bias"), outputs: Self.hidden, into: projected)
            SwipeKernel.mean(projected, steps: steps, width: Self.hidden, into: pooled)
            SwipeKernel.matmul(pooled, rows: 1, inputs: Self.hidden, tensor(block + "se_fc1_weight"),
                               tensor(block + "se_fc1_bias"), outputs: Self.hidden / 4, into: squeezed)
            for i in 0..<Self.hidden / 4 { squeezed[i] = max(squeezed[i], 0) }
            SwipeKernel.matmul(squeezed, rows: 1, inputs: Self.hidden / 4, tensor(block + "se_fc2_weight"),
                               tensor(block + "se_fc2_bias"), outputs: Self.hidden, into: pooled)
            SwipeKernel.sigmoid(pooled, Self.hidden)
            SwipeKernel.scaleAndAdd(projected, steps: steps, width: Self.hidden, scale: pooled, residual: h, into: other)
            swap(&h, &other)
        }

        // The adapter reads pairs of steps (64 → 32) as one row of 2 × hidden inputs.
        let adapted = scratch.take(Self.steps * Self.wide)
        SwipeKernel.matmul(h, rows: Self.steps, inputs: 2 * Self.hidden, tensor("adapter_weight"),
                           tensor("adapter_bias"), outputs: Self.wide, into: adapted)
        let gates = scratch.take(Self.steps * 8)
        SwipeKernel.matmul(adapted, rows: Self.steps, inputs: Self.wide, tensor("lambda_weight"),
                           tensor("lambda_bias"), outputs: 8, into: gates)
        let coefficients = scratch.take(Self.steps * Self.coefficients)
        SwipeKernel.matmul(adapted, rows: Self.steps, inputs: Self.wide, tensor("coeff_weight"),
                           tensor("coeff_bias"), outputs: Self.coefficients, into: coefficients)

        // Letter logits are a cosine-basis field evaluated at each key's center: any key geometry works.
        let basis = Self.basis(layout)
        var values = [Float](repeating: 0, count: Self.steps * Self.classes)
        var logits = [Float](repeating: 0, count: Self.letters)
        for t in 0..<Self.steps {
            let gate = 1 / (1 + Foundation.exp(-gates[t * 8]))
            let c = coefficients + t * Self.coefficients
            for k in 0..<Self.letters {
                var sum: Float = 0
                for j in 0..<Self.coefficients { sum += c[j] * basis[k * Self.coefficients + j] }
                logits[k] = sum
            }
            let high = logits.max()!
            var total: Float = 0
            for k in 0..<Self.letters { total += Foundation.exp(logits[k] - high) }
            let letterOffset = Foundation.log(max(gate, 1e-7)) - high - Foundation.log(total)
            for k in 0..<Self.letters { values[t * Self.classes + k] = max(logits[k] + letterOffset, -100) }
            values[t * Self.classes + Self.letters] = max(Foundation.log(max(1 - gate, 1e-7)), -100)
        }
        return Emissions(values: values)
    }

    private static func savitzkyGolay(_ input: UnsafePointer<Float>, _ kernel: UnsafePointer<Float>,
                                      _ out: UnsafeMutablePointer<Float>) {
        for t in 0..<inputSteps {
            var sum: Float = 0
            for k in 0..<Self.kernel {
                sum.addProduct(kernel[k], input[min(max(t + k - Self.kernel / 2, 0), inputSteps - 1)])
            }
            out[t] = sum
        }
    }

    /// Each key's row of the cosine basis `cos(π u x) cos(π v y)`, u, v < 8, u-major.
    private static func basis(_ layout: SwipeLayout) -> [Float] {
        var basis: [Float] = []
        basis.reserveCapacity(letters * coefficients)
        for center in layout.centers {
            let cx = (0..<frequencies).map { Float(Foundation.cos(Double.pi * Double($0) * center.x)) }
            let cy = (0..<frequencies).map { Float(Foundation.cos(Double.pi * Double($0) * center.y)) }
            for u in 0..<frequencies { for v in 0..<frequencies { basis.append(cx[u] * cy[v]) } }
        }
        return basis
    }
}

/// Network operations over flat step-major float buffers, eight channels at a time.
nonisolated enum SwipeKernel {
    typealias Vector = SIMD8<Float>

    private static func load(_ pointer: UnsafePointer<Float>, _ at: Int) -> Vector {
        UnsafeRawPointer(pointer + at).loadUnaligned(as: Vector.self)
    }

    private static func store(_ value: Vector, _ pointer: UnsafeMutablePointer<Float>, _ at: Int) {
        UnsafeMutableRawPointer(pointer + at).storeBytes(of: value, as: Vector.self)
    }

    private static func exp(_ x: Vector) -> Vector {
        var out = Vector()
        for i in 0..<8 { out[i] = Foundation.exp(x[i]) }
        return out
    }

    private static func sigmoid(_ x: Vector) -> Vector { 1 / (1 + exp(-x)) }

    /// `out[r] = bias + x[r] · weights`; `weights` holds one row of `outputs` per input.
    static func matmul(_ x: UnsafePointer<Float>, rows: Int, inputs: Int, _ weights: UnsafeRawPointer,
                       _ bias: UnsafeRawPointer, outputs: Int, into out: UnsafeMutablePointer<Float>) {
        let stride = outputs * 4
        for o in Swift.stride(from: 0, to: outputs, by: 8) {
            let start = bias.loadUnaligned(fromByteOffset: o * 4, as: Vector.self)
            var r = 0
            while r + 4 <= rows {
                var a0 = start, a1 = start, a2 = start, a3 = start
                let x0 = x + r * inputs, x1 = x0 + inputs, x2 = x1 + inputs, x3 = x2 + inputs
                var w = weights + o * 4
                for i in 0..<inputs {
                    let wv = w.loadUnaligned(as: Vector.self)
                    a0 += x0[i] * wv; a1 += x1[i] * wv; a2 += x2[i] * wv; a3 += x3[i] * wv
                    w += stride
                }
                store(a0, out, r * outputs + o)
                store(a1, out, (r + 1) * outputs + o)
                store(a2, out, (r + 2) * outputs + o)
                store(a3, out, (r + 3) * outputs + o)
                r += 4
            }
            while r < rows {
                var a = start
                let row = x + r * inputs
                var w = weights + o * 4
                for i in 0..<inputs {
                    a += row[i] * w.loadUnaligned(as: Vector.self)
                    w += stride
                }
                store(a, out, r * outputs + o)
                r += 1
            }
        }
    }

    static func hardswish(_ x: UnsafeMutablePointer<Float>, _ count: Int) {
        for i in Swift.stride(from: 0, to: count, by: 8) {
            let v = load(x, i)
            store(v * (v + 3).clamped(lowerBound: Vector(repeating: 0), upperBound: Vector(repeating: 6)) / 6, x, i)
        }
    }

    static func sigmoid(_ x: UnsafeMutablePointer<Float>, _ count: Int) {
        for i in Swift.stride(from: 0, to: count, by: 8) { store(sigmoid(load(x, i)), x, i) }
    }

    /// Per-channel convolution along the steps, zero-padded.
    static func depthwise(_ x: UnsafePointer<Float>, steps: Int, channels: Int, taps: Int, dilation: Int,
                          _ weights: UnsafePointer<Float>, _ bias: UnsafePointer<Float>,
                          into out: UnsafeMutablePointer<Float>) {
        for t in 0..<steps {
            for c in Swift.stride(from: 0, to: channels, by: 8) {
                var sum = load(bias, c)
                for k in 0..<taps {
                    let source = t + (k - taps / 2) * dilation
                    if source >= 0 && source < steps {
                        sum += load(weights, k * channels + c) * load(x, source * channels + c)
                    }
                }
                store(sum, out, t * channels + c)
            }
        }
    }

    /// sigmoid(first half) × second half of each step's `2 * width` channels.
    static func gate(_ x: UnsafePointer<Float>, steps: Int, width: Int, into out: UnsafeMutablePointer<Float>) {
        for t in 0..<steps {
            for c in Swift.stride(from: 0, to: width, by: 8) {
                store(sigmoid(load(x, t * 2 * width + c)) * load(x, t * 2 * width + width + c), out, t * width + c)
            }
        }
    }

    /// Global response normalization.
    static func normalize(_ x: UnsafeMutablePointer<Float>, steps: Int, width: Int, gamma: UnsafePointer<Float>,
                          beta: UnsafePointer<Float>, scratch: UnsafeMutablePointer<Float>) {
        for c in Swift.stride(from: 0, to: width, by: 8) {
            var energy = Vector()
            for t in 0..<steps {
                let v = load(x, t * width + c)
                energy += v * v
            }
            store((energy / Float(steps) + 1e-6).squareRoot(), scratch, c)
        }
        var mean: Float = 0
        for c in 0..<width { mean += scratch[c] }
        mean = mean / Float(width) + 1e-6
        for c in Swift.stride(from: 0, to: width, by: 8) {
            let factor = load(gamma, c) * load(scratch, c) / mean + 1
            let shift = load(beta, c)
            for t in 0..<steps { store(load(x, t * width + c) * factor + shift, x, t * width + c) }
        }
    }

    static func mean(_ x: UnsafePointer<Float>, steps: Int, width: Int, into out: UnsafeMutablePointer<Float>) {
        for c in Swift.stride(from: 0, to: width, by: 8) {
            var sum = Vector()
            for t in 0..<steps { sum += load(x, t * width + c) }
            store(sum / Float(steps), out, c)
        }
    }

    /// `x * scale + residual`, one scale per channel.
    static func scaleAndAdd(_ x: UnsafePointer<Float>, steps: Int, width: Int, scale: UnsafePointer<Float>,
                            residual: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        for t in 0..<steps {
            for c in Swift.stride(from: 0, to: width, by: 8) {
                store(load(x, t * width + c) * load(scale, c) + load(residual, t * width + c), out, t * width + c)
            }
        }
    }
}
