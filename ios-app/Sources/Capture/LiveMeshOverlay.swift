import ARKit
import SceneKit
import UIKit

final class LiveMeshOverlayView: SCNView {
    static let rebuildIntervalS: TimeInterval = 0.5
    static let nearM: CGFloat = 0.05
    static let farM: CGFloat = 20

    weak var session: ARSession?

    private let cameraNode = SCNNode()
    private var nodes: [UUID: (node: SCNNode, faces: Int, vertices: Int)] = [:]
    private var link: CADisplayLink?
    private var lastRebuildAt: TimeInterval = -.infinity
    private let lineMaterial: SCNMaterial = {
        let material = SCNMaterial()
        material.fillMode = .lines
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 0.2, green: 0.9, blue: 1, alpha: 0.8)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        return material
    }()
    private let occluderMaterial: SCNMaterial = {
        let material = SCNMaterial()
        material.colorBufferWriteMask = []
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        return material
    }()
    static let occluderInsetM: Float = 0.02

    init() {
        super.init(frame: .zero, options: nil)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        antialiasingMode = .none
        preferredFramesPerSecond = 30
        autoenablesDefaultLighting = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let scene = SCNScene()
        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)
        self.scene = scene
        pointOfView = cameraNode
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopLink()
        } else {
            startLink()
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let target = LinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(LinkTarget.tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick() {
        guard let frame = session?.currentFrame, bounds.width > 0, bounds.height > 0 else { return }
        let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
        cameraNode.simdTransform = frame.camera.viewMatrix(for: orientation).inverse
        let projection = frame.camera.projectionMatrix(for: orientation, viewportSize: bounds.size, zNear: Self.nearM, zFar: Self.farM)
        cameraNode.camera?.projectionTransform = SCNMatrix4(projection)
        if frame.timestamp - lastRebuildAt >= Self.rebuildIntervalS {
            lastRebuildAt = frame.timestamp
            rebuild(frame.anchors.compactMap { $0 as? ARMeshAnchor })
        }
    }

    private func rebuild(_ anchors: [ARMeshAnchor]) {
        guard let root = scene?.rootNode else { return }
        var seen = Set<UUID>()
        for anchor in anchors {
            let id = anchor.identifier
            seen.insert(id)
            let faces = anchor.geometry.faces.count
            let vertices = anchor.geometry.vertices.count
            if let known = nodes[id] {
                known.node.simdTransform = anchor.transform
                if known.faces == faces && known.vertices == vertices { continue }
            }
            guard let lines = Self.geometry(for: anchor) else { continue }
            lines.materials = [lineMaterial]
            let occluder = Self.occluderGeometry(for: anchor, inset: Self.occluderInsetM)
            occluder?.materials = [occluderMaterial]
            let node = nodes[id]?.node ?? Self.makeAnchorNode()
            node.childNode(withName: Self.occluderName, recursively: false)?.geometry = occluder
            node.childNode(withName: Self.linesName, recursively: false)?.geometry = lines
            node.simdTransform = anchor.transform
            if node.parent == nil { root.addChildNode(node) }
            nodes[id] = (node, faces, vertices)
        }
        for id in nodes.keys where !seen.contains(id) {
            nodes[id]?.node.removeFromParentNode()
            nodes[id] = nil
        }
    }

    static let occluderName = "occluder"
    static let linesName = "lines"

    static func makeAnchorNode() -> SCNNode {
        let node = SCNNode()
        let occluder = SCNNode()
        occluder.name = occluderName
        occluder.renderingOrder = -1
        let lines = SCNNode()
        lines.name = linesName
        lines.renderingOrder = 1
        node.addChildNode(occluder)
        node.addChildNode(lines)
        return node
    }

    static func occluderGeometry(for anchor: ARMeshAnchor, inset: Float) -> SCNGeometry? {
        let vertices = anchor.geometry.vertices
        let normals = anchor.geometry.normals
        let faces = anchor.geometry.faces
        guard vertices.count > 0, faces.count > 0, faces.indexCountPerPrimitive == 3, normals.count == vertices.count,
              vertices.format == .float3, normals.format == .float3 else { return nil }
        let vertexBase = UnsafeRawPointer(vertices.buffer.contents().advanced(by: vertices.offset))
        let normalBase = UnsafeRawPointer(normals.buffer.contents().advanced(by: normals.offset))
        var points: [SCNVector3] = []
        points.reserveCapacity(vertices.count)
        for index in 0..<vertices.count {
            let v = index * vertices.stride
            let n = index * normals.stride
            let x = vertexBase.load(fromByteOffset: v, as: Float.self) - normalBase.load(fromByteOffset: n, as: Float.self) * inset
            let y = vertexBase.load(fromByteOffset: v + 4, as: Float.self) - normalBase.load(fromByteOffset: n + 4, as: Float.self) * inset
            let z = vertexBase.load(fromByteOffset: v + 8, as: Float.self) - normalBase.load(fromByteOffset: n + 8, as: Float.self) * inset
            points.append(SCNVector3(x, y, z))
        }
        let source = SCNGeometrySource(vertices: points)
        let indexData = Data(bytes: faces.buffer.contents(), count: faces.count * faces.indexCountPerPrimitive * faces.bytesPerIndex)
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)
        return SCNGeometry(sources: [source], elements: [element])
    }

    static func geometry(for anchor: ARMeshAnchor) -> SCNGeometry? {
        let vertices = anchor.geometry.vertices
        let faces = anchor.geometry.faces
        guard vertices.count > 0, faces.count > 0, faces.indexCountPerPrimitive == 3 else { return nil }
        let vertexData = Data(bytes: vertices.buffer.contents().advanced(by: vertices.offset), count: vertices.stride * vertices.count)
        let source = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: vertices.stride
        )
        let indexData = Data(bytes: faces.buffer.contents(), count: faces.count * faces.indexCountPerPrimitive * faces.bytesPerIndex)
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)
        return SCNGeometry(sources: [source], elements: [element])
    }

    @MainActor
    private final class LinkTarget: NSObject {
        weak var owner: LiveMeshOverlayView?

        init(owner: LiveMeshOverlayView) {
            self.owner = owner
            super.init()
        }

        @objc func tick() {
            owner?.tick()
        }
    }
}
