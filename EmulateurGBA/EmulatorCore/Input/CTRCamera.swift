//
//  CTRCamera.swift
//  EmulateurGBA
//
//  The 3DS's cameras, from the phone's: the core's camera (patch 0012) asks
//  for one when a game starts it, CTRBridge passes the request here, and this
//  runs a capture session on the phone's front camera for the 3DS's inner one
//  and its back camera for the two outer ones, and hands every frame back.
//
//  THE PERMISSION is asked the first time a game starts a camera, never
//  before (most 3DS games use none). When the player has refused, or the
//  device restricts the camera, the game receives black frames, as a 3DS with
//  a covered lens would, and the player is told once per game how to allow it
//  (`CTRCamera.deniedNotification`). Nothing leaves the phone: frames go to
//  the core and nowhere else.
//

import AVFoundation
import UIKit

final class CTRCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Posted on the main thread when a game starts a camera the player has
    /// not allowed (refused, or restricted): once per game.
    static let deniedNotification = Notification.Name("CTRCameraDeniedNotification")

    private weak var bridge: CTRBridge?
    private let queue = DispatchQueue(label: "CTRCamera")
    private var session: AVCaptureSession?
    private var position: AVCaptureDevice.Position?
    /// What the game asked for last, applied when the permission arrives.
    private var wanted: (run: Bool, inner: Bool) = (false, false)
    private var toldDenied = false
    /// The game is paused (`pause`); camera queue only.
    private var paused = false
    /// The interface's orientation, which the picture follows so the game
    /// sees the world upright however the phone is held (main thread, then
    /// read on the camera queue).
    private var orientation: AVCaptureVideoOrientation = .portrait

    init(bridge: CTRBridge) {
        self.bridge = bridge
        super.init()
        bridge.cameraHandler = { [weak self] run, inner in
            guard let self else { return }
            self.queue.async { [weak self] in self?.request(run: run, inner: inner) }
        }
    }

    deinit {
        bridge?.cameraHandler = nil
        session?.stopRunning()
    }

    /// Main thread, after the interface has rotated, and before a start.
    func orientationDidChange() {
        let interface = CTRMotion.phoneInterfaceOrientation
        // UIKit's interface orientations and AVFoundation's video ones share
        // their names and their meaning (where the home side is).
        let video: AVCaptureVideoOrientation
        switch interface {
        case .landscapeLeft: video = .landscapeLeft
        case .landscapeRight: video = .landscapeRight
        case .portraitUpsideDown: video = .portraitUpsideDown
        default: video = .portrait
        }
        queue.async {
            self.orientation = video
            if let connection = (self.session?.outputs.first as? AVCaptureVideoDataOutput)?
                .connection(with: .video) {
                Self.apply(video, to: connection)
            }
        }
    }

    /// The picture turned upright for `orientation`: the rotation angle on
    /// iOS 17 and later (the API that replaced `videoOrientation` there), the
    /// orientation before. The angles are the camera's own: 0 is the sensor's
    /// landscape, home side on the right.
    private static func apply(_ orientation: AVCaptureVideoOrientation, to connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch orientation {
            case .landscapeRight: angle = 0
            case .landscapeLeft: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
    }

    /// The game paused (the pause menu, a share card, the app in the
    /// background): the camera off, its green light with it, what the game
    /// asked for kept (audit, 2026-10-20: it kept capturing behind the menu).
    func pause() {
        queue.async {
            self.paused = true
            self.session?.stopRunning()
        }
    }

    /// The game runs again: the camera back on if the game had it on.
    func resume() {
        queue.async {
            self.paused = false
            if self.wanted.run { self.request(run: true, inner: self.wanted.inner) }
        }
    }

    /// The game stopped: off. Called with the session's shutdown as well.
    func stop() {
        queue.async { self.request(run: false, inner: self.wanted.inner) }
    }

    // MARK: - On the camera queue

    private func request(run: Bool, inner: Bool) {
        wanted = (run, inner)
        guard run else {
            session?.stopRunning()
            return
        }
        // Asked while paused: started on `resume`.
        guard !paused else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession(inner: inner)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    if granted {
                        if self.wanted.run, !self.paused { self.startSession(inner: self.wanted.inner) }
                    } else {
                        self.reportDenied()
                    }
                }
            }
        case .denied, .restricted:
            reportDenied()
        @unknown default:
            reportDenied()
        }
    }

    private func reportDenied() {
        guard !toldDenied else { return }
        toldDenied = true
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.deniedNotification, object: nil)
        }
    }

    private func startSession(inner: Bool) {
        let wantedPosition: AVCaptureDevice.Position = inner ? .front : .back
        if let session, position == wantedPosition {
            if !session.isRunning { session.startRunning() }
            return
        }
        session?.stopRunning()
        session = nil
        position = nil
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: wantedPosition)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let capture = AVCaptureSession()
        capture.beginConfiguration()
        // The 3DS's cameras are 640x480 at most: no more is captured.
        if capture.canSetSessionPreset(.vga640x480) { capture.sessionPreset = .vga640x480 }
        guard capture.canAddInput(input) else { capture.commitConfiguration(); return }
        capture.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard capture.canAddOutput(output) else { capture.commitConfiguration(); return }
        capture.addOutput(output)
        // Upright however the phone is held (`orientationDidChange`); the
        // inner camera mirrored as a front camera's picture is.
        if let connection = output.connection(with: .video) {
            Self.apply(orientation, to: connection)
            if inner, connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
        }
        capture.commitConfiguration()
        session = capture
        position = wantedPosition
        capture.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard wanted.run, let bridge, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        bridge.deliverCameraFrame(base, width: CVPixelBufferGetWidth(pixels),
                                  height: CVPixelBufferGetHeight(pixels),
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))
    }
}
