import AppKit
import MetalKit
#if SWIFT_PACKAGE
import LayoutCore
#endif

/// Compute and one instanced draw share GPU particle state and command ordering.
/// CPU reference mode retains three completion-protected upload buffers.
@MainActor
final class ParticleRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let simulation: MetalParticleSimulation?
    let engine: ParticleEngine
    private(set) var physicsEncodeMs = 0.0
    private let pipeline: MTLRenderPipelineState
    private let buffers: [MTLBuffer]
    private let available = DispatchSemaphore(value: 3)
    private var bufferIndex = 0
    private let capacity: Int

    init(engine: ParticleEngine, useGPU: Bool = true, collectDiagnostics: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "ParticleRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable"])
        }
        self.device = device
        self.queue = queue
        self.engine = engine
        self.capacity = max(1, engine.particles.count)
        simulation = useGPU ? try MetalParticleSimulation(engine: engine, device: device, collectDiagnostics: collectDiagnostics) : nil
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "particleVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "particleFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var uploads: [MTLBuffer] = []
        for _ in 0..<(useGPU ? 0 : 3) {
            guard let buffer = device.makeBuffer(length: self.capacity * MemoryLayout<MetalParticleSimulation.State>.stride, options: .storageModeShared) else {
                throw NSError(domain: "ParticleRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Metal upload allocation failed"])
            }
            uploads.append(buffer)
        }
        buffers = uploads
    }

    /// Never queue unlimited frames if the GPU falls behind. Completion owns the
    /// slot until Metal has finished reading it; no per-particle objects or uploads.
    func encode(at time: Double, size: CGSize, pass: MTLRenderPassDescriptor) throws -> MTLCommandBuffer? {
        guard available.wait(timeout: .now()) == .success else { return nil }
        guard let command = queue.makeCommandBuffer() else {
            available.signal()
            return nil
        }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            if let simulation { try simulation.encode(at: time, into: command) }
            else { engine.update(at: time); engine.clearPendingEmissions() }
        } catch {
            available.signal()
            throw error
        }
        physicsEncodeMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let available = available
        command.addCompletedHandler {
            if let error = $0.error { NSLog("Particle GPU command failed: %@", error.localizedDescription) }
            available.signal()
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            // Preserve any physics already encoded and its clock/state ordering.
            command.commit()
            return nil
        }
        let count = engine.activeParticleCount
        guard count > 0 else {
            // Border-only scenes still need the clear pass and presentation,
            // but Metal requires a nonzero instance count for particle draws.
            encoder.endEncoding()
            return command
        }
        let buffer: MTLBuffer
        if let simulation { buffer = simulation.particleBuffer }
        else {
            buffer = buffers[bufferIndex]
            bufferIndex = (bufferIndex + 1) % buffers.count
            let data = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: capacity * 2)
            for i in 0..<count {
                let p = engine.particles[i]
                data[2 * i] = SIMD4(Float(p.position.x), Float(p.position.y), Float(p.radius), Float(i % 7))
                data[2 * i + 1] = .zero
            }
        }
        var viewport = SIMD2(Float(size.width), Float(size.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        encoder.endEncoding()
        return command
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Raster { float4 position [[position]]; float2 uv; float3 color; };
    vertex Raster particleVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                 const device float4 *particles [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
        const float2 corners[6] = { {-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1} };
        const float3 colors[7] = { {1,.23,.3}, {1,.55,.12}, {1,.85,.17}, {.2,.85,.4}, {.15,.8,1}, {.68,.4,1}, {1,.35,.7} };
        float4 p = particles[instanceID * 2];
        float2 uv = corners[vertexID] * 1.35;
        Raster out;
        if (particles[instanceID * 2 + 1].z<0) {
            out.position=float4(2,2,0,1); out.uv=0; out.color=0; return out;
        }
        out.position = float4((p.xy + uv * p.z) / size * 2 - 1, 0, 1);
        out.uv = uv;
        out.color = colors[uint(p.w)];
        return out;
    }
    fragment float4 particleFragment(Raster in [[stage_in]]) {
        float distance = length(in.uv);
        float aa = max(fwidth(distance), .015);
        float alpha = 1 - smoothstep(1 - aa, 1 + aa, distance);
        float light = clamp(.9 + .24 * in.uv.y - .18 * in.uv.x, .5, 1.2);
        float highlight = exp(-18 * dot(in.uv - float2(-.3,.4), in.uv - float2(-.3,.4)));
        float3 color = min(float3(1), in.color * light + highlight * .32);
        return float4(color * alpha, alpha);
    }
    """
}
