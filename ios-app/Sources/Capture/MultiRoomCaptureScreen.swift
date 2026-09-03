//
//  MultiRoomCaptureScreen.swift
//  VuuroScan
//
//  WRITTEN, NOT COMPILED OR RUN — see ../Models/ScanIdentity.swift header.
//
//  RoomCaptureView(frame:arSession:) instead of RoomCaptureScreen's plain
//  RoomCaptureView(frame:.zero) — the whole point of MultiRoomCaptureCoordinator
//  is that this view must stay mounted (never dismissed/recreated) for the
//  full multi-room walkthrough, reusing the coordinator's own ARSession.
//

import RoomPlan
import SwiftUI

struct MultiRoomCaptureScreen: UIViewRepresentable {
    let coordinator: MultiRoomCaptureCoordinator

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero, arSession: coordinator.arSession)
        coordinator.attach(to: view.captureSession)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
    }

    func makeCoordinator() -> RoomCaptureScreenViewDelegate {
        // Reused from RoomCaptureScreen.swift — same reasoning: skip
        // RoomPlan's own review screen, we build/upload from didEndWith directly.
        RoomCaptureScreenViewDelegate()
    }
}
